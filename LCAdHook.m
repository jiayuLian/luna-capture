//
//  LCAdHook.m
//  激励视频自动化。
//
//  按钮的调用链(从 App 二进制里读出来的):
//    Lynx jsb → BDUGLuckyADRewardedVideoXBridge callWithParamModel:completionHandler:
//             → BDUGLuckyADRewardVideoManager createRewardedVideoWithParams:completion:
//             → __commonVideoAdDidLoadSuccess:
//             → __commonVideoAdBecomeEffective:extraParameters:rewardIndex:callback:  (发奖励)
//             → luckyRewardedVideoAd:didClickCloseWithInfo:
//
//  所以自动化不是伪造请求,而是在进程内调那个 bridge —— 等价于用户点了按钮,
//  广告由 App 自己拉、自己播、自己上报、自己领奖。签名与设备指纹全部由 App 生成。
//
//  第一次跑之前需要手动点一次「看广告赚金币」,把 paramModel 录下来;
//  录到之后就能按同样参数反复触发。
//

#import "LunaCapture.h"
#import <objc/runtime.h>
#import <objc/message.h>

// 从 LCAuto.m 导出
void LCAutoLog(NSString *fmt, ...);

static NSDictionary *gAdParamModel = nil;      // 录到的 jsb 参数
static NSDictionary *gAdEffectiveExtra = nil;  // becomeEffective 的 extraParameters
static __unsafe_unretained id gAdBridgeInst = nil;  // 录参数时的 bridge 实例
static NSLock *gAdLock = nil;
static BOOL gAdHooked = NO;
static volatile BOOL gAdBusy = NO;
static NSInteger gAdRemain = 0;
static NSInteger gAdTotalCount = 0;

#pragma mark - 工具

static NSString *LCJSONText(id obj) {
    if (!obj) return @"nil";
    if ([obj isKindOfClass:[NSString class]]) return obj;
    if (![NSJSONSerialization isValidJSONObject:obj]) {
        return [[obj description] substringToIndex:MIN(300u, [[obj description] length])];
    }
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
    if (!d) return @"<unserializable>";
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return s.length > 900 ? [s substringToIndex:900] : s;
}

#pragma mark - hook

typedef void (*LCBridgeCallIMP)(id, SEL, id, id);
static LCBridgeCallIMP gOrigBridgeCall = NULL;

// 一次真实的「看广告」点击会把 paramModel 送进来,这里记下来给循环复用。
static void LCBridgeCall(id self, SEL _cmd, id paramModel, id completion) {
    if ([paramModel isKindOfClass:[NSDictionary class]]) {
        if (!gAdLock) gAdLock = [NSLock new];
        [gAdLock lock];
        gAdParamModel = [(NSDictionary *)paramModel copy];
        gAdBridgeInst = self;
        [gAdLock unlock];
        LCAutoLog(@"[ad] 录到 paramModel: %@", LCJSONText(paramModel));
    } else {
        LCAutoLog(@"[ad] bridge 参数类型 %@", NSStringFromClass([paramModel class]));
    }
    if (gOrigBridgeCall) gOrigBridgeCall(self, _cmd, paramModel, completion);
}

typedef void (*LCEffIMP)(id, SEL, id, id, NSInteger, id);
static LCEffIMP gOrigEff = NULL;

// 广告播到"生效"时走这里。extraParameters 里带着 effective_inspire_time
// 和 post_done_extra,是奖励金额的判据来源。
static void LCEff(id self, SEL _cmd, id ad, id extra, NSInteger idx, id cb) {
    if ([extra isKindOfClass:[NSDictionary class]]) {
        if (!gAdLock) gAdLock = [NSLock new];
        [gAdLock lock];
        gAdEffectiveExtra = [(NSDictionary *)extra copy];
        [gAdLock unlock];
        LCAutoLog(@"[ad] 生效 extra=%@ idx=%ld", LCJSONText(extra), (long)idx);
    }
    if (gOrigEff) gOrigEff(self, _cmd, ad, extra, idx, cb);
}

static BOOL LCSwizzle(Class c, SEL sel, IMP repl, IMP *orig) {
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NO;
    IMP cur = method_getImplementation(m);
    if (cur == repl) return YES;                 // 已装
    if (orig) *orig = cur;
    method_setImplementation(m, repl);
    return YES;
}

