//
//  HookTTNet.m
//  iOS 版汽水音乐走 Cronet(TTNet),业务请求完全不经过 NSURLSession。
//  Cronet 的 C++ 层被 strip,但字节 TTNet 的 ObjC 门面方法名是明文,
//  所有请求最终都从门面方法发出。这里在门面层做旁路观察,不改请求本身。
//
//  闪退防护:这段代码运行在别人的进程里,任何越界都是整个 App 挂掉。
//  因此所有反射读取都做了类型白名单,所有 IMP 替换都加了并发锁,
//  拿不到原实现时绝不返回伪造值。
//

#import "LunaCapture.h"
#import <objc/runtime.h>
#import <objc/message.h>

NSString *LCHookInfo = @"ttnet:init";
void LCHookTTNet(void);

// 计数用于诊断:能直接看出 TTNet 通道有没有真的接上
static volatile int gSeen = 0;
static volatile int gSkipped = 0;

NSString *LCStatString(void) {
    return [NSString stringWithFormat:@"%@ seen:%d skip:%d",
            LCHookInfo ?: @"ttnet:none", gSeen, gSkipped];
}

#pragma mark - 反射 dump

// 属性读取白名单:只读对象类型,跳过 C 标量与 NSObject 自带实现
static BOOL LCOwnershipOK(const char *attrs) {
    // 逐段扫逗号后的修饰符,避免把类型名里的字母误判成修饰符。
    // 只认单独的 &(strong) / C(copy) / W(weak)。
    const char *p = attrs;
    while ((p = strchr(p, ',')) != NULL) {
        p++;
        char c = *p;
        if ((c == '&' || c == 'C' || c == 'W') && (p[1] == ',' || p[1] == '\0')) {
            return YES;
        }
    }
    return NO;
}

static BOOL LCPropReadable(const char *name, const char *attrs) {
    if (!name || !attrs) return NO;
    if (strncmp(attrs, "T@", 2) != 0) return NO;
    // 内存语义必须是 strong / copy / weak。
    // 缺省语义是 assign,getter 可能返回已释放的野指针,
    // 对它调 isKindOfClass: 就是 EXC_BAD_ACCESS。
    if (!LCOwnershipOK(attrs)) return NO;

    static NSSet *black = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        black = [NSSet setWithArray:@[@"hash", @"superclass", @"description",
                                      @"debugDescription", @"self", @"class",
                                      @"zone", @"retainCount", @"dealloc"]];
    });
    NSString *n = [NSString stringWithUTF8String:name];
    if (!n || [black containsObject:n]) return NO;
    return YES;
}

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
    if ([obj isKindOfClass:[NSSet class]]) {
        NSSet *st = (NSSet *)obj;
        if (depth <= 0) return [NSString stringWithFormat:@"<set %lu>", (unsigned long)st.count];
        NSMutableArray *out = [NSMutableArray array];
        for (id x in st) {
            id v = LCDumpObj(x, depth - 1, seen);
            [out addObject:v ?: [NSNull null]];
            if (out.count >= 60) break;
        }
        return out;
    }

    // 非 NSObject 派生一律不碰
    if (![obj isKindOfClass:[NSObject class]]) return nil;
    if (depth <= 0) return [NSString stringWithFormat:@"<%@>", NSStringFromClass([obj class])];

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
            const char *pa = property_getAttributes(ps[i]);
            if (!LCPropReadable(pn, pa)) continue;
            NSString *name = [NSString stringWithUTF8String:pn];
            if (!name || out[name]) continue;
            @try {
                id v = [obj valueForKey:name];
                if (v == nil) continue;
                id dv = LCDumpObj(v, depth - 1, seen);
                if (dv) out[name] = dv;
            } @catch (NSException *e) {
                // getter 抛异常或类型不符,跳过
            }
        }
        if (ps) free(ps);
        c = class_getSuperclass(c);
    }

    [seen removeObject:ptr];

    if (out.count == 0) return [NSString stringWithFormat:@"<%@>", NSStringFromClass([obj class])];
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
    NSDictionary *snap = LCDumpObj(task, 2, [NSMutableSet set]);
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
    if (![o isKindOfClass:[NSObject class]]) return NO;
    Class c = object_getClass(o);
    if (!c) return NO;
    const char *cn = class_getName(c);
    if (!cn) return NO;
    // 直接比对 C 字符串,避免构造 NSString 的开销与异常
    return (strstr(cn, "Task") != NULL) || (strstr(cn, "task") != NULL);
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
        NSDictionary *snap = LCDumpObj(task, 2, [NSMutableSet set]);
        LCPollTask(task, snap, 0);
    });
}

#pragma mark - 通用转发

// 用 Method 指针做 key,不是 class+sel。
//
// 这是上一版闪退的根因:class_copyMethodList 只列出「本类实现」的方法,
// 所以表里存的是 (类, sel) 这一对。一旦 App 通过子类调用继承来的同一个
// 方法,object_getClass(self) 是子类,查表落空 → 旧代码直接 return nil,
// 调用者拿到一个不该为 nil 的返回值继续解引用,当场 EXC_BAD_ACCESS。
//
// Method 是同一个结构体指针,父类和子类共用,用它做 key 天然覆盖继承。
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

