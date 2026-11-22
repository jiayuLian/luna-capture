//
//  LCAdHook.m
//  激励视频全自动:开广告 → 播够时长 → 自动关 → 领奖 → 下一轮
//
//  从 21.7.0 主二进制里读出来的真实链路(不是猜的):
//    Lynx jsb  → BDUGLuckyADRewardedVideoXBridge
//                  - callWithParamModel:completionHandler:
//              → BDUGLuckyADRewardVideoManager
//                  - createRewardedVideoWithParams:completion:
//                  - __commonVideoAdDidLoadSuccess:                       广告就绪
//                  - luckyRewardedVideoAdDidLoadSuccess:                  同上(老通道)
//                  - __commonVideoAdBecomeEffective:extraParameters:rewardIndex:callback:
//                  - luckyRewardedVideoAdBecomeEffective:extraParams:callback:
//                  - __commonVideoAd:didClickCloseWithInfo:               关闭(发 do_action)
//                  - luckyRewardedVideoAd:didClickCloseWithInfo:          关闭(csj 通道)
//                  - __commonVideoAdMoreRewardDisplayInfo:index:extraParams:callBack:
//  字符串表里还有 closeAdAfterAwarded / hasIssuedReward / awardedCount / rewardedIndex
//  / __handleRewardVideoCloseWithAdVideoModel: / setAdRewardedVideoController:，
//  说明关闭动作由 SDK 自己走 __handleRewardVideoCloseWithAdVideoModel:，
//  所以「自动关」必须真的去触发关闭按钮，直接 dismiss VC 不会发奖。
//
//  实测数据(2026-11-23 抓包):
//    inspire_send 17:25:50  →  do_action 17:26:06，间隔 16 秒
//    time_token payload: {"effective_inspire_time":15}
//    => 播够 16 秒就能领，不用等 30 秒片尾
//

#import "LunaCapture.h"
#import <objc/runtime.h>
#import <objc/message.h>

void LCAutoLog(NSString *fmt, ...);

// 广告要播多久，由服务端决定：inspire_preload 响应里的 effective_inspire_time
// 实测出现过 15 / 20 / 30，还有 0（这时按 launch_duration 的 20 算）。
// 写死 16 秒的后果：遇到 20/30 的广告会提前关掉，单次可能侥幸过，
// 攒几次就被判"违规操作"——这正是跳过广告脚本被封的原因。
// 所以这里改成运行时取，gAdPlaySeconds 由 LCAdNotePreloadResponse() 刷新。
static NSInteger gAdPlaySeconds = 22;   // 默认 20 + 2 秒余量
// 关掉之后再等一会儿让 App 把 do_action 发完，然后进下一轮
static const NSInteger kAdCooldown   = 5;

static NSDictionary *gAdParamModel = nil;      // 录到的 jsb 参数(字典形态)
static id gAdModelObj = nil;                   // 录到的 paramModel 对象(模板)
static NSString *gAdFreshToken = nil;          // 从任务页响应里解出来的最新 token
static __unsafe_unretained id gAdBridgeInst = nil;
static NSDictionary *gAdEffectiveExtra = nil;
static NSLock *gAdLock = nil;
static BOOL gAdHooked = NO;

static volatile BOOL gAdBusy = NO;
static volatile BOOL gAdOpening = NO;          // 已调 bridge，等 DidLoadSuccess
static volatile BOOL gAdPlaying = NO;          // 广告已在播
static volatile BOOL gAdClosing = NO;          // 已触发关闭，等 close 回调
static volatile BOOL gAdSawClose = NO;
static NSInteger gAdRemain = 0;
static NSInteger gAdTotalCount = 0;
static NSTimeInterval gAdPlayStart = 0;
static NSTimeInterval gAdOpenAt = 0;
static NSTimeInterval gAdCloseTryAt = 0;   // 上次尝试关闭的时刻，用于限流重试
static NSTimer *gAdTimer = nil;

#pragma mark - 工具

static NSString *LCJSONText(id obj) {
    if (!obj) return @"nil";
    if ([obj isKindOfClass:[NSString class]]) return obj;
    if (![NSJSONSerialization isValidJSONObject:obj]) {
        NSString *d = [obj description] ?: @"";
        return d.length > 300 ? [d substringToIndex:300] : d;
    }
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
    if (!d) return @"<unserializable>";
    NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
    return s.length > 900 ? [s substringToIndex:900] : s;
}

