#import "LunaCapture.h"

// TrollStore / TrollFools 环境没有 CydiaSubstrate,
// 因此入口必须走 constructor,不能依赖 Logos 的 %ctor。
__attribute__((constructor))
static void LCInit(void) {
    @autoreleasepool {
        NSLog(@"[LC] dylib loaded · %@", LC_VER);
        // hook 尽早装,才能抓到启动阶段的请求
        LCHookAll();
        // UI 等 UIKit 就绪
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            LCSetupUI();
        });
    }
}
