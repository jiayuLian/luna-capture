#import "LunaCapture.h"

// TrollStore / TrollFools 环境没有 CydiaSubstrate,
// 因此入口必须走 constructor,不能依赖 Logos 的 %ctor。
__attribute__((constructor))
static void LCInit(void) {
    @autoreleasepool {
        NSLog(@"[LC] dylib loaded · %@", LC_VER);
        // hook 尽早装,才能抓到启动阶段的请求
        LCHookAll();
        // LCSetupUI 内部自带延迟与场景重试,这里不重复等
        LCSetupUI();
    }
}
