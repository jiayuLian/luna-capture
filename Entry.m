#import "LunaCapture.h"

// TTNet 的门面类可能在 dylib 加载之后才被 App 首次触达,
// 单次尝试容易落空,这里做 30 秒窗口的重复尝试。
static void LCRetryTTNet(int tries) {
    LCHookTTNet();
    if (tries < 60) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            LCRetryTTNet(tries + 1);
        });
    }
}

// TrollStore / TrollFools 环境没有 CydiaSubstrate,
// 因此入口必须走 constructor,不能依赖 Logos 的 %ctor。
__attribute__((constructor))
static void LCInit(void) {
    @autoreleasepool {
        NSLog(@"[LC] dylib loaded · %@", LC_VER);
        // hook 尽早装,才能抓到启动阶段的请求
        LCHookAll();
        // iOS 版业务请求走 Cronet,这条通道才是主力
        LCHookTTNet();
        LCRetryTTNet(0);
        // LCSetupUI 内部自带延迟与场景重试,这里不重复等
        LCSetupUI();
    }
}
