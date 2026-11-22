//
//  HookTTNet.m
//  iOS 版汽水音乐的业务请求走 Cronet(TTNet)。
//  Cronet 的 C++ 层被 strip,只剩下 ObjC 门面类可碰:
//    TTHttpTask / TTHttpTaskChromium     任务对象,request/response 都挂在上面
//    TTHttpResponse / TTHttpResponseChromium
//
//  ── 为什么不再用 NSInvocation 转发 ──
//  前几版试图"通用地"hook 任意签名的方法,用 va_list 逐个搬参数。
//  这条路在真机上连续崩了三次(EXC_BAD_ACCESS,异常处理器抓不到):
//  参数里有 block(栈对象)、有继承方法(IMP 表查不到)、有结构体,
//  任何一个搬错就是整个进程死。
//
//  现在只 hook 签名完全确定的方法:
//    零参数、返回 void 或对象。转发时一个参数都不用处理,不可能错位。
//  代价是覆盖面变窄,但换来的是不崩。
//

#import "LunaCapture.h"
#import <objc/runtime.h>

NSString *LCHookInfo = @"ttnet:init";
void LCHookTTNet(void);
BOOL LCTryClaimURL(NSString *url, NSString *method);

static volatile int gSeen = 0;
static volatile int gSkipped = 0;

NSString *LCStatString(void) {
    return [NSString stringWithFormat:@"%@ seen:%d skip:%d",
            LCHookInfo ?: @"ttnet:none", gSeen, gSkipped];
}

#pragma mark - 安全取值
// 只按已知 key 用 KVC 取,不遍历属性链。
// 遍历会碰到 assign 语义的对象属性,getter 返回野指针,一碰就崩。

static id LCKVC(id obj, NSArray<NSString *> *keys) {
    if (!obj) return nil;
    for (NSString *k in keys) {
        @try {
            id v = [obj valueForKey:k];
            if (v) return v;
        } @catch (NSException *e) {
            // key 不存在 / 类型不符
        }
    }
    return nil;
}

static NSString *LCAsString(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v stringValue];
    if ([v isKindOfClass:[NSURL class]]) return [(NSURL *)v absoluteString];
    return nil;
}

static NSDictionary *LCAsDict(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:[NSDictionary class]] && [(NSDictionary *)v count]) return v;
    return nil;
}

static NSString *LCAsBody(id v) {
    if (!v) return nil;
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v length] ? v : nil;
    if ([v isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)v;
        if (d.length == 0) return nil;
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s) return [s length] > 16384 ? [s substringToIndex:16384] : s;
        return [@"base64:" stringByAppendingString:
                [d base64EncodedStringWithOptions:0]];
    }
    return nil;
}

#pragma mark - 噪音过滤

static BOOL LCSkipURLString(NSString *url) {
    if (url.length == 0) return YES;
    NSString *u = url.lowercaseString;
    static NSArray *ext = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ext = @[@".mp3", @".m4a", @".aac", @".flac", @".wav", @".ogg",
                @".mp4", @".m4v", @".ts", @".m4s", @".mov", @".flv",
                @".webp", @".png", @".jpg", @".jpeg", @".gif", @".heic",
                @".ttf", @".otf", @".zip", @".js", @".css", @".map",
                @".dylib", @".bundle"];
    });
    NSRange q = [u rangeOfString:@"?"];
    NSString *path = (q.location == NSNotFound) ? u : [u substringToIndex:q.location];
    for (NSString *e in ext) {
        if ([path hasSuffix:e]) return YES;
    }
    if ([u containsString:@"/video/tos/"] || [u containsString:@"/audio/tos/"]) return YES;
    if ([u containsString:@"bytestart="] || [u containsString:@"byteend="]) return YES;

    static NSArray *cdn = nil;
    static dispatch_once_t onceCdn;
    dispatch_once(&onceCdn, ^{
        cdn = @[@"douyinpic", @"byteimg", @"douyinstatic", @"bytednsdoc",
                @"volccdn", @"ibytedns", @"pstatp", @"bytedcdn"];
    });
    for (NSString *c in cdn) {
        if ([u containsString:c]) return YES;
    }
    return NO;
}

#pragma mark - task 跟踪

static NSMutableDictionary<NSString *, id> *gTasks = nil;
static NSLock *gTaskLock = nil;

static void LCEnsureTaskTable(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gTasks = [NSMutableDictionary dictionary];
        gTaskLock = [NSLock new];
    });
}

static NSString *LCPtrKey(id obj) {
    return [NSString stringWithFormat:@"%p", obj];
}

static void LCPollTask(id task, int tries);

