#import "LunaCapture.h"
#import <objc/runtime.h>
#import <objc/message.h>

#define LC_MAX_BODY   (512 * 1024)        // 单条 body 存进 HAR 的上限
#define LC_MAX_STREAM (8 * 1024 * 1024)   // 读取 HTTPBodyStream 的上限,读满即视为超长上传

@implementation LCRecord
@end

#pragma mark - 工具

// 一次性读完 stream,带长度上限
static NSData *LCReadStream(NSInputStream *is, NSUInteger cap) {
    if (!is) return nil;
    [is open];
    NSMutableData *md = [NSMutableData data];
    uint8_t buf[8192];
    while ([is hasBytesAvailable]) {
        NSInteger n = [is read:buf maxLength:sizeof(buf)];
        if (n <= 0) break;
        [md appendBytes:buf length:(NSUInteger)n];
        if (md.length >= cap) break;
    }
    [is close];
    return md.length ? md : nil;
}

static NSString *LCISO(NSDate *d) {
    if (!d) return @"";
    static NSDateFormatter *f = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        f = [NSDateFormatter new];
        f.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
        f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [f stringFromDate:d];
}

static NSArray *LCHdr(NSDictionary *h) {
    NSMutableArray *a = [NSMutableArray array];
    [h enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        [a addObject:@{@"name": [k description], @"value": [v description]}];
    }];
    return a;
}

static NSArray *LCQuery(NSURL *u) {
    NSMutableArray *a = [NSMutableArray array];
    if (!u) return a;
    NSURLComponents *c = [NSURLComponents componentsWithURL:u resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *q in c.queryItems) {
        [a addObject:@{@"name": q.name ?: @"", @"value": q.value ?: @""}];
    }
    return a;
}

static NSString *LCBodyString(NSData *data, BOOL *isBase64) {
    if (data.length == 0) return nil;
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (s) {
        if (isBase64) *isBase64 = NO;
        return s;
    }
    if (isBase64) *isBase64 = YES;
    return [data base64EncodedStringWithOptions:0];
}

#pragma mark - 去重
// 同一个请求会被 NSURLProtocol 和 dataTask swizzle 各碰一次,3 秒窗口内只记一次

static NSMutableDictionary<NSString *, NSNumber *> *gRecent = nil;
static NSLock *gRecentLock = nil;

static void LCRecentInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gRecent = [NSMutableDictionary dictionary];
        gRecentLock = [NSLock new];
    });
}

static BOOL LCTryClaim(NSString *key) {
    if (key.length == 0) return YES;
    LCRecentInit();
    [gRecentLock lock];
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSArray *keys = [gRecent allKeys];
    for (NSString *k in keys) {
        if (now - gRecent[k].doubleValue > 1.0) [gRecent removeObjectForKey:k];
    }
    BOOL claimed = (gRecent[key] == nil);
    if (claimed) gRecent[key] = @(now);
    [gRecentLock unlock];
    return claimed;
}

#pragma mark - 内部请求防护
// 内部 session 发出的请求如果再被 LCProtocol 拦到,就是无限递归。
// 只靠 setProperty 不保险(能否跨 mutableCopy 是未文档化行为),
// 再加一张 URL 集合:发之前登记,回来后立刻注销。

static NSMutableSet<NSString *> *gInternal = nil;
static NSLock *gInternalLock = nil;

static void LCInternalInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gInternal = [NSMutableSet set];
        gInternalLock = [NSLock new];
    });
}

static NSString *LCReqKey(NSURLRequest *r) {
    if (!r) return @"";
    return [NSString stringWithFormat:@"%@|%@",
            r.HTTPMethod.length ? r.HTTPMethod : @"GET",
            r.URL.absoluteString ?: @""];
}

static void LCInternalMark(NSString *k, BOOL on) {
    if (k.length == 0) return;
    LCInternalInit();
    [gInternalLock lock];
    if (on) [gInternal addObject:k];
    else [gInternal removeObject:k];
    [gInternalLock unlock];
}

static BOOL LCInternalHas(NSString *k) {
    if (k.length == 0) return NO;
    LCInternalInit();
    [gInternalLock lock];
    BOOL b = [gInternal containsObject:k];
    [gInternalLock unlock];
    return b;
}

#pragma mark - 存储

@implementation LCCapture {
    NSMutableArray<LCRecord *> *_records;
    NSLock *_lock;
    NSTimeInterval _lastNotify;
}

+ (instancetype)shared {
    static LCCapture *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [LCCapture new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _records = [NSMutableArray array];
        _lock = [NSLock new];
        _lastNotify = 0;
    }
    return self;
}