// 反射 dump 模型对象。字符串上限 2000 —— 之前截到 120，
// 结果广告 token(280 字符)只看到前 120，误以为 token 是短的。
static NSString *LCDumpObject(id obj, int depth) {
    if (!obj) return @"nil";
    if ([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]]) {
        NSString *v = [obj description] ?: @"";
        return v.length > 2000 ? [v substringToIndex:2000] : v;
    }
    if (depth > 2) return [NSString stringWithFormat:@"<%@>", NSStringFromClass([obj class])];

    NSMutableString *s = [NSMutableString stringWithFormat:@"<%@ {", NSStringFromClass([obj class])];
    unsigned int n = 0;
    objc_property_t *props = class_copyPropertyList([obj class], &n);
    int shown = 0;
    for (unsigned int i = 0; props && i < n && shown < 60; i++) {
        const char *nm = property_getName(props[i]);
        const char *attrs = property_getAttributes(props[i]);
        if (!nm || !attrs) continue;
        // 只读对象类型 T@"..."。C 标量跳过，避免读到野指针
        if (attrs[0] != 'T' || attrs[1] != '@') continue;
        NSString *key = [NSString stringWithUTF8String:nm];
        if ([key isEqualToString:@"hash"] || [key isEqualToString:@"superclass"] ||
            [key isEqualToString:@"description"] || [key isEqualToString:@"debugDescription"])
            continue;
        @try {
            id v = [obj valueForKey:key];
            if (!v) continue;
            [s appendFormat:@"%@=%@; ", key, LCDumpObject(v, depth + 1)];
            shown++;
        } @catch (NSException *e) { }
    }
    if (props) free(props);
    [s appendString:@"}>"];
    return s;
}

static UIWindow *LCKeyWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) return w;
            }
        }
    }
    return [UIApplication sharedApplication].keyWindow;
}

static UIViewController *LCTopVC(void) {
    UIViewController *top = LCKeyWindow().rootViewController;
    if (!top) return nil;
    while (top.presentedViewController) top = top.presentedViewController;
    // 容器型 VC 要下钻到 selected
    if ([top isKindOfClass:[UITabBarController class]])
        return ((UITabBarController *)top).selectedViewController ?: top;
    if ([top isKindOfClass:[UINavigationController class]])
        return ((UINavigationController *)top).topViewController ?: top;
    return top;
}

// 在视图树里找"右上角的可点控件"——激励视频的关闭按钮都在那儿。
// 倒序遍历 subviews:后添加的在最上层，先命中才是用户看到的那个。
static UIControl *LCFindCloseControl(UIView *v, CGRect winRect, int depth) {
    if (!v || v.hidden || v.alpha < 0.05 || !v.userInteractionEnabled) return nil;
    if (depth > 24) return nil;

    if ([v isKindOfClass:[UIControl class]]) {
        UIControl *c = (UIControl *)v;
        CGRect f = [v convertRect:v.bounds toView:nil];
        BOOL topRight = (f.origin.x > winRect.size.width * 0.52 &&
                         f.origin.y < winRect.size.height * 0.42 &&
                         f.size.width >= 12 && f.size.height >= 12 &&
                         f.size.width < winRect.size.width * 0.55);
        if (topRight && c.enabled) return c;
    }
    for (UIView *s in [v.subviews reverseObjectEnumerator]) {
        UIControl *c = LCFindCloseControl(s, winRect, depth + 1);
        if (c) return c;
    }
    return nil;
}

