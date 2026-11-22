//
//  HookSession.m
//  NSURLSession 层的旁路观察。
//
//  为什么走这一层:主二进制里有 TTNetURLSessionDelegate 这个类,
//  说明 TTNet(Cronet) 的请求最终落到 NSURLSession 上发出。
//  之前抓不到,是因为只 hook 了 dataTaskWithRequest:completionHandler:
//  (带 block 的那个重载),而 App 用的是 delegate 模式。
//
//  为什么安全:hook 的全是签名完全确定的方法 ——
//  -[NSURLSessionTask resume] 是 void(id,SEL),零参数零返回值;
//  delegate 回调是固定 3~5 个对象参数。
//  全部用精确 C 签名直接调用原实现,不走 NSInvocation,不做 va_arg,
//  参数一个不丢,也不可能错位。
//

#import "LunaCapture.h"
#import <objc/runtime.h>

#define LC_BODY_CAP (512 * 1024)
#define LC_POLL_MAX 40                      // 40 × 0.25s = 10s

static const void *kLCBodyKey   = &kLCBodyKey;    // 累积的响应体
static const void *kLCTrackedKey = &kLCTrackedKey; // 已登记标记

// 诊断计数:导出 HAR 时写进 creator.comment,一眼看出哪条通道在工作
static volatile int gSessionSeen = 0;
static volatile int gSessionHooked = 0;

int LCSessionSeen(void) { return gSessionSeen; }
int LCSessionHooked(void) { return gSessionHooked; }

#pragma mark - 工具

static id LCKVC(id obj, NSArray<NSString *> *keys) {
    if (!obj) return nil;
    for (NSString *k in keys) {
        @try {
            id v = [obj valueForKey:k];
            if (v) return v;
        } @catch (NSException *e) {
            // key 不存在或类型不符
        }
    }
    return nil;
}

static NSString *LCBodyStr(NSData *d, BOOL *isB64) {
    if (d.length == 0) return nil;
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    if (s) {
        if (isB64) *isB64 = NO;
        return s;
    }
    if (isB64) *isB64 = YES;
    return [d base64EncodedStringWithOptions:0];
}

#pragma mark - 去重
// 同一请求可能被 sessiontask 和 ttnet 两条通道各碰一次。
// 用 URL+method 的 2 秒窗口只放一条过去。

static NSMutableDictionary<NSString *, NSNumber *> *gClaim = nil;
static NSLock *gClaimLock = nil;

BOOL LCTryClaimURL(NSString *url, NSString *method) {
    if (url.length == 0) return YES;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gClaim = [NSMutableDictionary dictionary];
        gClaimLock = [NSLock new];
    });

    NSString *key = [NSString stringWithFormat:@"%@|%@", method ?: @"GET", url];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];

    [gClaimLock lock];
    // 顺手清理过期项,表不会无限涨
    if (gClaim.count > 3000) {
        NSMutableArray *dead = [NSMutableArray array];
        for (NSString *k in gClaim) {
            if (now - gClaim[k].doubleValue > 5.0) [dead addObject:k];
        }
        [gClaim removeObjectsForKeys:dead];
    }
    BOOL claimed = (gClaim[key] == nil);
    if (claimed) gClaim[key] = @(now);
    [gClaimLock unlock];
    return claimed;
}

#pragma mark - 记录

// 媒体与静态资源不进记录:一条广告视频能塞几百个分片请求,
// 会把 8000 条缓冲冲满,金币接口就被挤没了
static BOOL LCSkipURL(NSString *u) {
    if (u.length == 0) return YES;
    NSString *s = u.lowercaseString;
    static NSArray *ext = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ext = @[@".mp3", @".m4a", @".aac", @".flac", @".wav", @".ogg",
                @".mp4", @".m4v", @".ts", @".m4s", @".mov", @".flv",
                @".webp", @".png", @".jpg", @".jpeg", @".gif", @".heic",
                @".ttf", @".otf", @".zip", @".js", @".css", @".map"];
    });
    NSRange q = [s rangeOfString:@"?"];
    NSString *path = (q.location == NSNotFound) ? s : [s substringToIndex:q.location];
    for (NSString *e in ext) {
        if ([path hasSuffix:e]) return YES;
    }
    if ([s containsString:@"/video/tos/"] || [s containsString:@"/audio/tos/"]) return YES;
    if ([s containsString:@"bytestart="] || [s containsString:@"byteend="]) return YES;

    static NSArray *cdn = nil;
    static dispatch_once_t onceCdn;
    dispatch_once(&onceCdn, ^{
        cdn = @[@"douyinpic", @"byteimg", @"douyinstatic", @"bytednsdoc",
                @"volccdn", @"ibytedns", @"pstatp", @"bytedcdn"];
    });
    for (NSString *c in cdn) {
        if ([s containsString:c]) return YES;
    }
    return NO;
}

static void LCFinishSessionTask(id task) {
    if (!task) return;

    NSURLRequest *req = LCKVC(task, @[@"originalRequest", @"currentRequest", @"request"]);
    if (![req isKindOfClass:[NSURLRequest class]]) return;

    NSString *url = req.URL.absoluteString;
    if (url.length == 0) return;
    if (LCSkipURL(url)) return;

    NSString *method = req.HTTPMethod ?: @"GET";
    if (!LCTryClaimURL(url, method)) return;

    LCRecord *r = [LCRecord new];
    r.url = url;
    r.method = method.uppercaseString;
    r.source = @"sessiontask";
    r.reqHeaders = req.allHTTPHeaderFields ?: @{};

    if (req.HTTPBody.length) {
        BOOL b64 = NO;
        r.reqBody = LCBodyStr(req.HTTPBody, &b64);
    }

    NSURLResponse *resp = LCKVC(task, @[@"response"]);
    if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
        r.status = h.statusCode;
        r.respHeaders = h.allHeaderFields ?: @{};
        r.mime = h.MIMEType;
    } else if ([resp isKindOfClass:[NSURLResponse class]]) {
        r.mime = resp.MIMEType;
    }

    NSData *body = objc_getAssociatedObject(task, kLCBodyKey);
    if (body.length) {
        BOOL b64 = NO;
        r.respBody = LCBodyStr(body, &b64);
        r.respIsBase64 = b64;
    }

    r.start = [NSDate date];
    r.end = r.start;

    gSessionSeen++;
    [[LCCapture shared] addRecord:r];
}