- (void)addRecord:(LCRecord *)rec {
    if (!rec || rec.url.length == 0) return;
    NSUInteger n = 0;
    BOOL notify = NO;
    [_lock lock];
    [_records addObject:rec];
    if (_records.count > 5000) [_records removeObjectsInRange:NSMakeRange(0, 1000)];
    n = _records.count;
    // 节流:250ms 内最多刷一次 UI,否则高频请求会把主线程刷爆
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - _lastNotify > 0.25) {
        _lastNotify = now;
        notify = YES;
    }
    [_lock unlock];

    if (notify) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:@"LCUpdate"
                                                                object:@(n)];
        });
    }
}

- (NSUInteger)count {
    [_lock lock];
    NSUInteger n = _records.count;
    [_lock unlock];
    return n;
}

- (void)clear {
    [_lock lock];
    [_records removeAllObjects];
    [_lock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LCUpdate" object:@(0)];
    });
}

- (NSArray<LCRecord *> *)snapshot {
    [_lock lock];
    NSArray *a = [_records copy];
    [_lock unlock];
    return a;
}

#pragma mark - 记录入口(两条通道共用)

- (void)recordRequest:(NSURLRequest *)req
             response:(NSURLResponse *)resp
                 data:(NSData *)data
                start:(NSDate *)start
                end:(NSDate *)end
             reqBody:(NSData *)reqBody
              source:(NSString *)source
                error:(NSError *)err {
    NSString *url = req.URL.absoluteString;
    if (url.length == 0) return;

    NSString *method = req.HTTPMethod.length ? req.HTTPMethod : @"GET";
    // 去重键带上 body 长度,避免同 URL 的并发上报被误吞
    NSString *claimKey = [NSString stringWithFormat:@"%@|%@|%lu",
                          method, url, (unsigned long)reqBody.length];
    if (!LCTryClaim(claimKey)) return;   // 另一条通道已经记过

    LCRecord *r = [LCRecord new];
    r.method = method;
    r.url = url;
    r.start = start ?: [NSDate date];
    r.end = end ?: [NSDate date];
    r.source = source ?: @"?";
    r.reqHeaders = [req allHTTPHeaderFields] ?: @{};

    // 存进 HAR 前截断,避免单条大 JSON 把内存和导出文件撑爆
    NSData *rb = reqBody.length > LC_MAX_BODY
        ? [reqBody subdataWithRange:NSMakeRange(0, LC_MAX_BODY)] : reqBody;
    if (rb.length) {
        BOOL b64 = NO;
        r.reqBody = LCBodyString(rb, &b64);
    }

    if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
        r.status = h.statusCode;
        r.respHeaders = h.allHeaderFields ?: @{};
    }
    r.mime = resp.MIMEType;

    NSData *pb = data.length > LC_MAX_BODY
        ? [data subdataWithRange:NSMakeRange(0, LC_MAX_BODY)] : data;
    if (pb.length) {
        BOOL b64 = NO;
        r.respBody = LCBodyString(pb, &b64);
        r.respIsBase64 = b64;
    }
    if (err) {
        r.respBody = [NSString stringWithFormat:@"[ERROR] %@ (%ld)",
                      err.localizedDescription, (long)err.code];
        r.respIsBase64 = NO;
    }

    [self addRecord:r];
}

#pragma mark - 导出

- (NSDictionary *)buildHAR {
    NSArray<LCRecord *> *recs = [self snapshot];
    NSMutableArray *entries = [NSMutableArray arrayWithCapacity:recs.count];

    for (LCRecord *r in recs) {
        double ms = [r.end timeIntervalSinceDate:r.start] * 1000.0;
        if (ms < 0) ms = 0;

        NSUInteger reqLen = r.reqBody.length
            ? [r.reqBody dataUsingEncoding:NSUTF8StringEncoding].length : 0;

        NSMutableDictionary *req = [@{
            @"method": r.method ?: @"GET",
            @"url": r.url ?: @"",
            @"httpVersion": @"HTTP/1.1",
            @"headers": LCHdr(r.reqHeaders),
            @"queryString": LCQuery([NSURL URLWithString:r.url ?: @""]),
            @"cookies": @[],
            @"headersSize": @(-1),
            @"bodySize": @(reqLen)
        } mutableCopy];
        if (r.reqBody.length) {
            req[@"postData"] = @{
                @"mimeType": @"application/x-www-form-urlencoded",
                @"text": r.reqBody
            };
        }

        NSMutableDictionary *content = [@{
            @"size": @(r.respBody.length),
            @"mimeType": r.mime ?: @"application/json"
        } mutableCopy];
        if (r.respBody.length) {
            content[@"text"] = r.respBody;
            if (r.respIsBase64) content[@"encoding"] = @"base64";
        }

        NSDictionary *resp = @{
            @"status": @(r.status),
            @"statusText": @"",
            @"httpVersion": @"HTTP/1.1",
            @"headers": LCHdr(r.respHeaders),
            @"cookies": @[],
            @"content": content,
            @"redirectURL": @"",
            @"headersSize": @(-1),
            @"bodySize": @(r.respBody.length)
        };

        [entries addObject:@{
            @"startedDateTime": LCISO(r.start),
            @"time": @(ms),
            @"request": req,
            @"response": resp,
            @"cache": @{},
            @"timings": @{@"send": @0, @"wait": @(ms), @"receive": @0},
            @"_source": r.source ?: @""
        }];
    }

    return @{
        @"log": @{
            @"version": @"1.2",
            @"creator": @{@"name": @"LunaCapture", @"version": LC_VER},
            @"entries": entries
        }
    };
}

