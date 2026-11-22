//
//  HookTTNet.m
//  iOS 版汽水音乐走 Cronet(TTNet),业务请求完全不经过 NSURLSession。
//  Cronet 的 C++ 层被 strip,但字节 TTNet 的 ObjC 门面方法名是明文,
//  所有请求最终都从门面方法发出。这里在门面层做旁路观察,不改请求本身。
//

#import "LunaCapture.h"
#import <objc/runtime.h>
#import <objc/message.h>

NSString *LCHookInfo = @"ttnet:init";

#pragma mark - 反射 dump
// 不假设私有对象的字段名。把对象的属性链整个读出来,
// 再从 dump 里按关键字模糊匹配 URL / header / body / status。
// 兜不住的部分原样留在记录的 _ttnet_dump 字段里,导出后仍可人工分析,信息不丢。

static id LCDumpObj(id obj, int depth, NSMutableSet *seen);

static id LCDumpObj(id obj, int depth, NSMutableSet *seen) {
    if (!obj || obj == (id)[NSNull null]) return nil;

    if ([obj isKindOfClass:[NSString class]]) {
        NSString *s = (NSString *)obj;
        return s.length > 16384 ? [s substringToIndex:16384] : s;
    }
    if ([obj isKindOfClass:[NSNumber class]]) {
        return [(NSNumber *)obj description];
    }
    if ([obj isKindOfClass:[NSData class]]) {
        NSData *d = (NSData *)obj;
        if (d.length == 0) return @"";
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s) return s.length > 16384 ? [s substringToIndex:16384] : s;
        return [NSString stringWithFormat:@"base64:%@",
                [d base64EncodedStringWithOptions:0]];
    }
    if ([obj isKindOfClass:[NSArray class]]) {
        NSArray *arr = (NSArray *)obj;
        if (depth <= 0) return [NSString stringWithFormat:@"<array %lu>", (unsigned long)arr.count];
        NSMutableArray *out = [NSMutableArray array];
        for (id x in arr) {
            id v = LCDumpObj(x, depth - 1, seen);
            [out addObject:v ?: [NSNull null]];
            if (out.count >= 60) break;
        }
        return out;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dd = (NSDictionary *)obj;
        if (depth <= 0) return [NSString stringWithFormat:@"<dict %lu>", (unsigned long)dd.count];
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        [dd enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
            NSString *ks = [k description];
            if (ks.length > 160) ks = [ks substringToIndex:160];
            id dv = LCDumpObj(v, depth - 1, seen);
            out[ks] = dv ?: [NSNull null];
        }];
        return out;
    }

    if (depth <= 0) return [obj description];

    NSValue *ptr = [NSValue valueWithPointer:(__bridge const void *)obj];
    if ([seen containsObject:ptr]) return @"<cycle>";
    [seen addObject:ptr];

    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    Class c = [obj class];
    int guard = 0;
    while (c && c != [NSObject class] && guard++ < 8) {
        unsigned int n = 0;
        objc_property_t *ps = class_copyPropertyList(c, &n);
        for (unsigned int i = 0; i < n && out.count < 100; i++) {
            const char *pn = property_getName(ps[i]);
            if (!pn) continue;
            NSString *name = [NSString stringWithUTF8String:pn];
            if (!name || out[name]) continue;
            @try {
                id v = [obj valueForKey:name];
                if (v == nil) continue;
                id dv = LCDumpObj(v, depth - 1, seen);
                if (dv) out[name] = dv;
            } @catch (NSException *e) {
                // 私有属性的 getter 可能抛异常,跳过即可
            }
        }
        if (ps) free(ps);
        c = class_getSuperclass(c);
    }

    [seen removeObject:ptr];

    if (out.count == 0) return [obj description];
    return out;
}

// 在嵌套 dump 里按 key 关键字找第一个标量值
static NSString *LCDeepStr(id node, NSArray<NSString *> *subs, int depth) {
    if (!node || depth < 0) return nil;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)node;
        for (NSString *k in d) {
            NSString *lk = k.lowercaseString;
            for (NSString *sub in subs) {
                if ([lk containsString:sub]) {
                    id v = d[k];
                    if ([v isKindOfClass:[NSString class]] && [v length] > 0) return v;
                    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v description];
                }
            }
        }
        for (NSString *k in d) {
            NSString *r = LCDeepStr(d[k], subs, depth - 1);
            if (r) return r;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id x in (NSArray *)node) {
            NSString *r = LCDeepStr(x, subs, depth - 1);
            if (r) return r;
        }
    }
    return nil;
}

