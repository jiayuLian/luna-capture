//
//  LCAuto.m
//  任务自动化:在 App 进程内触发领奖。
//
//  为什么不能在青龙上用 Python 做:
//  do_action 有设备指纹校验。同一份 body、同一套 header 从 PC 发,
//  服务端回 1000043「设备异常,领取失败」,并且把 listen 任务整条下架。
//  这里改走 App 自己的网络层(TTNetworkManager),签名 / 设备指纹 / cookie
//  全部由 App 生成,服务端看到的与用户手动点击完全一致。
//
//  GET 类接口(拉任务页)仍走 NSURLSession,因为读接口不校验设备指纹
//  (已验证:数小时前抓的 GET 重放仍返回 status_code 0)。
//

#import "LunaCapture.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <zlib.h>

// 活动级 token。两份 HAR(相隔 1 小时)里都是同一个值,
// 说明它是活动配置常量而不是一次性票据。
// 若某天服务端换了活动,把这里改成新值即可。
static NSString *const kLCActToken =
    @"SrHhVe4GsFX7bqEai_I--NaXpWmcLUDuyAhqnjzcSjn00gG0uON7XB-Yp7hYDP8F";
static const NSInteger kLCSettingsVersion = 60;

static NSString *gAutoBase = nil;          // https://api5-lq.qishui.com
static NSDictionary *gAutoHeaders = nil;   // 复用的请求头
static volatile BOOL gAutoRunning = NO;
static NSMutableArray<NSString *> *gAutoLogBuf = nil;
static NSLock *gAutoLock = nil;

#pragma mark - 日志

void LCAutoLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[LCAuto] %@", s);
    if (!gAutoLock) gAutoLock = [NSLock new];
    [gAutoLock lock];
    if (!gAutoLogBuf) gAutoLogBuf = [NSMutableArray array];
    NSString *line = [NSString stringWithFormat:@"[%@] %@",
                      [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                     dateStyle:NSDateFormatterNoStyle
                                                     timeStyle:NSDateFormatterMediumStyle],
                      s];
    [gAutoLogBuf addObject:line];
    if (gAutoLogBuf.count > 400) [gAutoLogBuf removeObjectsInRange:NSMakeRange(0, 100)];
    NSString *snapshot = [gAutoLogBuf componentsJoinedByString:@"\n"];
    [gAutoLock unlock];

    // 落盘到 Documents/lc_auto.txt,文件 App 里可直接取
    NSArray *ps = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                      NSUserDomainMask, YES);
    if (ps.count == 0) return;
    NSString *p = [ps.firstObject stringByAppendingPathComponent:@"lc_auto.txt"];
    [snapshot writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

NSString *LCAutoLogText(void) {
    if (!gAutoLock) return @"";
    [gAutoLock lock];
    NSString *s = [gAutoLogBuf componentsJoinedByString:@"\n"] ?: @"";
    [gAutoLock unlock];
    return s;
}

#pragma mark - gzip

// 读接口的响应有时是 gzip。NSURLSession 只在没显式设 accept-encoding 时
// 才自动解,所以这里按魔数自己解,不依赖响应头。
static NSData *LCGunzip(NSData *in) {
    if (in.length < 18) return in;
    z_stream zs;
    memset(&zs, 0, sizeof(zs));
    // 15+32:自动识别 gzip / zlib 头
    if (inflateInit2(&zs, 15 + 32) != Z_OK) return in;

    NSUInteger cap = in.length * 4 + 4096;
    NSMutableData *out = [NSMutableData dataWithLength:cap];
    zs.next_in = (Bytef *)in.bytes;
    zs.avail_in = (uInt)in.length;
    zs.next_out = (Bytef *)out.mutableBytes;
    zs.avail_out = (uInt)cap;

    int rc = inflate(&zs, Z_NO_FLUSH);
    if (rc != Z_OK && rc != Z_STREAM_END) {
        inflateEnd(&zs);
        return in;
    }
    out.length = zs.total_out;
    inflateEnd(&zs);
    return out;
}

#pragma mark - 找 App 的网络管理器

// 类名不硬编码单一值:不同版本 App 里单例挂在不同的类上。
// 按优先级探测,第一个能响应"发 JSON 请求"方法的就用它。
static NSArray<NSString *> *LCNetManagerClasses(void) {
    return @[@"BDUGLuckyDogNetworkManager",   // 金币中心专用,优先级最高
             @"TTNetworkManagerChromium",
             @"TTNetworkManager",
             @"TTNetworkManagerImpl",
             @"NetworkManager"];
}

static NSArray<NSString *> *LCRequestSelectors(void) {
    // 参数顺序按 selector 冒号顺序解析,所以顺序写错也不会串位
    return @[@"requestForJSONWithPath:params:method:needCommonParams:retryTimes:headerField:callback:",
             @"requestForJSONWithPath:params:method:needCommonParams:headerField:callback:",
             @"requestForJSONWithResponse:params:method:needCommonParams:headerField:callback:",
             @"requestForJSONWithPath:params:method:headerField:callback:"];
}

static BOOL LCClassCanRequest(Class c) {
    for (NSString *n in LCRequestSelectors()) {
        if (class_getInstanceMethod(c, NSSelectorFromString(n))) return YES;
    }
    return NO;
}

static id LCNetManagerGet(void) {
    static id cached = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *name in LCNetManagerClasses()) {
            Class c = NSClassFromString(name);
            if (!c || !LCClassCanRequest(c)) continue;

            // 单例方法:依次试 shareInstance / sharedInstance / defaultManager / new
            id inst = nil;
            SEL singles[] = {NSSelectorFromString(@"shareInstance"),
                             NSSelectorFromString(@"sharedInstance"),
                             NSSelectorFromString(@"defaultManager")};
            for (int i = 0; i < 3 && !inst; i++) {
                if ([c respondsToSelector:singles[i]]) {
                    @try {
                        inst = ((id (*)(id, SEL))objc_msgSend)(c, singles[i]);
                    } @catch (NSException *e) { inst = nil; }
                }
            }
            if (!inst) {
                @try { inst = [c new]; } @catch (NSException *e) { inst = nil; }
            }
            if (inst && [inst respondsToSelector:@selector(methodSignatureForSelector:)]) {
                cached = inst;
                LCAutoLog(@"网络管理器 = %@", name);
                return;
            }
        }
        LCAutoLog(@"没找到可用的网络管理器,自动化不可用");
    });
    return cached;
}