- (NSString *)docPath:(NSString *)name {
    NSString *doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                        NSUserDomainMask, YES).firstObject;
    if (doc.length == 0) doc = NSTemporaryDirectory();
    return [doc stringByAppendingPathComponent:name];
}

- (NSString *)writeHARWithName:(NSString *)name {
    NSDictionary *har = [self buildHAR];
    NSError *err = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:har
                                                options:NSJSONWritingPrettyPrinted
                                                  error:&err];
    if (!d) {
        NSLog(@"[LC] HAR serialize failed: %@", err);
        return nil;
    }
    NSString *p = [self docPath:name];
    BOOL ok = [d writeToFile:p atomically:YES];
    if (!ok) {
        NSLog(@"[LC] HAR write failed: %@", p);
        return nil;
    }
    NSLog(@"[LC] HAR -> %@ (%lu bytes)", p, (unsigned long)d.length);
    return p;
}

- (NSString *)exportHAR {
    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"MMdd_HHmmss";
    NSString *name = [NSString stringWithFormat:@"luna_%@.har",
                      [f stringFromDate:[NSDate date]]];
    return [self writeHARWithName:name];
}

- (NSString *)exportJSON {
    NSString *name = [NSString stringWithFormat:@"luna_%lu.json",
                      (unsigned long)[[NSDate date] timeIntervalSince1970]];
    return [self writeHARWithName:name];
}

@end

#pragma mark - 过滤

// 媒体与静态资源不进记录,否则音频流会把金币接口冲掉
static BOOL LCSkipURL(NSURL *u) {
    if (!u) return YES;
    NSString *p = u.path.lowercaseString;
    static NSArray *ext = nil;
    static dispatch_once_t onceExt;
    dispatch_once(&onceExt, ^{
        ext = @[@".mp3", @".m4a", @".mp4", @".aac", @".flac", @".wav", @".ogg",
                @".webp", @".png", @".jpg", @".jpeg", @".gif", @".svg", @".heic",
                @".ttf", @".otf", @".zip", @".dylib", @".js", @".css", @".map"];
    });
    for (NSString *e in ext) {
        if ([p hasSuffix:e]) return YES;
    }
    NSString *h = u.host.lowercaseString;
    static NSArray *cdn = nil;
    static dispatch_once_t onceCdn;
    dispatch_once(&onceCdn, ^{
        cdn = @[@"douyinpic", @"byteimg", @"douyinstatic", @"bytednsdoc",
                @"volccdn", @"ibytedns", @"pstatp"];
    });
    for (NSString *c in cdn) {
        if ([h containsString:c]) return YES;
    }
    return NO;
}

#pragma mark - 通道 A:NSURLProtocol(覆盖 delegate 模式与新建 session)

@interface LCProtocol : NSURLProtocol {
    NSURLSession *_inner;
    NSURLSessionDataTask *_task;
}
@end