// 在嵌套 dump 里按 key 关键字找第一个字典(用于 header map)
static NSDictionary *LCDeepDict(id node, NSArray<NSString *> *subs, int depth) {
    if (!node || depth < 0) return nil;
    if ([node isKindOfClass:[NSDictionary class]]) {
        NSDictionary *d = (NSDictionary *)node;
        for (NSString *k in d) {
            NSString *lk = k.lowercaseString;
            for (NSString *sub in subs) {
                if ([lk containsString:sub]) {
                    id v = d[k];
                    if ([v isKindOfClass:[NSDictionary class]] && [(NSDictionary *)v count] > 0)
                        return v;
                }
            }
        }
        for (NSString *k in d) {
            NSDictionary *r = LCDeepDict(d[k], subs, depth - 1);
            if (r) return r;
        }
    } else if ([node isKindOfClass:[NSArray class]]) {
        for (id x in (NSArray *)node) {
            NSDictionary *r = LCDeepDict(x, subs, depth - 1);
            if (r) return r;
        }
    }
    return nil;
}

static BOOL LCHasResponse(NSDictionary *snap) {
    NSString *st = LCDeepStr(snap, @[@"statuscode"], 4);
    if (st.length && st.integerValue > 0) return YES;
    NSString *rb = LCDeepStr(snap, @[@"responsebody", @"responsedata"], 4);
    if (rb.length > 2) return YES;
    return NO;
}

#pragma mark - 噪音过滤

// 计数用于诊断:能直接看出 TTNet 通道有没有真的接上
static volatile int gSeen = 0;
static volatile int gSkipped = 0;

NSString *LCStatString(void) {
    return [NSString stringWithFormat:@"%@ seen:%d skip:%d",
            LCHookInfo ?: @"ttnet:none", gSeen, gSkipped];
}

// 媒体分片一律不记:广告视频、歌曲音频会把 8000 条缓冲瞬间冲满,金币接口就被挤没了
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
    // 去掉 query 再判后缀
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

static void LCPollTask(id task, NSDictionary *snap0, int tries);

// 从 task 的 dump 组装一条记录
static void LCFinishTask(id task, NSDictionary *snap, NSString *source) {
    LCEnsureTaskTable();
    [gTaskLock lock];
    [gTasks removeObjectForKey:LCPtrKey(task)];
    [gTaskLock unlock];

    if (!snap) return;

    NSString *url = LCDeepStr(snap, @[@"urlstring", @"absoluteurl", @"requesturl"], 4);
    if (url.length == 0) url = LCDeepStr(snap, @[@"url"], 4);
    if (url.length == 0) return;
    if ([url hasPrefix:@"base64:"]) return;
    // 统计:seen 是 TTNet 层看到的全部请求,skipped 是被媒体/静态过滤掉的
    if (LCSkipURLString(url)) { gSkipped++; return; }
    gSeen++;

    LCRecord *r = [LCRecord new];
    r.url = url;
    r.source = source;

    NSString *m = LCDeepStr(snap, @[@"httpmethod"], 4);
    if (m.length == 0) m = LCDeepStr(snap, @[@"method"], 4);
    r.method = m.length ? m.uppercaseString : @"GET";

    NSDictionary *reqH = LCDeepDict(snap, @[@"requestheader", @"allheaderfield", @"headerfield"], 4);
    if (reqH.count) r.reqHeaders = reqH;

    NSString *rb = LCDeepStr(snap, @[@"httpbody", @"requestbody", @"postdata"], 4);
    if (rb.length && ![rb hasPrefix:@"base64:"]) r.reqBody = rb;

    NSString *st = LCDeepStr(snap, @[@"statuscode", @"httpstatus"], 4);
    r.status = st.length ? st.integerValue : 0;

    NSDictionary *respH = LCDeepDict(snap, @[@"responseheader", @"allheaderfield"], 4);
    if (respH.count) r.respHeaders = respH;

    NSString *rbody = LCDeepStr(snap, @[@"responsebody", @"responsedata", @"contentstring"], 4);
    if (rbody.length) {
        if ([rbody hasPrefix:@"base64:"]) {
            r.respBody = [rbody substringFromIndex:7];
            r.respIsBase64 = YES;
        } else {
            r.respBody = rbody;
        }
    }

    // 保留原始 dump,供事后人工核对字段名
    NSMutableDictionary *h = [(r.respHeaders ?: @{}) mutableCopy];
    NSData *jd = [NSJSONSerialization dataWithJSONObject:snap options:0 error:NULL];
    if (jd) {
        NSString *s = [[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding];
        if (s.length > 65536) s = [s substringToIndex:65536];
        h[@"_ttnet_dump"] = s ?: @"";
    }
    r.respHeaders = h;

    r.start = [NSDate date];
    r.end = r.start;

    [[LCCapture shared] addRecord:r];
}

static void LCPollTask(id task, NSDictionary *snap0, int tries) {
    // task 被 block 捕获,期间不会被释放
    NSDictionary *snap = LCDumpObj(task, 3, [NSMutableSet set]);
    if (!snap) snap = snap0;

    BOOL done = LCHasResponse(snap);
    if (!done && tries < 60) {          // 60 × 0.25s = 15s 上限
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            LCPollTask(task, snap0, tries + 1);
        });
        return;
    }
    LCFinishTask(task, snap, @"ttnet");
}