// 有些关闭按钮是 UIImageView + UITapGestureRecognizer，不是 UIControl
static UIView *LCFindCloseGestureView(UIView *v, CGRect winRect, int depth) {
    if (!v || v.hidden || v.alpha < 0.05 || depth > 24) return nil;
    if (v.gestureRecognizers.count > 0 && v.userInteractionEnabled) {
        CGRect f = [v convertRect:v.bounds toView:nil];
        if (f.origin.x > winRect.size.width * 0.52 &&
            f.origin.y < winRect.size.height * 0.42 &&
            f.size.width >= 14 && f.size.height >= 14) {
            return v;
        }
    }
    for (UIView *s in [v.subviews reverseObjectEnumerator]) {
        UIView *hit = LCFindCloseGestureView(s, winRect, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

#pragma mark - 自动关闭

static void LCScheduleNext(void);
id LCAdTrigger(void);

static void LCForceCloseAd(void) {
    if (!gAdPlaying || gAdClosing) return;
    gAdClosing = YES;

    UIWindow *kw = LCKeyWindow();
    CGRect wr = kw ? kw.bounds : [UIScreen mainScreen].bounds;

    UIViewController *top = LCTopVC();
    UIView *root = kw ?: top.view;

    // 1) 优先点真的关闭按钮 —— 只有这条路径会走 SDK 的
    //    __handleRewardVideoCloseWithAdVideoModel:，进而触发 do_action
    UIControl *btn = LCFindCloseControl(root, wr, 0);
    if (!btn && top) btn = LCFindCloseControl(top.view, wr, 0);
    if (btn) {
        LCAutoLog(@"[ad] 点关闭按钮 <%@ %.0fx%.0f>",
                  NSStringFromClass([btn class]),
                  btn.frame.size.width, btn.frame.size.height);
        [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        return;
    }

    // 2) 退化到带手势的图片按钮
    UIView *gv = LCFindCloseGestureView(root, wr, 0);
    if (!gv && top) gv = LCFindCloseGestureView(top.view, wr, 0);
    if (gv) {
        UITapGestureRecognizer *tap =
            [[UITapGestureRecognizer alloc] initWithTarget:nil action:NULL];
        LCAutoLog(@"[ad] 手势视图 <%@>，模拟单击",
                  NSStringFromClass([gv class]));
        // 直接给 recognizer 的 target 发事件拿不到 target 列表，
        // 所以走 hitTest 派发一次触摸更可靠
        CGPoint p = [gv convertPoint:CGPointMake(gv.bounds.size.width / 2,
                                                gv.bounds.size.height / 2)
                              toView:kw];
        [gv hitTest:p withEvent:nil];
        // 兜底：直接 dismiss
        [top dismissViewControllerAnimated:YES completion:nil];
        LCAutoLog(@"[ad] 手势视图无 target，直接 dismiss");
        return;
    }

    // 3) 最后兜底：dismiss 顶层 VC。
    //    这条路能关掉广告但不一定发奖，日志里会标出来便于判断。
    if (top.presentingViewController) {
        LCAutoLog(@"[ad] 没找到关闭按钮，dismiss <%@>",
                  NSStringFromClass([top class]));
        [top dismissViewControllerAnimated:YES completion:nil];
    } else {
        LCAutoLog(@"[ad] 顶层 VC 不是 modal，无法关闭");
    }
}

static void LCTick(void) {
    if (!gAdBusy) { [gAdTimer invalidate]; gAdTimer = nil; return; }

    if (gAdSawClose) {
        [gAdTimer invalidate]; gAdTimer = nil;
        gAdSawClose = NO;
        gAdPlaying = NO;
        gAdClosing = NO;
        gAdOpening = NO;
        // 关掉后给 App 留时间把 do_action 发完
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAdCooldown * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ LCScheduleNext(); });
        return;
    }

    if (gAdPlaying && !gAdSawClose) {
        NSTimeInterval el = [[NSDate date] timeIntervalSince1970] - gAdPlayStart;
        if (el >= gAdPlaySeconds) {
            // 点关闭允许重试：第一次可能点到别的控件或按钮还没出来。
            // 每 5 秒重试一次，最多重试到 kAdMinSeconds+25。
            BOOL due = (gAdCloseTryAt <= 0) ||
                       ([[NSDate date] timeIntervalSince1970] - gAdCloseTryAt >= 5);
            if (due) {
                gAdCloseTryAt = [[NSDate date] timeIntervalSince1970];
                gAdClosing = NO;          // 解锁，让 LCForceCloseAd 真正执行
                LCForceCloseAd();
            }
            if (el > gAdPlaySeconds + 25) {
                LCAutoLog(@"[ad] %ld 秒还没关掉，放弃本轮", (long)(gAdPlaySeconds + 25));
                gAdSawClose = YES;        // 强行推进下一轮
            }
        }
    } else if (gAdOpening) {
        // DidLoadSuccess 没来（素材拉取失败 / 广告已无库存），20 秒算本轮失败
        if (gAdOpenAt > 0 &&
            [[NSDate date] timeIntervalSince1970] - gAdOpenAt > 20) {
            LCAutoLog(@"[ad] 20 秒内没收到 DidLoadSuccess，本轮作废");
            gAdOpenAt = 0;
            gAdOpening = NO;
            gAdSawClose = YES;   // 借 close 分支推进下一轮
        }
    }
}

static void LCScheduleNext(void) {
    if (!gAdBusy) return;
    if (gAdRemain <= 0) {
        gAdBusy = NO;
        LCAutoLog(@"[ad] 全部完成，共 %ld 次", (long)gAdTotalCount);
        return;
    }
    gAdRemain--;
    LCAutoLog(@"[ad] 第 %ld/%ld 轮",
              (long)(gAdTotalCount - gAdRemain), (long)gAdTotalCount);
    (void)LCAdTrigger();
}

#pragma mark - hook

typedef void (*LCBridgeCallIMP)(id, SEL, id, id);
typedef void (*LC1IMP)(id, SEL, id);
typedef void (*LC3IMP)(id, SEL, id, id, id);
typedef void (*LC4IMP)(id, SEL, id, id, NSInteger, id);
typedef void (*LC2IMP)(id, SEL, id, id);

static LCBridgeCallIMP gOrigBridgeCall = NULL;
static LC1IMP gOrigDidLoad = NULL;
static LC1IMP gOrigDidLoad2 = NULL;
static LC3IMP gOrigEff3 = NULL;
static LC4IMP gOrigEff4 = NULL;
static LC2IMP gOrigClose = NULL;
static LC2IMP gOrigClose2 = NULL;

static void LCBridgeCall(id self, SEL _cmd, id paramModel, id completion) {
    if ([paramModel isKindOfClass:[NSDictionary class]]) {
        if (!gAdLock) gAdLock = [NSLock new];
        [gAdLock lock];
        gAdParamModel = [(NSDictionary *)paramModel copy];
        gAdBridgeInst = self;
        [gAdLock unlock];
        LCAutoLog(@"[ad] 录到字典 paramModel: %@", LCJSONText(paramModel));
    } else if (paramModel) {
        if (!gAdLock) gAdLock = [NSLock new];
        [gAdLock lock];
        gAdModelObj = paramModel;
        gAdBridgeInst = self;
        [gAdLock unlock];
        LCAutoLog(@"[ad] 录到对象 paramModel: %@", LCDumpObject(paramModel, 0));
    }
    if (gOrigBridgeCall) gOrigBridgeCall(self, _cmd, paramModel, completion);
}

static void LCHandleDidLoad(NSString *tag) {
    if (!gAdBusy) return;
    gAdOpening = NO;
    gAdPlaying = YES;
    gAdClosing = NO;
    gAdPlayStart = [[NSDate date] timeIntervalSince1970];
    LCAutoLog(@"[ad] 广告就绪(%@)，%ld 秒后自动关闭", tag, (long)gAdPlaySeconds);
}

static void LCDidLoad1(id self, SEL _cmd, id ad) {
    LCHandleDidLoad(@"common");
    if (gOrigDidLoad) gOrigDidLoad(self, _cmd, ad);
}
static void LCDidLoad2(id self, SEL _cmd, id ad) {
    LCHandleDidLoad(@"lucky");
    if (gOrigDidLoad2) gOrigDidLoad2(self, _cmd, ad);
}

static void LCHandleEffective(id extra, long idx) {
    if ([extra isKindOfClass:[NSDictionary class]]) {
        if (!gAdLock) gAdLock = [NSLock new];
        [gAdLock lock];
        gAdEffectiveExtra = [(NSDictionary *)extra copy];
        [gAdLock unlock];
        NSString *t = LCJSONText(extra);
        LCAutoLog(@"[ad] 生效 extra(%ld)=%@", idx,
                  t.length > 700 ? [t substringToIndex:700] : t);
    }
    // 生效即说明时长够了，不用等满 kAdMinSeconds，立刻关
    if (gAdBusy && gAdPlaying && !gAdClosing) {
        LCAutoLog(@"[ad] 已生效，提前关闭");
        LCForceCloseAd();
    }
}

static void LCEff4(id self, SEL _cmd, id ad, id extra, NSInteger idx, id cb) {
    LCHandleEffective(extra, (long)idx);
    if (gOrigEff4) gOrigEff4(self, _cmd, ad, extra, idx, cb);
}
static void LCEff3(id self, SEL _cmd, id ad, id extra, id cb) {
    LCHandleEffective(extra, 0);
    if (gOrigEff3) gOrigEff3(self, _cmd, ad, extra, cb);
}

static void LCClose1(id self, SEL _cmd, id ad, id info) {
    if (gAdBusy) {
        LCAutoLog(@"[ad] 关闭(common) info=%@",
                  info ? LCJSONText(info) : @"nil");
        gAdSawClose = YES;
    }
    if (gOrigClose) gOrigClose(self, _cmd, ad, info);
}
static void LCClose2(id self, SEL _cmd, id ad, id info) {
    if (gAdBusy) {
        LCAutoLog(@"[ad] 关闭(lucky) info=%@",
                  info ? LCJSONText(info) : @"nil");
        gAdSawClose = YES;
    }
    if (gOrigClose2) gOrigClose2(self, _cmd, ad, info);
}

static BOOL LCSwizzle(Class c, SEL sel, IMP repl, IMP *orig) {
    if (!c) return NO;
    Method m = class_getInstanceMethod(c, sel);
    if (!m) return NO;
    IMP cur = method_getImplementation(m);
    if (cur == repl) return YES;
    if (orig) *orig = cur;
    method_setImplementation(m, repl);
    return YES;
}

void LCAdHookInstall(void) {
    if (gAdHooked) return;

    Class bridge = NSClassFromString(@"BDUGLuckyADRewardedVideoXBridge");
    Class mgr    = NSClassFromString(@"BDUGLuckyADRewardVideoManager");
    int ok = 0;

    if (bridge) {
        if (LCSwizzle(bridge, @selector(callWithParamModel:completionHandler:),
                      (IMP)LCBridgeCall, (IMP *)&gOrigBridgeCall)) {
            LCAutoLog(@"[ad] hook bridge");
            ok++;
        }
    }
    if (mgr) {
        if (LCSwizzle(mgr, NSSelectorFromString(@"__commonVideoAdDidLoadSuccess:"),
                      (IMP)LCDidLoad1, (IMP *)&gOrigDidLoad)) {
            LCAutoLog(@"[ad] hook DidLoadSuccess");
            ok++;
        }
        if (LCSwizzle(mgr, NSSelectorFromString(@"luckyRewardedVideoAdDidLoadSuccess:"),
                      (IMP)LCDidLoad2, (IMP *)&gOrigDidLoad2)) {
            LCAutoLog(@"[ad] hook luckyDidLoadSuccess");
            ok++;
        }
        if (LCSwizzle(mgr, NSSelectorFromString(
                @"__commonVideoAdBecomeEffective:extraParameters:rewardIndex:callback:"),
                      (IMP)LCEff4, (IMP *)&gOrigEff4)) {
            LCAutoLog(@"[ad] hook becomeEffective(4)");
            ok++;
        }
        if (LCSwizzle(mgr, NSSelectorFromString(
                @"luckyRewardedVideoAdBecomeEffective:extraParams:callback:"),
                      (IMP)LCEff3, (IMP *)&gOrigEff3)) {
            LCAutoLog(@"[ad] hook becomeEffective(3)");
            ok++;
        }
        if (LCSwizzle(mgr, NSSelectorFromString(@"__commonVideoAd:didClickCloseWithInfo:"),
                      (IMP)LCClose1, (IMP *)&gOrigClose)) {
            LCAutoLog(@"[ad] hook close(common)");
            ok++;
        }
        if (LCSwizzle(mgr, NSSelectorFromString(@"luckyRewardedVideoAd:didClickCloseWithInfo:"),
                      (IMP)LCClose2, (IMP *)&gOrigClose2)) {
            LCAutoLog(@"[ad] hook close(lucky)");
            ok++;
        }
    }
    if (ok == 0) {
        LCAutoLog(@"[ad] 类还没加载，稍后重试");
        return;
    }
    LCAutoLog(@"[ad] 共装上 %d 个 hook", ok);
    gAdHooked = YES;
}

#pragma mark - token 刷新

// Capture.m 在收到 /luna/treasure/task/page/v2 响应时调这里。
// 任务页每次刷新都会重新生成 token(抓包里连续 4 次刷新 4 个不同 token)，
// 所以每轮结束后 App 自己刷任务页时就能白拿一个新 token。
void LCAdNotePageResponse(NSString *body) {
    if (body.length < 100) return;
    NSData *d = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return;

    NSString *found = nil;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:obj];
    int guard = 0;
    while (stack.count && guard++ < 20000) {
        id cur = stack.lastObject;
        [stack removeLastObject];
        if ([cur isKindOfClass:[NSDictionary class]]) {
            NSDictionary *dd = cur;
            NSString *key = dd[@"key"];
            NSString *tok = dd[@"token"];
            if ([key isKindOfClass:[NSString class]] &&
                [key isEqualToString:@"music_incentive_ad"] &&
                [tok isKindOfClass:[NSString class]] && tok.length > 40) {
                found = tok;
                break;
            }
            for (id v in dd.allValues) {
                if ([v isKindOfClass:[NSDictionary class]] ||
                    [v isKindOfClass:[NSArray class]]) [stack addObject:v];
            }
        } else if ([cur isKindOfClass:[NSArray class]]) {
            for (id v in cur) {
                if ([v isKindOfClass:[NSDictionary class]] ||
                    [v isKindOfClass:[NSArray class]]) [stack addObject:v];
            }
        }
    }
    if (!found) return;
    if (!gAdLock) gAdLock = [NSLock new];
    [gAdLock lock];
    BOOL changed = ![found isEqualToString:gAdFreshToken];
    gAdFreshToken = [found copy];
    [gAdLock unlock];
    if (changed) {
        LCAutoLog(@"[ad] 任务页给了新 token(%luB) %@...",
                  (unsigned long)found.length, [found substringToIndex:24]);
    }
}

// Capture.m 在收到 /api/ad/v1/inspire_preload/ 响应时调这里。
// 服务端在这个响应里指定本次广告要播多久，必须照着播，不能自己拍 16 秒。
void LCAdNotePreloadResponse(NSString *body) {
    if (body.length < 50) return;
    NSData *d = [body dataUsingEncoding:NSUTF8StringEncoding];
    if (!d) return;
    id obj = [NSJSONSerialization JSONObjectWithData:d options:0 error:NULL];
    if (![obj isKindOfClass:[NSDictionary class]]) return;

    NSNumber *v = ((NSDictionary *)obj)[@"effective_inspire_time"];
    NSInteger need = v ? v.integerValue : 0;
    if (need <= 0) need = 20;            // 0 表示不指定，按 launch_duration 的 20
    NSInteger total = need + 2;          // 2 秒余量，卡点关闭容易被判提前
    if (total < 18) total = 18;
    if (total > 95) total = 95;

    if (total != gAdPlaySeconds) {
        LCAutoLog(@"[ad] 服务端要求播 %lds，阈值改为 %lds",
                  (long)need, (long)total);
    }
    gAdPlaySeconds = total;
}

NSString *LCAdCurrentToken(void) {
    if (!gAdLock) return gAdFreshToken;
    [gAdLock lock];
    NSString *t = [gAdFreshToken copy];
    [gAdLock unlock];
    return t;
}

// 把 token 换进 model。model 是 App 自己 new 出来的对象，
// 字段类型/隐藏属性全都对，只改 token 最稳（不复用旧 token 会 1300003）。
static BOOL LCApplyTokenToModel(void) {
    NSString *tok = LCAdCurrentToken();
    if (!tok) {
        LCAutoLog(@"[ad] 还没有新 token，沿用上一轮的");
        return YES;
    }
    id pm = gAdModelObj;
    if (!pm) return YES;

    @try {
        [pm setValue:tok forKey:@"token"];
        LCAutoLog(@"[ad] token 已更新为 %@...", [tok substringToIndex:24]);
        return YES;
    } @catch (NSException *e) {
        LCAutoLog(@"[ad] 换 token 失败: %@，沿用旧 model", e.reason);
        return NO;
    }
}

#pragma mark - 对外

id LCAdTrigger(void) {
    id bridge = gAdBridgeInst;
    id pm = gAdModelObj ?: gAdParamModel;
    if (!bridge || !pm) {
        LCAutoLog(@"[ad] 没有可复用的 bridge 实例");
        return nil;
    }
    if (gAdModelObj) LCApplyTokenToModel();

    gAdOpening = YES;
    gAdPlaying = NO;
    gAdClosing = NO;
    gAdSawClose = NO;
    gAdOpenAt = [[NSDate date] timeIntervalSince1970];
    gAdCloseTryAt = 0;

    @try {
        // 精确签名直调，不用 NSInvocation —— 之前用 NSInvocation 转发
        // 任意签名连续崩了 3 次 EXC_BAD_ACCESS
        SEL s = NSSelectorFromString(@"callWithParamModel:completionHandler:");
        if (![bridge respondsToSelector:s]) {
            LCAutoLog(@"[ad] bridge 不响应 callWithParamModel:");
            gAdOpening = NO;
            return nil;
        }
        LCBridgeCallIMP f = (LCBridgeCallIMP)[bridge methodForSelector:s];
        if (f) f(bridge, s, pm, nil);
        LCAutoLog(@"[ad] 已触发 bridge");
    } @catch (NSException *e) {
        LCAutoLog(@"[ad] 调用异常: %@", e.reason);
        gAdOpening = NO;
    }
    return pm;
}

BOOL LCAdHasTemplate(void) {
    if (!gAdLock) return (gAdParamModel.count > 0) || gAdModelObj != nil;
    [gAdLock lock];
    BOOL has = (gAdParamModel.count > 0) || gAdModelObj != nil;
    [gAdLock unlock];
    return has;
}

NSString *LCAdTemplateText(void) {
    if (gAdModelObj) return LCDumpObject(gAdModelObj, 0);
    return LCJSONText(gAdParamModel);
}

void LCAdRun(NSInteger times) {
    if (gAdBusy) {
        LCAutoLog(@"[ad] 上一轮还在跑");
        return;
    }
    if (!LCAdHasTemplate()) {
        LCAutoLog(@"[ad] 没有参数样本:先在 App 里手动点一次「看广告赚金币」");
        return;
    }
    if (!gAdBridgeInst) {
        LCAutoLog(@"[ad] 没有 bridge 实例(需要停在金币任务页)");
        return;
    }
    if (times <= 0) times = 1;
    if (times > 30) times = 30;

    gAdBusy = YES;
    gAdTotalCount = times;
    gAdRemain = times;
    gAdOpening = NO;
    gAdPlaying = NO;
    gAdClosing = NO;
    gAdSawClose = NO;

    if (gAdTimer) [gAdTimer invalidate];
    gAdTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                               repeats:YES
                                                 block:^(NSTimer *t) { LCTick(); }];
    LCAutoLog(@"[ad] 开始 %ld 轮，按服务端要求播 %lds，每轮约 %ld 秒",
              (long)times, (long)gAdPlaySeconds, (long)(gAdPlaySeconds + kAdCooldown));

    // 第一轮立刻来
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!gAdBusy) return;
        if (gAdRemain <= 0) { gAdBusy = NO; return; }
        gAdRemain--;
        LCAutoLog(@"[ad] 第 %ld/%ld 轮",
                  (long)(gAdTotalCount - gAdRemain), (long)gAdTotalCount);
        LCAdTrigger();
    });
}

void LCAdStop(void) {
    if (!gAdBusy && !gAdTimer) return;
    gAdBusy = NO;
    gAdRemain = 0;
    gAdOpening = NO;
    gAdPlaying = NO;
    gAdClosing = NO;
    gAdSawClose = NO;
    if (gAdTimer) { [gAdTimer invalidate]; gAdTimer = nil; }
    LCAutoLog(@"[ad] 手动停止");
}

BOOL LCAdBusy(void) { return gAdBusy; }
NSDictionary *LCAdEffectiveExtra(void) { return gAdEffectiveExtra; }