#pragma mark - 用 App 的网络层发请求

// 按 selector 的冒号名字逐个填参数,类型不匹配就跳过这个 selector。
// 这样换 App 版本、方法名一样但参数类型变了,也不会写坏寄存器。
static BOOL LCInvokeRequest(id mgr, NSString *selName, NSString *path,
                            NSDictionary *params, NSString *method) {
    SEL sel = NSSelectorFromString(selName);
    if (![mgr respondsToSelector:sel]) return NO;

    NSMethodSignature *sig = [mgr methodSignatureForSelector:sel];
    if (!sig) return NO;

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    [inv setTarget:mgr];
    [inv setSelector:sel];

    NSArray *parts = [selName componentsSeparatedByString:@":"];
    NSUInteger idx = 2;                       // 0=self 1=_cmd
    BOOL ok = YES;

    for (NSUInteger i = 0; i + 1 < parts.count; i++, idx++) {
        if (idx >= sig.numberOfArguments) { ok = NO; break; }
        NSString *p = parts[i];
        const char *t = [sig getArgumentTypeAtIndex:idx];
        if (!t) { ok = NO; break; }

        if ([p isEqualToString:@"path"]) {
            if (t[0] != '@') { ok = NO; break; }
            NSString *v = path;
            [inv setArgument:&v atIndex:idx];

        } else if ([p isEqualToString:@"params"]) {
            if (t[0] != '@') { ok = NO; break; }
            NSDictionary *v = params ?: @{};
            [inv setArgument:&v atIndex:idx];

        } else if ([p isEqualToString:@"method"]) {
            if (t[0] != '@') { ok = NO; break; }
            NSString *v = method;
            [inv setArgument:&v atIndex:idx];

        } else if ([p isEqualToString:@"needCommonParams"]) {
            if (t[0] == 'B') {
                BOOL v = YES;
                [inv setArgument:&v atIndex:idx];
            } else if (t[0] == 'c') {
                char v = 1;
                [inv setArgument:&v atIndex:idx];
            } else { ok = NO; break; }

        } else if ([p isEqualToString:@"retryTimes"] || [p isEqualToString:@"priority"]) {
            if (t[0] == 'q' || t[0] == 'Q' || t[0] == 'l') {
                long long v = 0;
                [inv setArgument:&v atIndex:idx];
            } else if (t[0] == 'i' || t[0] == 'I') {
                int v = 0;
                [inv setArgument:&v atIndex:idx];
            } else { ok = NO; break; }

        } else if ([p isEqualToString:@"headerField"]) {
            if (t[0] != '@') { ok = NO; break; }
            id v = gAutoHeaders;
            [inv setArgument:&v atIndex:idx];

        } else if ([p isEqualToString:@"callback"]) {
            // 回调传 nil:我们靠"过 2 秒重拉任务页看状态"判定结果,
            // 不去构造签名未知的 block(那是崩溃来源)。
            if (t[0] != '@') { ok = NO; break; }
            id v = nil;
            [inv setArgument:&v atIndex:idx];

        } else {
            ok = NO;                       // 有不认识的参数名,整体放弃
            break;
        }
    }

    if (!ok) return NO;

    @try {
        [inv invoke];
        return YES;
    } @catch (NSException *e) {
        LCAutoLog(@"%@ 调用异常: %@", selName, e.reason);
        return NO;
    }
}