static BOOL LCLooksLikeTask(id o) {
    if (!o) return NO;
    NSString *cn = NSStringFromClass([o class]);
    if (cn.length == 0) return NO;
    return [cn containsString:@"Task"] || [cn containsString:@"task"];
}

static void LCTrackTask(id task) {
    if (!LCLooksLikeTask(task)) return;
    LCEnsureTaskTable();
    NSString *key = LCPtrKey(task);

    [gTaskLock lock];
    if (gTasks[key]) {                 // 同一个 task 只跟一次
        [gTaskLock unlock];
        return;
    }
    gTasks[key] = @"pending";
    [gTaskLock unlock];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *snap = LCDumpObj(task, 3, [NSMutableSet set]);
        LCPollTask(task, snap, 0);
    });
}

#pragma mark - 通用转发

// 保存被替换掉的原实现,key = 类指针|selector
static NSMutableDictionary<NSString *, NSValue *> *gOrigIMP = nil;

static void *LCOrigIMPFor(Class cls, SEL sel) {
    NSString *k = [NSString stringWithFormat:@"%p|%p", cls, sel];
    NSValue *v = gOrigIMP[k];
    return v ? [v pointerValue] : NULL;
}

// 统一入口:不假设方法签名,用 NSInvocation 原样转发,
// 唯一动作是取出返回的 task 对象做旁路观察。
static id LCForward(id self, SEL _cmd, ...) {
    Class cls = object_getClass(self);
    Method m = class_getInstanceMethod(cls, _cmd);
    void *op = LCOrigIMPFor(cls, _cmd);

    if (!op) return nil;

    NSMethodSignature *sig = nil;
    @try {
        sig = m ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)] : nil;
    } @catch (NSException *e) {
        sig = nil;
    }

    if (!sig) {
        // 拿不到签名就直调原实现,不做记录
        return ((id (*)(id, SEL, ...))op)(self, _cmd);
    }

    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.target = self;
    inv.selector = _cmd;

    va_list ap;
    va_start(ap, _cmd);
    BOOL ok = YES;
    for (NSUInteger i = 2; i < sig.numberOfArguments; i++) {
        const char *t = [sig getArgumentTypeAtIndex:i];
        switch (t[0]) {
            case '@': case '#': case ':': {
                id a = va_arg(ap, id);
                [inv setArgument:&a atIndex:i];
                break;
            }
            case 'B': case 'c': case 'C': case 'i': case 'I':
            case 's': case 'S': {
                int a = va_arg(ap, int);
                [inv setArgument:&a atIndex:i];
                break;
            }
            case 'q': case 'Q': case 'l': case 'L': {
                long long a = va_arg(ap, long long);
                [inv setArgument:&a atIndex:i];
                break;
            }
            case 'f': {
                double a = va_arg(ap, double);
                float f = (float)a;
                [inv setArgument:&f atIndex:i];
                break;
            }
            case 'd': {
                double a = va_arg(ap, double);
                [inv setArgument:&a atIndex:i];
                break;
            }
            case '^': case '*': {
                void *a = va_arg(ap, void *);
                [inv setArgument:&a atIndex:i];
                break;
            }
            default:
                ok = NO;
                break;
        }
        if (!ok) break;
    }
    va_end(ap);

    if (!ok) {
        // 装 hook 时已过滤掉结构体参数,这里只做兜底
        return ((id (*)(id, SEL, ...))op)(self, _cmd);
    }

    @try {
        [inv invoke];
    } @catch (NSException *e) {
        return nil;
    }

    id ret = nil;
    const char *rt = sig.methodReturnType;
    if (rt && rt[0] == '@') {
        [inv getReturnValue:&ret];
        if (ret && ret != (id)[NSNull null]) {
            @try {
                LCTrackTask(ret);
            } @catch (NSException *e) {}
        }
    }
    return ret;
}

#pragma mark - 安装