// 同一条调用链上重入同一实现的深度保护。
// 正常网络方法不会递归,超过这个深度说明 IMP 表出了问题,直接放行不再记录,
// 避免无栈可用。
static __thread int gForwardDepth = 0;


// 统一入口:不假设方法签名,用 NSInvocation 原样转发,
// 唯一动作是取出返回的 task 对象做旁路观察。
static id LCForward(id self, SEL _cmd, ...) {
    Class cls = object_getClass(self);
    Method m = class_getInstanceMethod(cls, _cmd);
    void *op = LCOrigIMPForMethod(m);

    // 表里查不到 = 这个 Method 不是我们换的。正常不可能走到,
    // 真走到了就说明表被破坏,直接返回 nil 比乱调安全。
    if (!op) return nil;

    if (gForwardDepth > 32) {
        // 深度异常,原样放行
        return ((id (*)(id, SEL, ...))op)(self, _cmd);
    }
    gForwardDepth++;

    NSMethodSignature *sig = nil;
    if (m) {
        @try {
            sig = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(m)];
        } @catch (NSException *e) {
            sig = nil;
        }
    }

    if (!sig) {
        gForwardDepth--;
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
        gForwardDepth--;
        return ((id (*)(id, SEL, ...))op)(self, _cmd);
    }

    @try {
        [inv invoke];
    } @catch (NSException *e) {
        gForwardDepth--;
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
    gForwardDepth--;
    return ret;
}

#pragma mark - 安装

// 浮点参数在 arm64 上走 s0-s7,和 va_arg 的通用寄存器序列不一致,
// 与浮点参数沾边的方法一律不 hook,宁可少抓也不能崩。
// 返回类型只接受对象:任务构建方法必然返回 task,返回 void 的一律不碰。
static BOOL LCSigSupported(Method m) {
    const char *types = method_getTypeEncoding(m);
    if (!types) return NO;

    char *rt = method_copyReturnType(m);
    BOOL retOK = (rt && *rt == '@');
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
            case 'l': case 'L': case '^': case '*':
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

    LCEnsureIMPTable();
    if (LCOrigIMPForMethod(m)) return 0;   // 这个 Method 已经换过

    IMP om = method_getImplementation(m);
    if (om == (IMP)LCForward) return 0;

    LCSetOrigIMP(m, om);
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
        const char *sn = sel_getName(sel);
        if (!sn) continue;
        // 只关心会产出 task 的构建方法,其他方法(hook/setup/init)不碰
        if (!strstr(sn, "task") && !strstr(sn, "Task")) continue;
        if (LCSwizzleMethod(cls, sel, ms[i])) {
            hooked++;
            if (names && names.count < 200) [names addObject:[NSString stringWithUTF8String:sn]];
        }
    }
    if (ms) free(ms);

    Class meta = object_getClass(cls);
    if (meta) {
        unsigned int mn = 0;
        Method *mms = class_copyMethodList(meta, &mn);
        for (unsigned int i = 0; i < mn; i++) {
            SEL sel = method_getName(mms[i]);
            const char *sn = sel_getName(sel);
            if (!sn) continue;
            if (!strstr(sn, "task") && !strstr(sn, "Task")) continue;
            if (LCSwizzleMethod(meta, sel, mms[i])) {
                hooked++;
                if (names && names.count < 200) [names addObject:[NSString stringWithUTF8String:sn]];
            }
        }
        if (mms) free(mms);
    }
    return hooked;
}

static NSMutableSet *gHooked = nil;

// 可重复调用。每次都重新扫一遍,新出现的门面类会被补上。
// 不触发 +initialize(不碰 shareInstance),避免在启动早期拉起重依赖。
void LCHookTTNet(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        LCEnsureIMPTable();
        gHooked = [NSMutableSet set];
    });

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

        // 直接 C 字符串匹配,不构造 NSString
        if (!strstr(cn, "TTNetworkManager") &&
            !strstr(cn, "TTNetManager") &&
            !strstr(cn, "NetworkManagerChromium")) {
            continue;
        }
        NSString *n = [NSString stringWithUTF8String:cn];
        if (!n || [gHooked containsObject:n]) continue;

        int h = LCHookOneClass(c, hitNames);
        if (h > 0) {
            [gHooked addObject:n];
            totalHooked += h;
        }
    }
    free(classes);

    if (totalHooked > 0) {
        LCHookInfo = [NSString stringWithFormat:@"ttnet:%d 方法/%lu 类",
                      totalHooked, (unsigned long)gHooked.count];
        NSLog(@"[LC] %@", LCHookInfo);
        for (NSString *s in hitNames) NSLog(@"[LC]   hook %@", s);

        // 落盘一份 hook 清单。万一后面崩了,这份名单是唯一能缩小排查范围的线索。
        NSArray *snapshot = [hitNames copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            @try {
                NSString *d = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                                   NSUserDomainMask, YES) firstObject];
                if (!d.length) return;
                NSMutableString *s = [NSMutableString string];
                [s appendFormat:@"# %@\n", LC_VER];
                for (NSString *n in snapshot) [s appendFormat:@"%@\n", n];
                [s writeToFile:[d stringByAppendingPathComponent:@"lc_hooked.txt"]
                    atomically:YES
                      encoding:NSUTF8StringEncoding
                         error:NULL];
            } @catch (NSException *e) {}
        });
    }
}