@implementation LCProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"LCHandled" inRequest:request]) return NO;
    // 内部转发请求直接放行,这是防递归的第二道保险
    if (LCInternalHas(LCReqKey(request))) return NO;
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
    if (LCSkipURL(request.URL)) return NO;
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:@"LCHandled" inRequest:req];

    // 发出去之前登记,保证内部 session 不会再拦到这条
    NSString *fwdKey = LCReqKey(req);
    LCInternalMark(fwdKey, YES);

    // body 必须在发请求之前取,发完 stream 就空了
    NSData *reqBody = req.HTTPBody;
    if (!reqBody && req.HTTPBodyStream) {
        reqBody = LCReadStream(req.HTTPBodyStream, LC_MAX_STREAM);
        if (reqBody.length) {
            req.HTTPBody = reqBody;
            req.HTTPBodyStream = nil;
        }
    }

    NSDate *start = [NSDate date];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    cfg.protocolClasses = @[];
    _inner = [NSURLSession sessionWithConfiguration:cfg delegate:nil delegateQueue:nil];

    __weak typeof(self) weakSelf = self;
    _task = [_inner dataTaskWithRequest:req
                      completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        LCInternalMark(fwdKey, NO);

        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        [[LCCapture shared] recordRequest:req
                                 response:resp
                                     data:data
                                    start:start
                                      end:[NSDate date]
                                  reqBody:reqBody
                                   source:@"protocol"
                                    error:err];

        if (err) {
            [strongSelf.client URLProtocol:strongSelf didFailWithError:err];
        } else {
            [strongSelf.client URLProtocol:strongSelf
                        didReceiveResponse:resp
                        cacheStoragePolicy:NSURLCacheStorageNotAllowed];
            if (data.length) [strongSelf.client URLProtocol:strongSelf didLoadData:data];
            [strongSelf.client URLProtocolDidFinishLoading:strongSelf];
        }
        [strongSelf->_inner finishTasksAndInvalidate];
    }];
    [_task resume];
}

- (void)stopLoading {
    // 请求被上层取消,也要把登记撤掉,否则同 URL 后续会被永久跳过
    LCInternalMark(LCReqKey(self.request), NO);
    [_task cancel];
    [_inner invalidateAndCancel];
    _task = nil;
    _inner = nil;
}

@end

#pragma mark - 通道 B:dataTask swizzle(覆盖 App 启动时就建好的 session)

static id (*gOrigDataTask)(id, SEL, NSURLRequest *, void (^)(NSData *, NSURLResponse *, NSError *)) = NULL;

static id LCDataTaskWithRequest(id self, SEL _cmd, NSURLRequest *req,
                                void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    if (!gOrigDataTask) return nil;
    if (!req || handler == NULL) {
        return gOrigDataTask(self, _cmd, req, handler);
    }

    NSDate *start = [NSDate date];

    // body 提前拿一份(此时 stream 还没被消费)
    NSData *reqBody = req.HTTPBody;
    NSURLRequest *frozen = req;
    if (!reqBody && req.HTTPBodyStream) {
        NSMutableURLRequest *m = [req mutableCopy];
        reqBody = LCReadStream(req.HTTPBodyStream, LC_MAX_STREAM);
        if (reqBody.length) {
            m.HTTPBody = reqBody;
            m.HTTPBodyStream = nil;
            frozen = m;   // 用补好 body 的版本往下传,否则请求会缺 body
        }
    }

    void (^wrapped)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *resp, NSError *err) {
            [[LCCapture shared] recordRequest:frozen
                                     response:resp
                                         data:data
                                        start:start
                                          end:[NSDate date]
                                      reqBody:reqBody
                                       source:@"taskswizzle"
                                        error:err];
            if (handler) handler(data, resp, err);
        };

    return gOrigDataTask(self, _cmd, frozen, wrapped);
}

#pragma mark - 让自定义 protocol 挂进所有新建 session

@interface NSURLSessionConfiguration (LC)
@end

@implementation NSURLSessionConfiguration (LC)

- (void)lc_setProtocolClasses:(NSArray *)classes {
    // 空数组是内部 session 主动清空协议栈,必须原样透传,否则会把自己插回去形成递归
    if (classes.count == 0) {
        [self lc_setProtocolClasses:classes];
        return;
    }
    NSMutableArray *a = [classes mutableCopy];
    if (![a containsObject:[LCProtocol class]]) {
        [a insertObject:[LCProtocol class] atIndex:0];
    }
    // 交换后 lc_setProtocolClasses 指向原 setter
    [self lc_setProtocolClasses:a];
}

@end

#pragma mark - 安装

void LCHookAll(void) {
    LCRecentInit();

    // 通道 A
    [NSURLProtocol registerClass:[LCProtocol class]];

    // 通道 B
    Class sessionCls = [NSURLSession class];
    Method m = class_getInstanceMethod(sessionCls,
        @selector(dataTaskWithRequest:completionHandler:));
    if (m) {
        gOrigDataTask = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)LCDataTaskWithRequest);
        NSLog(@"[LC] dataTask swizzled");
    }

    // 让新建 session 自动带上 LCProtocol
    Class cfgCls = [NSURLSessionConfiguration class];
    Method m1 = class_getInstanceMethod(cfgCls, @selector(setProtocolClasses:));
    Method m2 = class_getInstanceMethod(cfgCls, @selector(lc_setProtocolClasses:));
    if (m1 && m2) {
        method_exchangeImplementations(m1, m2);
        NSLog(@"[LC] protocolClasses swizzled");
    }

    NSLog(@"[LC] hooks installed, %@", LC_VER);
}