static BOOL LCFireJSON(NSString *path, NSDictionary *params, NSString *method) {
    id mgr = LCNetManagerGet();
    if (!mgr) return NO;
    for (NSString *sel in LCRequestSelectors()) {
        if (LCInvokeRequest(mgr, sel, path, params, method)) {
            LCAutoLog(@"已发出 %@ %@", method, path);
            return YES;
        }
    }
    LCAutoLog(@"没有匹配到可用的请求方法");
    return NO;
}

#pragma mark - 读接口(NSURLSession,不需要设备签名)

static NSDictionary *LCGetJSON(NSString *path) {
    if (gAutoBase.length == 0) return nil;
    NSString *url = [gAutoBase stringByAppendingString:path];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 20;
    // 只带鉴权相关的头,其余让服务端按默认处理
    for (NSString *k in @[@"cookie", @"x-tt-token", @"x-ss-cookie", @"user-agent",
                          @"x-ss-dp", @"sdk_aid", @"x-luna-api-version",
                          @"x-common-params-v2", @"x-khronos", @"tt-request-time"]) {
        NSString *v = gAutoHeaders[k];
        if (v) [req setValue:v forHTTPHeaderField:k];
    }
    [req setValue:[NSString stringWithFormat:@"%ld", (long)[[NSDate date] timeIntervalSince1970]]
       forHTTPHeaderField:@"x-khronos"];

    __block NSDictionary *out = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *t =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
                                        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        if (d.length) {
            NSData *raw = d;
            // gzip 手动解:NSURLSession 只有在我们没设 accept-encoding 时才自动解
            if (raw.length > 2 && ((const uint8_t *)raw.bytes)[0] == 0x1F
                             && ((const uint8_t *)raw.bytes)[1] == 0x8B) {
                raw = LCGunzip(raw);
            }
            id j = [NSJSONSerialization JSONObjectWithData:raw options:0 error:NULL];
            if ([j isKindOfClass:[NSDictionary class]]) out = j;
        }
        if (e) LCAutoLog(@"GET %@ 失败: %@", path, e.localizedDescription);
        dispatch_semaphore_signal(sem);
    }];
    [t resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 25ull * NSEC_PER_SEC));
    return out;
}

#pragma mark - 请求体