static void LCFinishTask(id task) {
    if (!task) return;

    LCEnsureTaskTable();
    [gTaskLock lock];
    [gTasks removeObjectForKey:LCPtrKey(task)];
    [gTaskLock unlock];

    id req = LCKVC(task, @[@"request", @"httpRequest", @"originalRequest", @"urlRequest"]);
    id resp = LCKVC(task, @[@"response", @"httpResponse", @"urlResponse"]);

    NSString *url = nil;
    NSString *method = nil;
    NSDictionary *reqH = nil;
    NSString *reqB = nil;

    if (req) {
        url = LCAsString(LCKVC(req, @[@"URLString", @"urlString", @"URL", @"url", @"absoluteString"]));
        method = LCAsString(LCKVC(req, @[@"HTTPMethod", @"httpMethod", @"method"]));
        reqH = LCAsDict(LCKVC(req, @[@"allHTTPHeaderFields", @"headerField", @"headers"]));
        reqB = LCAsBody(LCKVC(req, @[@"HTTPBody", @"body", @"postData"]));
    }
    if (url.length == 0) {
        url = LCAsString(LCKVC(task, @[@"URLString", @"urlString", @"url", @"URL"]));
    }
    if (url.length == 0) return;
    if (![url hasPrefix:@"http"]) return;
    if (LCSkipURLString(url)) { gSkipped++; return; }

    method = [method length] ? method.uppercaseString : @"GET";
    if (!LCTryClaimURL(url, method)) return;   // 另一条通道已经记过

    gSeen++;

    LCRecord *r = [LCRecord new];
    r.url = url;
    r.method = method;
    r.source = @"ttnet";
    if (reqH.count) r.reqHeaders = reqH;
    if (reqB.length) r.reqBody = reqB;

    if (resp) {
        NSString *st = LCAsString(LCKVC(resp, @[@"statusCode", @"status", @"httpStatusCode"]));
        if (st.length) r.status = st.integerValue;
        NSDictionary *respH = LCAsDict(LCKVC(resp, @[@"allHeaderFields", @"headerField", @"headers"]));
        if (respH.count) r.respHeaders = respH;
        NSString *respB = LCAsBody(LCKVC(resp, @[@"responseBody", @"body", @"data", @"content"]));
        if (respB.length) {
            if ([respB hasPrefix:@"base64:"]) {
                r.respBody = [respB substringFromIndex:7];
                r.respIsBase64 = YES;
            } else {
                r.respBody = respB;
            }
        }
    }

    r.start = [NSDate date];
    r.end = r.start;

    [[LCCapture shared] addRecord:r];
}

static BOOL LCLooksLikeTask(id o) {
    if (!o) return NO;
    if (![o isKindOfClass:[NSObject class]]) return NO;
    Class c = object_getClass(o);
    if (!c) return NO;
    const char *cn = class_getName(c);
    if (!cn) return NO;
    return (strstr(cn, "Task") != NULL) || (strstr(cn, "task") != NULL);
}

static NSMutableSet *gTracked = nil;

static void LCTrackTask(id task) {
    if (!LCLooksLikeTask(task)) return;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gTracked = [NSMutableSet set];
    });

    LCEnsureTaskTable();
    NSString *key = LCPtrKey(task);

    [gTaskLock lock];
    if (gTasks[key]) {
        [gTaskLock unlock];
        return;
    }
    gTasks[key] = @"pending";
    [gTaskLock unlock];

    LCPollTask(task, 0);
}

static void LCPollTask(id task, int tries) {
    // 有响应就早点收,没有就轮询到上限
    id resp = LCKVC(task, @[@"response", @"httpResponse", @"urlResponse"]);
    BOOL done = NO;
    if (resp) {
        NSString *st = LCAsString(LCKVC(resp, @[@"statusCode", @"status", @"httpStatusCode"]));
        if (st.length && st.integerValue > 0) done = YES;
    }

    if (!done && tries < 40) {           // 40 × 0.25s = 10s
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            LCPollTask(task, tries + 1);
        });
        return;
    }
    LCFinishTask(task);
}

#pragma mark - 零参数方法 hook

// 用 Method 指针做 key:父类和子类共用同一个 Method 结构体,
// 继承调用也能查到原实现。
static NSMapTable *gOrigIMPs = nil;
static NSLock *gIMPock = nil;

static void LCEnsureIMPTable(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gOrigIMPs = [NSMapTable mapTableWithKeyOptions:
                     (NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality)
                                          valueOptions:NSPointerFunctionsStrongMemory];
        gIMPock = [NSLock new];
    });
}

static void *LCOrigIMPForMethod(Method m) {
    if (!m || !gOrigIMPs) return NULL;
    [gIMPock lock];
    NSValue *v = [gOrigIMPs objectForKey:(__bridge id)(void *)m];
    void *p = v ? [v pointerValue] : NULL;
    [gIMPock unlock];
    return p;
}