static BOOL LCSigSupported(Method m) {
    const char *types = method_getTypeEncoding(m);
    if (!types) return NO;

    char *rt = method_copyReturnType(m);
    BOOL retOK = (rt && (*rt == '@' || *rt == 'v'));
    if (rt) free(rt);
    if (!retOK) return NO;

    NSMethodSignature *sig = nil;
    @try {
        sig = [NSMethodSignature signatureWithObjCTypes:types];
    } @catch (NSException *e) {
        return NO;
    }
    if (!sig) return NO;

    for (NSUInteger i = 2; i < sig.numberOfArguments; i++) {
        const char *t = [sig getArgumentTypeAtIndex:i];
        switch (t[0]) {
            case '@': case '#': case ':': case 'B': case 'c': case 'C':
            case 'i': case 'I': case 's': case 'S': case 'q': case 'Q':
            case 'l': case 'L': case 'f': case 'd': case '^': case '*':
                break;
            default:
                return NO;
        }
    }
    return YES;
}

static int LCSwizzleMethod(Class cls, SEL sel, Method m) {
    if (!cls || !sel || !m) return 0;
    if (!LCSigSupported(m)) return 0;

    void *existing = LCOrigIMPFor(cls, sel);
    if (existing) return 0;

    IMP om = method_getImplementation(m);
    // 已经是自己的实现(重复安装),跳过
    if (om == (IMP)LCForward) return 0;

    NSString *k = [NSString stringWithFormat:@"%p|%p", cls, sel];
    gOrigIMP[k] = [NSValue valueWithPointer:(void *)om];
    method_setImplementation(m, (IMP)LCForward);
    return 1;
}

static int LCHookOneClass(Class cls, NSMutableArray<NSString *> *names) {
    if (!cls) return 0;
    int hooked = 0;

    unsigned int n = 0;
    Method *ms = class_copyMethodList(cls, &n);
    for (unsigned int i = 0; i < n; i++) {
        SEL sel = method_getName(ms[i]);
        NSString *ln = NSStringFromSelector(sel).lowercaseString;
        // 只关心会产出 task 的构建方法,其他方法(hook/setup/init)不碰
        if (![ln containsString:@"task"]) continue;
        if (LCSwizzleMethod(cls, sel, ms[i])) {
            hooked++;
            if (names && names.count < 200) [names addObject:NSStringFromSelector(sel)];
        }
    }
    if (ms) free(ms);

    Class meta = object_getClass(cls);
    if (meta) {
        unsigned int mn = 0;
        Method *mms = class_copyMethodList(meta, &mn);
        for (unsigned int i = 0; i < mn; i++) {
            SEL sel = method_getName(mms[i]);
            NSString *ln = NSStringFromSelector(sel).lowercaseString;
            if (![ln containsString:@"task"]) continue;
            if (LCSwizzleMethod(meta, sel, mms[i])) {
                hooked++;
                if (names && names.count < 200) [names addObject:NSStringFromSelector(sel)];
            }
        }
        if (mms) free(mms);
    }
    return hooked;
}

static NSMutableSet *gHooked = nil;

void LCHookTTNet(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gOrigIMP = [NSMutableDictionary dictionary];
        gHooked = [NSMutableSet set];
    });

    // 类名不做硬编码假设:全量扫已加载的类
    int num = objc_getClassList(NULL, 0);
    if (num <= 0) return;
    Class *classes = (Class *)malloc(sizeof(Class) * (size_t)num);
    if (!classes) return;
    num = objc_getClassList(classes, num);

    NSMutableArray<NSString *> *hitNames = [NSMutableArray array];
    int totalHooked = 0;

    for (int i = 0; i < num; i++) {
        Class c = classes[i];
        const char *cn = class_getName(c);
        if (!cn) continue;
        NSString *n = [NSString stringWithUTF8String:cn];
        if (!n || [gHooked containsObject:n]) continue;

        BOOL candidate = ([n containsString:@"TTNetworkManager"] ||
                          [n containsString:@"TTNetManager"] ||
                          [n containsString:@"NetworkManagerChromium"]);
        if (!candidate) continue;

        @try {
            if ([c respondsToSelector:NSSelectorFromString(@"shareInstance")]) {
                [(id)c performSelector:NSSelectorFromString(@"shareInstance")];
            }
        } @catch (NSException *e) {}

        int h = LCHookOneClass(c, hitNames);
        if (h > 0) {
            [gHooked addObject:n];
            totalHooked += h;
        }
    }
    free(classes);

    if (totalHooked > 0) {
        NSString *info = [NSString stringWithFormat:@"ttnet:%d 方法/%lu 类",
                          totalHooked, (unsigned long)gHooked.count];
        LCHookInfo = info;
        NSLog(@"[LC] %@", info);
        for (NSString *s in hitNames) NSLog(@"[LC]   hook %@", s);
    }
}