static NSDictionary *LCBuildClaimBody(NSString *token) {
    NSString *uid = [[NSUUID UUID] UUIDString];
    NSDictionary *common = @{@"token": token ?: @"", @"unique_id": uid};
    return @{
        @"act_common": @{
            @"act_token": kLCActToken,
            @"settings_version": @(kLCSettingsVersion),
            @"static_settings_version": @(kLCSettingsVersion),
            @"dynamic_settings_version": @(kLCSettingsVersion),
            @"polling_settings_version": @0,
            @"act_base": @"",
            @"act_data": @"",
            @"sdk_version": @"9.9.9",
        },
        @"need_token_params": @1,
        @"BDXBridgeDefaultParamKey": @{@"scene": @"treasure", @"common_args": common},
        @"scene": @"treasure",
        @"common_args": common,
    };
}

// 每个任务 key 对应自己的领取路径
static NSString *LCClaimPath(NSString *key) {
    if (!key) return @"/polaris/task/do_action";
    if ([key containsString:@"listen"])      return @"/luna/treasure/task/listen_music/do_action";
    if ([key containsString:@"red_packet"])  return @"/luna/treasure/task/red_packet_rain/do_action/v2";
    if ([key containsString:@"flip_card"])   return @"/luna/treasure/task/flip_card/do_action";
    if ([key containsString:@"sign_in"])     return @"/luna/treasure/task/sign_in/do_action";
    return @"/polaris/task/do_action";
}

#pragma mark - 会话初始化

// 从已抓到的流量里取 base 与请求头。
// 这样不用额外配置,用户只要正常用过一次 App 就有。
BOOL LCAutoPrepare(void) {
    NSArray *recs = [[LCCapture shared] snapshot];
    for (LCRecord *r in recs.reverseObjectEnumerator) {
        NSString *u = r.url;
        if (![u containsString:@"qishui.com"]) continue;
        if (![u containsString:@"/luna/"]) continue;

        NSURL *nu = [NSURL URLWithString:u];
        if (nu.host.length == 0) continue;

        gAutoBase = [NSString stringWithFormat:@"https://%@", nu.host];
        NSMutableDictionary *h = [NSMutableDictionary dictionary];
        [r.reqHeaders enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            NSString *lk = [k lowercaseString];
            if ([lk isEqualToString:@"content-length"] ||
                [lk isEqualToString:@"accept-encoding"]) return;
            h[lk] = v;
        }];
        gAutoHeaders = h;

        LCAutoLog(@"会话 base=%@ 头=%lu 个", gAutoBase, (unsigned long)h.count);
        return YES;
    }
    LCAutoLog(@"抓包里还没有金币页请求,请先打开一次金币页再运行");
    return NO;
}

#pragma mark - 主流程

static NSArray<NSDictionary *> *LCListenTasks(NSDictionary *page) {
    NSMutableArray *out = [NSMutableArray array];
    NSArray *sections = page[@"data"][@"sections"];
    if (![sections isKindOfClass:[NSArray class]]) return out;

    for (NSDictionary *sec in sections) {
        for (NSString *gk in @[@"task_group", @"widget_task_group"]) {
            NSArray *tasks = sec[gk][@"tasks"];
            if (![tasks isKindOfClass:[NSArray class]]) continue;
            for (NSDictionary *t in tasks) {
                if (![t isKindOfClass:[NSDictionary class]]) continue;

                NSDictionary *view = t[@"view"];
                NSDictionary *btn = view[@"button"];
                NSString *action = btn[@"action"];
                NSString *token = t[@"token"];
                NSString *key = t[@"key"];

                NSDictionary *stats = t[@"stats"];
                NSDictionary *sub = view[@"subtitle"];

                [out addObject:@{
                    @"key": key ?: @"",
                    @"action": action ?: @"",
                    @"token": token ?: @"",
                    @"title": view[@"title"][@"plain_text"] ?: @"",
                    @"sub": sub[@"plain_text"] ?: @"",
                    @"completed": stats[@"completed_times"] ?: @0,
                    @"total": stats[@"total_times"] ?: @0,
                }];
            }
        }
    }
    return out;
}

