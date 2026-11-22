#import "LunaCapture.h"

// ============================================================
// 闪退防护
// 这段代码跑在别人的进程里,一旦崩就是整个 App 挂掉,而且用户只会
// 看到"闪退",拿不到任何原因。所以这里做两件事:
//   1. 记录上次启动是否走完,没走完说明崩在那一段,下次自动降级
//   2. 未捕获异常写进 Documents/lc_crash.log,把原因带出来
// ============================================================

#define LC_TAG_OK       @"ok"        // 上次完整模式正常
#define LC_TAG_PENDING  @"pending"   // 本次完整模式启动中(若残留 = 上次崩了)
#define LC_TAG_SAFE     @"safe-ok"   // 安全模式正常,保持安全模式

static NSString *LCStateDir(void) {
    // 必须等沙盒容器就绪才能拿到路径,所以在 main queue 延迟后取
    return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                NSUserDomainMask, YES) firstObject];
}

static NSString *LCStatePath(void) {
    NSString *d = LCStateDir();
    return d.length ? [d stringByAppendingPathComponent:@"lc_state.txt"] : nil;
}

static NSString *LCReadState(void) {
    NSString *p = LCStatePath();
    if (!p) return @"";
    NSString *s = [NSString stringWithContentsOfFile:p
                                           encoding:NSUTF8StringEncoding
                                              error:NULL];
    return s ?: @"";
}

static void LCWriteState(NSString *s) {
    NSString *p = LCStatePath();
    if (!p) return;
    @try {
        [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    } @catch (NSException *e) {}
}

static NSUncaughtExceptionHandler *gPrevHandler = NULL;

static void LCExceptionHandler(NSException *e) {
    @try {
        NSMutableString *s = [NSMutableString string];
        [s appendFormat:@"time: %@\n", [NSDate date]];
        [s appendFormat:@"name: %@\n", e.name];
        [s appendFormat:@"reason: %@\n", e.reason];
        [s appendString:@"--- callStackSymbols ---\n"];
        [s appendString:[[e callStackSymbols] componentsJoinedByString:@"\n"]];
        [s appendString:@"\n--- callStackReturnAddresses ---\n"];
        [s appendString:[[e callStackReturnAddresses] componentsJoinedByString:@"\n"]];
        [s appendString:@"\n"];
        NSString *d = LCStateDir();
        if (d.length) {
            NSString *p = [d stringByAppendingPathComponent:@"lc_crash.log"];
            [s writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            // 标记本次未走完,下次启动自动降级为安全模式
            LCWriteState(LC_TAG_PENDING);
        }
    } @catch (NSException *ignored) {}

    if (gPrevHandler) gPrevHandler(e);
}

// ============================================================

// TTNet 门面类在 App 首次触达前可能还不存在,做 10 秒窗口的重复尝试。
static void LCRetryTTNet(int tries) {
    LCHookTTNet();
    if (tries < 20) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LCRetryTTNet(tries + 1);
        });
    }
}

// 状态判断必须在沙盒容器就绪后做,constructor 阶段取不到路径
static void LCStartupSchedulers(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSString *st = LCReadState();
        BOOL full = YES;
        if ([st hasPrefix:@"safe"]) full = NO;         // 已降级过,保持
        else if ([st hasPrefix:@"pending"]) full = NO; // 上次没走完 = 崩了

        // 先写 pending,10 秒后如果进程还活着再改成 ok / safe-ok
        LCWriteState(LC_TAG_PENDING);

        if (full) {
            LCHookTTNet();
            LCRetryTTNet(0);
        } else {
            LCHookInfo = @"safe-mode(上次启动崩溃,TTNet 通道已禁用)";
            NSLog(@"[LC] 安全模式:TTNet 通道已禁用");
        }

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LCWriteState(full ? LC_TAG_OK : LC_TAG_SAFE);
        });
    });
}

// TrollStore / TrollFools 环境没有 CydiaSubstrate,
// 因此入口必须走 constructor,不能依赖 Logos 的 %ctor。
__attribute__((constructor))
static void LCInit(void) {
    @autoreleasepool {
        NSLog(@"[LC] dylib loaded · %@", LC_VER);

        gPrevHandler = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(&LCExceptionHandler);

        // 只有 NSURLSession 通道是历史验证过的,先在 constructor 装好
        LCHookAll();
        LCStartupSchedulers();

        // LCSetupUI 内部自带延迟与场景重试,这里不重复等
        LCSetupUI();
    }
}