static void LCSetOrigIMP(Method m, IMP imp) {
    if (!m || !gOrigIMPs) return;
    [gIMPock lock];
    [gOrigIMPs setObject:[NSValue valueWithPointer:(void *)imp]
                  forKey:(__bridge id)(void *)m];
    [gIMPock unlock];
}

// 返回 void 的零参方法:void(id, SEL)
static void LCZeroArgV(id self, SEL _cmd) {
    Method m = class_getInstanceMethod(object_getClass(self), _cmd);
    void *op = LCOrigIMPForMethod(m);
    if (op) ((void (*)(id, SEL))op)(self, _cmd);
}

// 返回对象的零参方法:id(id, SEL)
static id LCZeroArgR(id self, SEL _cmd) {
    Method m = class_getInstanceMethod(object_getClass(self), _cmd);
    void *op = LCOrigIMPForMethod(m);
    if (!op) return nil;
    id ret = ((id (*)(id, SEL))op)(self, _cmd);
    @try {
        LCTrackTask(ret);
    } @catch (NSException *e) {}
    return ret;
}

// 触发请求的零参方法名。只认这些,不做全量 hook,
// 避免把 rootViewController 之类的 getter 也挂上,白耗性能。
static BOOL LCStarterName(const char *sn) {
    static const char *names[] = {
        "resume", "start", "startTask", "begin", "beginTask",
        "fire", "launch", "run", "send", "execute", "doStart", "kickOff"
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (strcmp(sn, names[i]) == 0) return YES;
    }
    return NO;
}

static int LCHookZeroArgOnClass(Class cls, NSMutableArray<NSString *> *log) {
    if (!cls) return 0;
    LCEnsureIMPTable();
    int hooked = 0;

    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        Method m = ms[i];
        SEL sel = method_getName(m);
        const char *sn = sel_getName(sel);
        if (!sn) continue;
        if (!LCStarterName(sn)) continue;

        // 只接受零参数
        const char *types = method_getTypeEncoding(m);
        if (!types) continue;
        NSMethodSignature *sig = nil;
        @try {
            sig = [NSMethodSignature signatureWithObjCTypes:types];
        } @catch (NSException *e) {
            sig = nil;
        }
        if (!sig || sig.numberOfArguments != 2) continue;

        char *rt = method_copyReturnType(m);
        BOOL isVoid = (rt && *rt == 'v');
        BOOL isObj  = (rt && *rt == '@');
        if (rt) free(rt);
        if (!isVoid && !isObj) continue;

        if (LCOrigIMPForMethod(m)) continue;
        IMP cur = method_getImplementation(m);
        if (cur == (IMP)LCZeroArgV || cur == (IMP)LCZeroArgR) continue;

        LCSetOrigIMP(m, cur);
        method_setImplementation(m, isVoid ? (IMP)LCZeroArgV : (IMP)LCZeroArgR);
        hooked++;
        if (log && log.count < 100) [log addObject:[NSString stringWithUTF8String:sn]];
    }
    if (ms) free(ms);
    return hooked;
}

#pragma mark - 安装

static NSMutableSet *gHooked = nil;

void LCHookTTNet(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LCEnsureIMPTable();
        gHooked = [NSMutableSet set];
    });

    // task 类名是确定的,直接从 ObjC runtime 取,不用扫全量类
    NSArray *classNames = @[@"TTHttpTask",
                            @"TTHttpTaskChromium",
                            @"TTNetTask",
                            @"CronetClient"];

    NSMutableArray<NSString *> *log = [NSMutableArray array];
    int total = 0;

    for (NSString *n in classNames) {
        Class c = NSClassFromString(n);
        if (!c) continue;
        if ([gHooked containsObject:n]) continue;
        int h = LCHookZeroArgOnClass(c, log);
        // 子类可能重写,再走一遍元类(类方法)
        Class meta = object_getClass(c);
        if (meta) h += LCHookZeroArgOnClass(meta, log);
        if (h > 0) {
            [gHooked addObject:n];
            total += h;
        }
    }

    if (total > 0) {
        LCHookInfo = [NSString stringWithFormat:@"ttnet:%d 零参/%lu 类",
                      total, (unsigned long)gHooked.count];
        NSLog(@"[LC] %@", LCHookInfo);
        for (NSString *s in log) NSLog(@"[LC]   hook %@", s);

        NSString *d = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                           NSUserDomainMask, YES) firstObject];
        if (d.length) {
            NSMutableString *s = [NSMutableString stringWithFormat:@"# %@\n", LC_VER];
            for (NSString *x in log) [s appendFormat:@"%@\n", x];
            @try {
                [s writeToFile:[d stringByAppendingPathComponent:@"lc_hooked.txt"]
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:NULL];
            } @catch (NSException *e) {}
        }
    }
}