static void LCPollTask(id task, int tries);

static void LCRegisterTask(id task) {
    if (!task) return;
    if (![task isKindOfClass:[NSURLSessionTask class]]) return;

    // 同一个 task 只登记一次
    if (objc_getAssociatedObject(task, kLCTrackedKey)) return;
    objc_setAssociatedObject(task, kLCTrackedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    LCPollTask(task, 0);
}

static void LCPollTask(id task, int tries) {
    // block 捕获 task,期间它不会被释放
    NSURLSessionTaskState st = [task state];
    if (tries < LC_POLL_MAX && st != NSURLSessionTaskStateCompleted) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            LCPollTask(task, tries + 1);
        });
        return;
    }
    LCFinishSessionTask(task);
}

#pragma mark - hook: -[NSURLSessionTask resume]

// void(id, SEL),零参数。转发时一个参数都不用处理,不可能错位。
static void (*gOrigResume)(id, SEL) = NULL;

static void LCResume(id self, SEL _cmd) {
    if (!gOrigResume) return;
    @try {
        LCRegisterTask(self);
    } @catch (NSException *e) {}
    gOrigResume(self, _cmd);
}

// void(id, SEL, NSURLSession *, NSURLSessionTask *, NSError *)
static void (*gOrigDidComplete)(id, SEL, id, id, id) = NULL;

static void LCDidComplete(id self, SEL _cmd, id session, id task, id error) {
    if (gOrigDidComplete) {
        @try {
            LCFinishSessionTask(task);
        } @catch (NSException *e) {}
        gOrigDidComplete(self, _cmd, session, task, error);
    }
}

// void(id, SEL, NSURLSession *, NSURLSessionDataTask *, NSData *)
static void (*gOrigDidRecvData)(id, SEL, id, id, id) = NULL;

static void LCDidRecvData(id self, SEL _cmd, id session, id task, id data) {
    if (gOrigDidRecvData) {
        @try {
            if (task && [data isKindOfClass:[NSData class]] && [(NSData *)data length]) {
                NSMutableData *buf = objc_getAssociatedObject(task, kLCBodyKey);
                if (!buf) {
                    buf = [NSMutableData data];
                    objc_setAssociatedObject(task, kLCBodyKey, buf,
                                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                if (buf.length < LC_BODY_CAP) [buf appendData:(NSData *)data];
            }
        } @catch (NSException *e) {}
        gOrigDidRecvData(self, _cmd, session, task, data);
    }
}

#pragma mark - 安装

static void LCHookResumeOn(Class cls) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, @selector(resume));
    if (!m) return;
    IMP cur = method_getImplementation(m);
    // 已经是我们自己的实现(父类装过),跳过,避免自己调自己
    if (cur == (IMP)LCResume) return;

    if (!gOrigResume) gOrigResume = (void *)cur;
    method_setImplementation(m, (IMP)LCResume);
    gSessionHooked = 1;
}

static void LCHookDelegateClass(Class cls) {
    if (!cls) return;

    Method m1 = class_getInstanceMethod(cls,
        @selector(URLSession:task:didCompleteWithError:));
    if (m1) {
        IMP cur = method_getImplementation(m1);
        if (cur != (IMP)LCDidComplete) {
            if (!gOrigDidComplete) gOrigDidComplete = (void *)cur;
            method_setImplementation(m1, (IMP)LCDidComplete);
        }
    }

    Method m2 = class_getInstanceMethod(cls,
        @selector(URLSession:dataTask:didReceiveData:));
    if (m2) {
        IMP cur = method_getImplementation(m2);
        if (cur != (IMP)LCDidRecvData) {
            if (!gOrigDidRecvData) gOrigDidRecvData = (void *)cur;
            method_setImplementation(m2, (IMP)LCDidRecvData);
        }
    }
}

void LCHookSession(void) {
    // 每次调用都重试一遍:delegate 类是 App 运行中才加载的,
    // 首次可能拿不到。LCHookResumeOn / LCHookDelegateClass 内部
    // 用 IMP 比对做幂等,重复调用无副作用。
    LCHookResumeOn([NSURLSessionTask class]);
    for (NSString *n in @[@"NSURLSessionDataTask",
                          @"NSURLSessionUploadTask",
                          @"NSURLSessionDownloadTask",
                          @"NSURLSessionStreamTask"]) {
        Class c = NSClassFromString(n);
        if (c) LCHookResumeOn(c);
    }

    NSMutableArray<NSString *> *hit = [NSMutableArray array];
    for (NSString *n in @[@"TTNetURLSessionDelegate",
                          @"TTNetSessionDelegate",
                          @"BDNetworkSessionDelegate",
                          @"TTNetworkManagerChromium"]) {
        Class c = NSClassFromString(n);
        if (!c) continue;
        LCHookDelegateClass(c);
        [hit addObject:n];
    }

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLog(@"[LC] session hook: resume + delegate %@", hit);
    });
}