// 类在 App 运行中才注册,所以按 0.5s 间隔重试,一共 20 秒。
void LCAdHookInstall(void) {
    if (gAdHooked) return;

    Class bridge = NSClassFromString(@"BDUGLuckyADRewardedVideoXBridge");
    Class mgr    = NSClassFromString(@"BDUGLuckyADRewardVideoManager");

    BOOL ok = NO;
    if (bridge) {
        SEL s = NSSelectorFromString(@"callWithParamModel:completionHandler:");
        if (LCSwizzle(bridge, s, (IMP)LCBridgeCall, (IMP *)&gOrigBridgeCall)) {
            LCAutoLog(@"[ad] hook bridge 成功");
            ok = YES;
        }
    }
    if (mgr) {
        SEL s = NSSelectorFromString(
            @"__commonVideoAdBecomeEffective:extraParameters:rewardIndex:callback:");
        if (LCSwizzle(mgr, s, (IMP)LCEff, (IMP *)&gOrigEff)) {
            LCAutoLog(@"[ad] hook becomeEffective 成功");
            ok = YES;
        }
    }
    if (!ok) {
        LCAutoLog(@"[ad] 类还没加载,稍后重试");
        return;
    }
    gAdHooked = YES;
}

BOOL LCAdHasTemplate(void) {
    if (!gAdLock) return gAdParamModel != nil;
    [gAdLock lock];
    BOOL has = (gAdParamModel.count > 0);
    [gAdLock unlock];
    return has;
}

NSString *LCAdTemplateText(void) {
    if (!gAdLock) return LCJSONText(gAdParamModel);
    [gAdLock lock];
    NSString *s = LCJSONText(gAdParamModel);
    [gAdLock unlock];
    return s;
}

#pragma mark - 循环触发

// bridge 实例按 Lynx 页面的生命周期创建,不能自己 new 一个出来
// (XBridge 需要注册到 bridge center)。所以复用录参数时拿到的那一个。
static void LCAdTick(void) {
    if (gAdRemain <= 0) {
        gAdBusy = NO;
        LCAutoLog(@"[ad] 循环结束");
        return;
    }
    gAdRemain--;

    id bridge = gAdBridgeInst;
    if (!bridge || !gAdParamModel) {
        LCAutoLog(@"[ad] 没有可复用的 bridge 实例,停止");
        gAdBusy = NO;
        gAdRemain = 0;
        return;
    }

    LCAutoLog(@"[ad] 第 %ld 次触发(剩 %ld)", (long)(gAdTotalCount - gAdRemain), (long)gAdRemain);

    @try {
        SEL s = NSSelectorFromString(@"callWithParamModel:completionHandler:");
        NSMethodSignature *sig = [bridge methodSignatureForSelector:s];
        if (!sig) {
            LCAutoLog(@"[ad] bridge 不支持该方法");
            gAdBusy = NO;
            return;
        }
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        [inv setTarget:bridge];
        [inv setSelector:s];
        id pm = gAdParamModel;
        id cb = nil;
        [inv setArgument:&pm atIndex:2];
        [inv setArgument:&cb atIndex:3];
        [inv invoke];
    } @catch (NSException *e) {
        LCAutoLog(@"[ad] 调用异常: %@", e.reason);
        gAdBusy = NO;
        return;
    }

    // 广告本身 30 秒,加上拉取与上报,留 48 秒再下一次。
    // 间隔太短会撞上服务端的 ad_coin_cool_sec 冷却。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(48 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ LCAdTick(); });
}

void LCAdRun(NSInteger times) {
    if (gAdBusy) {
        LCAutoLog(@"[ad] 上一轮还在跑");
        return;
    }
    if (!LCAdHasTemplate()) {
        LCAutoLog(@"[ad] 还没有参数样本:先在 App 里手动点一次「看广告赚金币」");
        return;
    }
    if (times <= 0) times = 1;
    if (times > 20) times = 20;            // 上限,防止误操作刷一整夜

    gAdBusy = YES;
    gAdTotalCount = times;
    gAdRemain = times;
    LCAutoLog(@"[ad] 开始 %ld 次,每次约 48 秒", (long)times);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ LCAdTick(); });
}

BOOL LCAdBusy(void) { return gAdBusy; }
NSDictionary *LCAdEffectiveExtra(void) { return gAdEffectiveExtra; }