void LCAutoRun(void) {
    if (gAutoRunning) {
        LCAutoLog(@"上一轮还在跑,跳过");
        return;
    }
    gAutoRunning = YES;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            LCAutoLog(@"==== 开始自动领奖 ====");

            if (!LCAutoPrepare()) { gAutoRunning = NO; return; }

            NSDictionary *page = LCGetJSON(@"/luna/treasure/task/page/v2");
            if (!page) {
                LCAutoLog(@"拉任务页失败");
                gAutoRunning = NO;
                return;
            }
            NSArray *tasks = LCListenTasks(page);
            LCAutoLog(@"任务 %lu 个", (unsigned long)tasks.count);

            NSInteger claimed = 0;
            for (NSDictionary *t in tasks) {
                NSString *key = t[@"key"];
                NSString *action = t[@"action"];
                NSString *token = t[@"token"];
                LCAutoLog(@"· %@ [%@] %@ | token=%lu",
                          key, action, [t[@"sub"] substringToIndex:MIN(28u, [t[@"sub"] length])],
                          (unsigned long)token.length);

                // 只处理"点击即领"的任务;广告/逛街/刷视频要真实曝光,不在这里做
                BOOL claimable = [action isEqualToString:@"do_action"];
                if (!claimable || token.length == 0) continue;

                NSString *path = LCClaimPath(key);
                NSDictionary *body = LCBuildClaimBody(token);
                if (!LCFireJSON(path, body, @"POST")) {
                    LCAutoLog(@"  发送失败,跳过");
                    continue;
                }
                claimed++;

                // 服务端对短时间连续领取会回 8010064 / 1000043,
                // 间隔 3 秒是实测能稳定通过的节奏。
                [NSThread sleepForTimeInterval:3.0];
            }

            [NSThread sleepForTimeInterval:2.0];
            NSDictionary *after = LCGetJSON(@"/luna/treasure/task/page/v2");
            if (after) {
                for (NSDictionary *t in LCListenTasks(after)) {
                    LCAutoLog(@"→ %@ completed=%@/%@ %@",
                              t[@"key"], t[@"completed"], t[@"total"],
                              [t[@"sub"] substringToIndex:MIN(30u, [t[@"sub"] length])]);
                }
            }
            LCAutoLog(@"==== 结束,发出 %ld 次领取 ====", (long)claimed);
            gAutoRunning = NO;
        }
    });
}

BOOL LCAutoBusy(void) { return gAutoRunning; }

// 把全部日志合并成一个文件导出。
// 沙盒 Documents 在「文件」App 里看不到(Info.plist 没开 UIFileSharingEnabled,
// TrollFools 注入也改不了 plist),所以只能走系统分享面板，和 HAR 一样。
NSString *LCAutoExportLog(void) {
    NSArray *ps = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                      NSUserDomainMask, YES);
    if (ps.count == 0) return nil;
    NSString *dir = ps.firstObject;

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"LunaCapture %@\n", LC_VER];
    [out appendFormat:@"导出时间 %@\n", [NSDate date]];

    NSArray *files = @[@[@"lc_auto.txt",   @"自动任务"],
                       @[@"lc_ssl.txt",    @"SSL 挂载"],
                       @[@"lc_hooked.txt", @"hook 清单"],
                       @[@"lc_state.txt",  @"启动状态"]];
    for (NSArray *pair in files) {
        NSString *name = pair[0];
        NSString *p = [dir stringByAppendingPathComponent:name];
        NSString *body = [NSString stringWithContentsOfFile:p
                                                  encoding:NSUTF8StringEncoding
                                                     error:NULL];
        [out appendFormat:@"\n========== %@ (%@) ==========\n", name, pair[1]];
        [out appendString:(body.length ? body : @"(空)")];
        [out appendString:@"\n"];
    }

    NSDateFormatter *f = [NSDateFormatter new];
    f.dateFormat = @"MMdd_HHmmss";
    NSString *outPath = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"luna_log_%@.txt", [f stringFromDate:[NSDate date]]]];

    NSError *err = nil;
    if (![out writeToFile:outPath atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
        LCAutoLog(@"写日志失败: %@", err.localizedDescription);
        return nil;
    }
    return outPath;
}
