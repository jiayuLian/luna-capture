#import "LunaCapture.h"
#import <objc/runtime.h>
#import <objc/message.h>

@implementation LCRecord
@end

#pragma mark - 存储

@implementation LCCapture {
    NSMutableArray<LCRecord *> *_records;
    NSLock *_lock;
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
    }
    return self;
}

- (void)addRecord:(LCRecord *)rec {
    if (!rec || rec.url.length == 0) return;
    [_lock lock];
    [_records addObject:rec];
    if (_records.count > 5000) [_records removeObjectsInRange:NSMakeRange(0, 1000)];
    NSUInteger n = _records.count;
    [_lock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:@"LCUpdate" object:@(n)];
    });
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

@end

#pragma mark - 过滤

// 媒体与静态资源不进记录,否则音频流会把金币接口冲掉
static BOOL LCSkipURL(NSURL *u) {
    if (!u) return YES;
    NSString *p = u.path.lowercaseString;
    static NSArray *ext = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ext = @[@".mp3", @".m4a", @".mp4", @".aac", @".flac", @".wav", @".ogg",
                @".webp", @".png", @".jpg", @".jpeg", @".gif", @".svg", @".heic",
                @".ttf", @".otf", @".zip", @".dylib", @".js", @".css", @".map"];
    });
    for (NSString *e in ext) {
        if ([p hasSuffix:e]) return YES;
    }
    NSString *h = u.host.lowercaseString;
    static NSArray *cdn = nil;
    static dispatch_once_t once2;
    dispatch_once(&once2, ^{
        cdn = @[@"douyinpic", @"byteimg", @"douyinstatic", @"bytednsdoc",
                @"volccdn", @"ibytedns", @"pstatp", @"-pic.", @"img."];
    });
    for (NSString *c in cdn) {
        if ([h containsString:c]) return YES;
    }
    return NO;
}

#pragma mark - NSURLProtocol

@interface LCProtocol : NSURLProtocol
@end

@implementation LCProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:@"LCHandled" inRequest:request]) return NO;
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
    NSDate *start = [NSDate date];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    // 内部 session 不能再走 LCProtocol,否则递归
    cfg.protocolClasses = @[];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg
                                                         delegate:nil
                                                    delegateQueue:nil];

    __weak typeof(self) weakSelf = self;
    NSURLSessionDataTask *task =
        [session dataTaskWithRequest:req
                   completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf recordRequest:req response:resp data:data start:start error:err];
            if (err) {
                [strongSelf.client URLProtocol:strongSelf didFailWithError:err];
            } else {
                [strongSelf.client URLProtocol:strongSelf
                            didReceiveResponse:resp
                            cacheStoragePolicy:NSURLCacheStorageNotAllowed];
                if (data.length) [strongSelf.client URLProtocol:strongSelf didLoadData:data];
                [strongSelf.client URLProtocolDidFinishLoading:strongSelf];
            }
            [session finishTasksAndInvalidate];
        }];
    [task resume];
}

- (void)stopLoading {
    // 内部 session 的 task 由 completion 收尾,这里不主动取消
}

- (void)recordRequest:(NSURLRequest *)req
             response:(NSURLResponse *)resp
                 data:(NSData *)data
                start:(NSDate *)start
                error:(NSError *)err {
    LCRecord *r = [LCRecord new];
    r.method = req.HTTPMethod.length ? req.HTTPMethod : @"GET";
    r.url = req.URL.absoluteString;
    r.start = start;
    r.end = [NSDate date];
    r.source = @"nsurlsession";
    r.reqHeaders = [req allHTTPHeaderFields] ?: @{};

    NSData *body = req.HTTPBody;
    if (!body && req.HTTPBodyStream) {
        // body 走 stream 的请求:尽力读取,失败就算了
        NSInputStream *is = req.HTTPBodyStream;
        [is open];
        NSMutableData *md = [NSMutableData data];
        uint8_t buf[4096];
        while ([is hasBytesAvailable]) {
            NSInteger n = [is read:buf maxLength:sizeof(buf)];
            if (n <= 0) break;
            [md appendBytes:buf length:(NSUInteger)n];
        }
        [is close];
        body = md;
    }
    if (body.length) r.reqBody = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];

    if ([resp isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
        r.status = h.statusCode;
        r.respHeaders = h.allHeaderFields ?: @{};
    }
    r.mime = resp.MIMEType;

    if (data.length) {
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (s) {
            r.respBody = s;
            r.respIsBase64 = NO;
        } else {
            r.respBody = [data base64EncodedStringWithOptions:0];
            r.respIsBase64 = YES;
        }
    }
    if (err) {
        r.respBody = [NSString stringWithFormat:@"[ERROR] %@ (%ld)",
                      err.localizedDescription, (long)err.code];
    }
    [[LCCapture shared] addRecord:r];
}

@end

#pragma mark - 让自定义 protocol 挂进所有 session

@interface NSURLSessionConfiguration (LC)
@end

@implementation NSURLSessionConfiguration (LC)

- (void)lc_setProtocolClasses:(NSArray *)classes {
    NSMutableArray *a = classes ? [classes mutableCopy] : [NSMutableArray array];
    if (![a containsObject:[LCProtocol class]]) {
        [a insertObject:[LCProtocol class] atIndex:0];
    }
    // 交换后 lc_setProtocolClasses 指向原 setter
    [self lc_setProtocolClasses:a];
}

@end

#pragma mark - 安装

void LCHookAll(void) {
    [NSURLProtocol registerClass:[LCProtocol class]];

    Class cls = [NSURLSessionConfiguration class];
    Method m1 = class_getInstanceMethod(cls, @selector(setProtocolClasses:));
    Method m2 = class_getInstanceMethod(cls, @selector(lc_setProtocolClasses:));
    if (m1 && m2) {
        method_exchangeImplementations(m1, m2);
        NSLog(@"[LC] protocolClasses swizzled");
    }

    NSLog(@"[LC] hooks installed, %@", LC_VER);
}
