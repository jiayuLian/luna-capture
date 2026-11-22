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
#include <string.h>

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
static volatile int gTaskPageSeen = 0;
static volatile int gTaskPageParsed = 0;
int LCAdTaskPageSeen(void)   { return gTaskPageSeen; }
int LCAdTaskPageParsed(void) { return gTaskPageParsed; }

static volatile BOOL gAdBusy = NO;
static volatile BOOL gAdOpening = NO;          // 已调 bridge，等 DidLoadSuccess
static volatile BOOL gAdPlaying = NO;          // 广告已在播
static volatile BOOL gAdClosing = NO;          // 已触发关闭，等 close 回调
static volatile BOOL gAdSawClose = NO;
static NSInteger gAdRemain = 0;
// 领时长（任务 600590 luna_rewards_ads）的状态。必须声明在这里，
// 因为 LCScheduleNext（广告关掉后推进轮次）要用它记账。
static NSInteger gDurRemain = 0;
// 任务 600590 的 button.schema（sslocal://luckydog/activity_task?...）。
// 金币页是 Lynx 渲染的，里面没有能点的 UIKit 控件，只能靠 schema 打开活动页。
static NSString *gDurSchema = nil;
static NSString *gDurSchemaDate = nil;          // 只在当天有效，隔天必须换
static NSTimeInterval gDurOpenAt = 0;           // 上次 openURL 的时刻，25 秒限流
static int gDurOpenFails = 0;                   // 连续失败次数，到 3 就不再试
static NSInteger gDurDone   = 0;
static BOOL      gDurActive = NO;    // 接管中:广告关一次才记一次
static NSTimeInterval gDurTapAt = 0;
static NSTimer  *gDurTimer  = nil;
// 连续刷视频（任务 601232）的状态。同样要放顶部，LCScheduleNext 要记账。
static NSInteger gDrawRemain = 0;
static NSInteger gDrawDone   = 0;
static BOOL      gDrawActive = NO;
static NSTimeInterval gDrawTapAt  = 0;
static NSTimeInterval gDrawCoolAt = 0;
static NSTimer  *gDrawTimer = nil;
static NSInteger gAdTotalCount = 0;
static NSTimeInterval gAdPlayStart = 0;
static NSTimeInterval gAdOpenAt = 0;
static NSTimeInterval gAdCloseTryAt = 0;   // 上次尝试关闭的时刻，用于限流重试
static BOOL gAdRetried = NO;               // 本轮是否已经重试过开广告
static BOOL gAdDumped = NO;                // 本轮是否已经自动抓过界面树
static NSTimeInterval gAdEffectiveAt = 0;  // becomeEffective 回调时刻，仅用于日志
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

// 前向声明：下面两个工具函数要用到它们，而定义在后面
static UIViewController *LCTopVC(void);
static UIView *LCFindControlByText(UIView *v, NSArray<NSString *> *texts, int depth);

// 激励视频几乎都跑在自己的 UIWindow 里，而且未必是 keyWindow。
// 只遍历 keyWindow 会漏掉「再看一个视频」那个弹窗 —— 认字全部落空。
// 这个函数返回全部可见 window，后加的在上面。
// 自家浮窗的类名。它 level=2050 排在最上层，如果参与文案匹配，
// 会把「领时长」匹配成浮窗菜单里那个「领时长 ×3」按钮，
// 也会把 54x54 的红色圆钮当成广告关闭按钮（实测 04:14 连点 4 次）。
// 所以所有"找按钮"的遍历都必须把它排除掉。
static BOOL LCIsOwnWindow(UIWindow *w) {
    return [NSStringFromClass([w class]) isEqualToString:@"LCFloatWindow"];
}

static NSArray<UIWindow *> *LCAllWindows(void) {
    NSMutableArray *arr = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (!w.isHidden && w.alpha > 0.01 && w.bounds.size.width > 100 &&
                    !LCIsOwnWindow(w)) {
                    [arr addObject:w];
                }
            }
        }
    } else {
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if (!w.isHidden && w.alpha > 0.01 && w.bounds.size.width > 100 &&
                !LCIsOwnWindow(w)) {
                [arr addObject:w];
            }
        }
    }
    return [[arr reverseObjectEnumerator] allObjects];
}

// 在所有 window 里按文案找可点控件
static UIView *LCFindByTextAnywhere(NSArray<NSString *> *texts) {
    for (UIWindow *w in LCAllWindows()) {
        UIView *v = LCFindControlByText(w, texts, 0);
        if (v) return v;
    }
    UIViewController *top = LCTopVC();
    if (top.view) return LCFindControlByText(top.view, texts, 0);
    return nil;
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
    // 滚动容器不是按钮，整棵子树跳过
    if ([v isKindOfClass:[UIScrollView class]]) return nil;

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

// 取一个 view 上承载的文案。Lynx / 原生混排，文字可能落在
// UILabel.text、UIButton 的 title、UITextView.text 或 accessibilityLabel。
static NSString *LCTextOfView(UIView *v) {
    NSMutableString *s = [NSMutableString string];
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (l.text.length) [s appendString:l.text];
    }
    if ([v isKindOfClass:[UITextView class]]) {
        UITextView *t = (UITextView *)v;
        if (t.text.length) [s appendString:t.text];
    }
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        NSString *t = [b titleForState:UIControlStateNormal];
        if (t.length) [s appendString:t];
    }
    if (v.accessibilityLabel.length) [s appendString:v.accessibilityLabel];
    if (v.accessibilityValue.length) [s appendString:v.accessibilityValue];
    return s;
}

// 按文案找可点控件。返回的可能是 UIControl，也可能只是普通 view(靠手势)。
// 命中后优先往上找最近的可点祖先 —— Lynx 的按钮往往文字在子 label 上,
// 真正的点击目标在几层之外。
static UIView *LCFindControlByText(UIView *v, NSArray<NSString *> *texts, int depth) {
    if (!v || v.hidden || v.alpha < 0.03 || depth > 30) return nil;

    NSString *t = LCTextOfView(v);
    if (t.length) {
        for (NSString *want in texts) {
            if (![t containsString:want]) continue;
            UIView *cur = v;
            for (int i = 0; i < 10 && cur; i++) {
                BOOL skip = [cur isKindOfClass:[UIScrollView class]];
                // Lynx 把所有手势都挂在根 LynxView 上（accessibilityLabel 是
                // "lynxview"），全屏。以前命中文案后一路向上找可点祖先，
                // 最后返回的就是它 —— 日志里 `点「lynxview」<LynxView>`，
                // 点整个页面等于没点。所以根容器也要跳过。
                if (!skip && cur.bounds.size.width >= v.window.bounds.size.width - 2 &&
                    cur.bounds.size.height >= v.window.bounds.size.height - 2) {
                    skip = YES;
                }
                if (!skip) {
                    if ([cur isKindOfClass:[UIControl class]] && ((UIControl *)cur).enabled) return cur;
                    if (cur.userInteractionEnabled && cur.gestureRecognizers.count > 0) return cur;
                }
                cur = cur.superview;
            }
            // 找不到合适的祖先就返回命中文字的那个视图本身（UILynxView / LynxTextView），
            // 由 LCTapLynxView 用它的坐标去 hitTest。
            return v;
        }
    }
    for (UIView *s in [v.subviews reverseObjectEnumerator]) {
        UIView *hit = LCFindControlByText(s, texts, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

#pragma mark - 合成触摸（Lynx 按钮唯一可行的点法）

// 金币任务页整页是 Lynx 画的：内容在 LunaTabBarSlidingScrollView 里，
// 再套 BDXView → BDXLynxView → LynxView，卡片和按钮全是 UILynxView。
// 这些按钮既不是 UIControl，也没有 accessibilityLabel（文字在兄弟 LynxTextView 上），
// sendActions / accessibilityActivate / 手势 target 三条路全是死的 ——
// Lynx 只认 UIResponder 的 touchesBegan/Ended，而且要从 UITouch 里读坐标。
//
// 所以这里直接按 ivar 偏移写一个 UITouch，再喂给 LynxView。
// UITouch 没有公开构造器，但字段布局是固定的：_view/_window/_phase/
// _locationInWindow/_previousLocationInWindow/_timestamp/_tapCount。
static BOOL LCSetIvar(id obj, const char *name, const void *src, size_t size) {
    if (!obj || !name) return NO;
    Ivar iv = class_getInstanceVariable(object_getClass(obj), name);
    if (!iv) return NO;
    if ((size_t)ivar_getOffset(iv) == 0) return NO;
    memcpy((char *)(__bridge void *)obj + ivar_getOffset(iv), src, size);
    return YES;
}

static BOOL LCSynthTapAtWindowPoint(UIWindow *win, CGPoint p) {
    if (!win) return NO;
    UIView *hit = [win hitTest:p withEvent:nil];
    if (!hit) return NO;

    // 往上找 LynxView，事件必须喂给它，它才会拿坐标做命中测试
    UIView *lynx = hit;
    for (int i = 0; i < 24 && lynx; i++) {
        if ([NSStringFromClass([lynx class]) isEqualToString:@"LynxView"]) break;
        lynx = lynx.superview;
    }
    if (!lynx) lynx = hit;

    UITouch *t = nil;
    @try { t = [[UITouch alloc] init]; } @catch (__unused NSException *e) { return NO; }
    if (!t) return NO;

    UIView   *v  = hit;
    UIWindow *w  = win;
    CGPoint   pp = p;
    NSUInteger tapCount = 1;
    int phaseBegan = 0;      // UITouchPhaseBegan
    int phaseEnded = 3;      // UITouchPhaseEnded
    NSTimeInterval ts = [[NSProcessInfo processInfo] systemUptime];

    LCSetIvar(t, "_view", &v, sizeof(v));
    LCSetIvar(t, "_window", &w, sizeof(w));
    LCSetIvar(t, "_locationInWindow", &pp, sizeof(pp));
    LCSetIvar(t, "_previousLocationInWindow", &pp, sizeof(pp));
    LCSetIvar(t, "_tapCount", &tapCount, sizeof(tapCount));
    LCSetIvar(t, "_timestamp", &ts, sizeof(ts));

    NSSet *set = [NSSet setWithObject:t];

    @try {
        LCSetIvar(t, "_phase", &phaseBegan, sizeof(phaseBegan));
        [lynx touchesBegan:set withEvent:nil];
        LCSetIvar(t, "_phase", &phaseEnded, sizeof(phaseEnded));
        [lynx touchesEnded:set withEvent:nil];
        return YES;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

// 合成点击某个视图：取它的中心点换算到 window 坐标
static BOOL LCSynthTapView(UIView *v) {
    if (!v) return NO;
    UIWindow *w = v.window;
    if (!w) return NO;
    CGPoint c = CGPointMake(v.bounds.size.width / 2.0, v.bounds.size.height / 2.0);
    CGPoint p = [v convertPoint:c toView:w];
    return LCSynthTapAtWindowPoint(w, p);
}

#pragma mark - 卡片按钮定位（金币任务页专用）

// 金币页每张任务卡都是这个结构（实测 04:23 界面树）：
//   UILynxView (12,142 350x81)            卡片
//     UILynxView (0,16 350x49)
//       LynxTextView (0,0 147x25) "连续刷视频赚金币"
//       UILynxView (265,7 85x36)          按钮（没有文字、没有 label）
// 按钮统一 85x36，贴卡片右侧。所以只要先按标题文字找到卡片，
// 再在卡片里挑"最右边那个 80x30 左右的小块"，就是按钮。
static UIView *LCFindExactText(UIView *v, NSString *want, int depth) {
    if (!v || v.hidden || v.alpha < 0.03 || depth > 30) return nil;
    NSString *t = LCTextOfView(v);
    if (t.length && [t containsString:want]) return v;
    for (UIView *s in v.subviews) {
        UIView *h = LCFindExactText(s, want, depth + 1);
        if (h) return h;
    }
    return nil;
}

// 从文字视图往上找"卡片"：宽度 >= 300 且高度在 60~260 之间
static UIView *LCCardAncestorOf(UIView *v) {
    UIView *cur = v;
    for (int i = 0; i < 12 && cur; i++) {
        CGRect f = cur.bounds;
        if (f.size.width >= 300 && f.size.height >= 60 && f.size.height <= 260) return cur;
        cur = cur.superview;
    }
    return v.superview ?: v;
}

// 在卡片里找按钮：85x36 上下、贴右侧（x 最大）
static UIView *LCButtonInCard(UIView *card) {
    if (!card) return nil;
    __block UIView *best = nil;
    __block CGFloat bestX = -1;
    __block void (^walk)(UIView *, int);
    walk = ^(UIView *v, int d) {
        if (!v || d > 8) return;
        CGRect f = v.bounds;
        BOOL sizeOK = (f.size.width >= 60 && f.size.width <= 120 &&
                       f.size.height >= 24 && f.size.height <= 52);
        BOOL isLynx = [NSStringFromClass([v class]) containsString:@"UILynxView"] ||
                      [v isKindOfClass:[UIControl class]];
        if (sizeOK && isLynx) {
            CGPoint p = [v convertPoint:CGPointZero toView:card];
            if (p.x > bestX && p.x > card.bounds.size.width * 0.55) {
                bestX = p.x;
                best = v;
            }
        }
        for (UIView *s in v.subviews) walk(s, d + 1);
    };
    walk(card, 0);
    return best;
}

// 对外：按卡片标题点它右侧的按钮
static BOOL LCTapCardButton(NSString *title) {
    for (UIWindow *w in LCAllWindows()) {
        UIView *txt = LCFindExactText(w, title, 0);
        if (!txt) continue;
        UIView *card = LCCardAncestorOf(txt);
        UIView *btn = LCButtonInCard(card);
        if (btn) {
            BOOL ok = LCSynthTapView(btn);
            LCAutoLog(@"[tap] 「%@」卡片按钮 <%@ %.0fx%.0f> %@",
                      title, NSStringFromClass([btn class]),
                      btn.bounds.size.width, btn.bounds.size.height,
                      ok ? @"已点击" : @"点不动");
            if (ok) return YES;
        }
        // 退一步：直接点文字本身
        BOOL ok2 = LCSynthTapView(txt);
        LCAutoLog(@"[tap] 「%@」没找到按钮，点文字 <%@> %@",
                  title, NSStringFromClass([txt class]), ok2 ? @"已点击" : @"点不动");
        return ok2;
    }
    return NO;
}

// 从 UIGestureRecognizerTarget 里把 target/action 抠出来。
// _action 是 SEL —— KVC 不支持 SEL，valueForKey 会抛异常，
// 之前被 @catch 吞掉后这个函数就一直静默返回 NO，等于从没点过。
// 所以这里用 object_getIvar + ivar 偏移直接读。
static BOOL LCFireOneGesture(UIGestureRecognizer *g) {
    Ivar tiv = class_getInstanceVariable([g class], "_targets");
    if (!tiv) return NO;
    NSArray *targets = nil;
    @try { targets = object_getIvar(g, tiv); } @catch (__unused NSException *e) {}
    if (![targets isKindOfClass:[NSArray class]]) return NO;

    for (id t in targets) {
        Class tc = object_getClass(t);
        Ivar ti = class_getInstanceVariable(tc, "_target");
        Ivar ai = class_getInstanceVariable(tc, "_action");

        id tgt = nil;
        if (ti) {
            @try { tgt = object_getIvar(t, ti); } @catch (__unused NSException *e) {}
        }
        SEL sel = NULL;
        if (ai) {
            const char *enc = ivar_getTypeEncoding(ai);
            if (enc && enc[0] == ':') {      // SEL 编码是 ":"
                sel = *(SEL *)((char *)(__bridge void *)t + ivar_getOffset(ai));
            }
        }
        // 万一 ivar 改名了，退回 KVC（action 是 NSString 的情况也在这里）
        if (!sel) {
            id act = nil;
            @try { act = [t valueForKey:@"action"]; } @catch (__unused NSException *e) {}
            if ([act isKindOfClass:[NSString class]]) sel = NSSelectorFromString((NSString *)act);
            if (!tgt) { @try { tgt = [t valueForKey:@"target"]; } @catch (__unused NSException *e) {} }
        }
        if (!tgt || !sel) continue;
        if (![tgt respondsToSelector:sel]) continue;
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(tgt, sel, g);
            return YES;
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

// 触发一次点击。三条路依次试：
//   1. UIControl 的 sendActions —— 原生按钮最稳
//   2. accessibilityActivate —— UIAccessibility 的标准激活通道，
//      Lynx / 自绘控件大多实现了它
//   3. 手势 target/action 直调
static BOOL LCFireTapGesture(UIView *v) {
    // 2) accessibility 通道
    if ([v respondsToSelector:@selector(accessibilityActivate)]) {
        @try {
            if ([v accessibilityActivate]) return YES;
        } @catch (__unused NSException *e) {}
    }
    // 3) 手势
    for (UIView *cur = v; cur; cur = cur.superview) {
        for (UIGestureRecognizer *g in cur.gestureRecognizers) {
            if (![g isKindOfClass:[UITapGestureRecognizer class]]) continue;
            if (LCFireOneGesture(g)) return YES;
        }
    }
    return NO;
}

static BOOL LCTapView(UIView *v) {
    if (!v) return NO;
    for (UIView *cur = v; cur; cur = cur.superview) {
        if ([cur isKindOfClass:[UIControl class]]) {
            UIControl *c = (UIControl *)cur;
            if (c.enabled) {
                [c sendActionsForControlEvents:UIControlEventTouchUpInside];
                return YES;
            }
        }
    }
    return LCFireTapGesture(v);
}

// 有些关闭按钮是 UIImageView + UITapGestureRecognizer，不是 UIControl
static UIView *LCFindCloseGestureView(UIView *v, CGRect winRect, int depth) {
    if (!v || v.hidden || v.alpha < 0.05 || depth > 24) return nil;
    // LynxScrollView 是 Lynx 的滚动容器，几乎占满全屏又带手势，
    // 之前一直被当成"右上角关闭按钮"点，点了当然没反应。
    if ([v isKindOfClass:[UIScrollView class]]) return nil;
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

#pragma mark - 广告关闭按钮（Lynx）

// 广告播完后右上角那个「领取成功 ×」实测结构：
//   UILynxView (280,47 94x32)  accessibilityLabel = "领取成功，关闭，按钮"
//     LynxTextView "领取成功"
//     BDImageView (8x8)        <- 那个 ×
// 它不是 UIControl，文字也不在 UILabel 上，靠普通文案遍历找不到，
// 必须读 accessibilityLabel。位置固定在右上角，顺手做个位置约束防误命中。
static UIView *LCFindAdCloseIn(UIView *v, CGRect scr, int depth) {
    if (!v || v.hidden || v.alpha < 0.03 || depth > 30) return nil;

    if (![v isKindOfClass:[UIScrollView class]]) {
        NSString *label = v.accessibilityLabel;
        if (label.length) {
            CGRect f = [v convertRect:v.bounds toView:nil];
            BOOL topRight = (f.origin.x > scr.size.width * 0.48 &&
                             f.origin.y < scr.size.height * 0.28 &&
                             f.size.width >= 30 && f.size.height >= 16 &&
                             f.size.width < scr.size.width * 0.8);
            if (topRight &&
                ([label containsString:@"领取成功"] ||
                 [label containsString:@"关闭"])) {
                return v;
            }
        }
    }
    for (UIView *s in [v.subviews reverseObjectEnumerator]) {
        UIView *hit = LCFindAdCloseIn(s, scr, depth + 1);
        if (hit) return hit;
    }
    return nil;
}

static UIView *LCFindAdCloseView(void) {
    CGRect scr = [UIScreen mainScreen].bounds;
    for (UIWindow *w in LCAllWindows()) {
        UIView *hit = LCFindAdCloseIn(w, scr, 0);
        if (hit) return hit;
    }
    return nil;
}

// 点 Lynx 视图。UILynxView 不响应 sendActions，依次试：
//   1) accessibilityActivate —— Lynx 为 VoiceOver 保留了这条通道，最靠谱
//   2) 手势 target/action
//   3) 中心点 hitTest 找到真正吃掉触摸的子视图，再走 1/2
static BOOL LCTapLynxView(UIView *v) {
    if (!v) return NO;

    if ([v respondsToSelector:@selector(accessibilityActivate)]) {
        @try { if ([v accessibilityActivate]) return YES; } @catch (__unused NSException *e) {}
    }
    if (LCFireTapGesture(v)) return YES;

    UIWindow *w = v.window;
    if (w) {
        CGPoint c = CGPointMake(v.bounds.size.width / 2.0, v.bounds.size.height / 2.0);
        CGPoint p = [v convertPoint:c toView:w];
        UIView *hit = [w hitTest:p withEvent:nil];
        if (hit && hit != v) {
            if ([hit respondsToSelector:@selector(accessibilityActivate)]) {
                @try { if ([hit accessibilityActivate]) return YES; } @catch (__unused NSException *e) {}
            }
            if (LCFireTapGesture(hit)) return YES;
            if ([hit isKindOfClass:[UIControl class]]) {
                [(UIControl *)hit sendActionsForControlEvents:UIControlEventTouchUpInside];
                return YES;
            }
        }
    }
    return NO;
}

#pragma mark - 界面树

static void LCDumpTreeWalk(UIView *v, int depth, NSMutableString *out) {
    // 14 层不够：金币任务页的卡片在 LunaTabBarSlidingScrollView 的 cell 里，
    // 到第 15 层就被截断了，所以之前的界面树里一个任务卡都看不到。
    if (!v || depth > 26) return;
    CGRect f = v.frame;
    NSString *t = LCTextOfView(v);
    if (t.length > 40) t = [t substringToIndex:40];
    NSMutableString *pad = [NSMutableString string];
    for (int i = 0; i < depth; i++) [pad appendString:@"  "];
    [out appendFormat:@"%@%@ (%.0f,%.0f %.0fx%.0f)%@\n",
     pad, NSStringFromClass([v class]),
     f.origin.x, f.origin.y, f.size.width, f.size.height,
     t.length ? [NSString stringWithFormat:@" \"%@\"", t] : @""];
    for (UIView *s in v.subviews) LCDumpTreeWalk(s, depth + 1, out);
}

// 把当前界面结构写到 lc_view.txt。文案匹配不上时，靠这个直接改规则，
// 不用用户再猜"那个按钮长什么样"。
void LCDumpAdViewTree(void) {
    NSArray<UIWindow *> *wins = LCAllWindows();
    if (wins.count == 0) { LCAutoLog(@"[view] 没有可 dump 的 window"); return; }

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"LunaCapture %@  %@  共 %lu 个 window\n",
     LC_VER, [NSDate date], (unsigned long)wins.count];
    for (UIWindow *w in wins) {
        [out appendFormat:@"\n===== %@ key=%d level=%.0f =====\n",
         NSStringFromClass([w class]), (int)w.isKeyWindow, w.windowLevel];
        LCDumpTreeWalk(w, 0, out);
    }

    NSArray *ps = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                      NSUserDomainMask, YES);
    if (ps.count == 0) return;
    NSString *p = [ps.firstObject stringByAppendingPathComponent:@"lc_view.txt"];
    [out writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    LCAutoLog(@"[view] 界面树已写入 lc_view.txt (%lu 字节)", (unsigned long)out.length);
}

#pragma mark - 自动关闭

static void LCScheduleNext(void);
id LCAdTrigger(void);

// 广告播完会出现两种弹窗：
//   「再看一个视频获得 +300 金币」 -> 领取奖励(继续看) / 坚持退出(结束)
//   「领取成功 ×」                -> 直接关掉广告窗口
// 以前只按坐标找右上角,结果总是点到第二种,把二次奖励跳过了。
// 现在先认字:有「领取奖励」就接着看,轮次用完或没有才退出去。
static BOOL LCTryFinishAd(void) {

    // 1) 二次奖励 —— 点了会直接开下一个广告，根本不回福利页
    UIView *again = LCFindByTextAnywhere(@[@"领取奖励", @"再看一个", @"继续观看"]);
    if (again) {
        if (gAdRemain > 0) {
            BOOL ok = LCTapView(again);
            LCAutoLog(@"[ad] 二次奖励弹窗，点「领取奖励」接着看(%@) <%@>",
                      ok ? @"已发送" : @"发送失败", NSStringFromClass([again class]));
            if (ok) {
                gAdRemain--;
                // 新广告会再走一次 DidLoadSuccess，计时会被重置
                gAdPlayStart = [[NSDate date] timeIntervalSince1970];
                gAdCloseTryAt = [[NSDate date] timeIntervalSince1970];
                return YES;
            }
        } else {
            LCAutoLog(@"[ad] 轮次已用完，不再连看");
        }
    }

    // 2) 播完标记：右上角「领取成功 ×」。
    //    它是 UILynxView + accessibilityLabel="领取成功，关闭，按钮"，
    //    走专用的 LCTapLynxView，不用普通文案匹配。
    UIView *closeView = LCFindAdCloseView();
    if (closeView) {
        CGRect f = [closeView convertRect:closeView.bounds toView:nil];
        BOOL ok = LCTapLynxView(closeView);
        LCAutoLog(@"[ad] 命中关闭视图 <%@ %.0f,%.0f %.0fx%.0f> label=%@ → %@",
                  NSStringFromClass([closeView class]),
                  f.origin.x, f.origin.y, f.size.width, f.size.height,
                  closeView.accessibilityLabel ?: @"nil",
                  ok ? @"已点击" : @"点不动");
        if (ok) { gAdClosing = YES; return YES; }
        LCDumpAdViewTree();
    }

    // 2b) 普通文案兜底（万一 accessibilityLabel 变了）
    UIView *done = LCFindByTextAnywhere(@[@"领取成功", @"已获得", @"奖励已发放", @"点击领取"]);
    if (done) {
        BOOL ok = LCTapView(done);
        LCAutoLog(@"[ad] 播完标记(文案)，点 <%@> %@",
                  NSStringFromClass([done class]), ok ? @"ok" : @"fail");
        if (ok) { gAdClosing = YES; return YES; }
    }

    // 3) 明确写着退出的
    UIView *quit = LCFindByTextAnywhere(@[@"坚持退出", @"残忍离开", @"放弃奖励"]);
    if (quit) {
        BOOL ok = LCTapView(quit);
        LCAutoLog(@"[ad] 点「坚持退出」结束 <%@> %@",
                  NSStringFromClass([quit class]), ok ? @"ok" : @"fail");
        if (ok) { gAdClosing = YES; return YES; }
    }
    return NO;
}

static void LCForceCloseAd(void) {
    // 不再用 gAdClosing 拦住重试 —— 一次点不到很常见（按钮晚出现、
    // 点到滚动容器等），重试节奏由 LCTick 的 gAdCloseTryAt 每 10 秒限流。
    if (!gAdPlaying) return;

    CGRect wr = [UIScreen mainScreen].bounds;
    UIViewController *top = LCTopVC();

    // 1) 优先点真的关闭按钮 —— 只有这条路径会走 SDK 的
    //    __handleRewardVideoCloseWithAdVideoModel:，进而触发 do_action
    UIControl *btn = nil;
    for (UIWindow *w in LCAllWindows()) {
        btn = LCFindCloseControl(w, wr, 0);
        if (btn) break;
    }
    if (!btn && top) btn = LCFindCloseControl(top.view, wr, 0);
    if (btn) {
        LCAutoLog(@"[ad] 点关闭按钮 <%@ %.0fx%.0f>",
                  NSStringFromClass([btn class]),
                  btn.frame.size.width, btn.frame.size.height);
        [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        return;
    }

    // 2) 退化到带手势的图片按钮
    UIView *gv = nil;
    for (UIWindow *w in LCAllWindows()) {
        gv = LCFindCloseGestureView(w, wr, 0);
        if (gv) break;
    }
    if (!gv && top) gv = LCFindCloseGestureView(top.view, wr, 0);
    if (gv) {
        LCAutoLog(@"[ad] 手势视图 <%@>，触发点击", NSStringFromClass([gv class]));
        // 这里必须真的把 recognizer 的 target/action 调起来。
        // 以前只做了 hitTest —— 那只算命中测试，不会触发手势，
        // 结果每次都掉进下面的 dismiss，关闭不生效也不发奖。
        if (LCFireTapGesture(gv)) {
            LCAutoLog(@"[ad] 手势已触发");
            return;
        }
        // 以前这里直接 dismiss 顶层 VC。dismiss 能关掉广告界面，但是
        // ① 不触发 SDK 的结算回调 ② 不弹「再看一个视频」③ 之后 close 回调
        // 也不会来，整轮就卡死。改成什么都不做，交给 LCTick 下一轮重试。
        LCAutoLog(@"[ad] 手势触发失败，不下 dismiss，等下一轮");
        return;
    }

    // 3) 一个可点控件都没找到。
    //    以前在这里 dismiss 顶层 VC —— 能关掉界面但拿不到奖励，还会让
    //    后面的 close 回调永远不来。现在只记录，LCTick 会继续重试。
    LCAutoLog(@"[ad] 没找到可点的关闭控件(顶层 %@)，等下一轮",
              top ? NSStringFromClass([top class]) : @"nil");
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
            // 播完之后再抓界面树才有意义。22 秒抓到的还是播放中的画面。
            if (!gAdDumped && el > gAdPlaySeconds + 10) {
                gAdDumped = YES;
                LCAutoLog(@"[ad] 抓界面树(%.0fs)，同时找结束按钮", el);
                LCDumpAdViewTree();
            }

            BOOL due = (gAdCloseTryAt <= 0) ||
                       ([[NSDate date] timeIntervalSince1970] - gAdCloseTryAt >= 3);
            if (due) {
                gAdCloseTryAt = [[NSDate date] timeIntervalSince1970];
                if (!LCTryFinishAd()) {
                    // 认字全落空（有的广告确实没有二次奖励），
                    // 等够 40 秒再退化成"点可点控件"，而且绝不 dismiss。
                    if (el > gAdPlaySeconds + 40) {
                        LCForceCloseAd();
                    }
                }
            }

            // 90 秒是硬上限。到这儿说明 SDK 完全没给任何锚点,
            // 只推进轮次，不强行 dismiss（留着现场给下一次 dump）。
            if (el > gAdPlaySeconds + 90) {
                if (gDurActive) {
                    LCAutoLog(@"[dur] 这条广告 %ld 秒没结束，跳过，不再重试",
                              (long)(gAdPlaySeconds + 90));
                    gDurActive = NO;
                    gDurRemain--;
                    gDurTapAt = 0;
                }
                if (gDrawActive) {
                    LCAutoLog(@"[draw] 这条广告 %ld 秒没结束，跳过",
                              (long)(gAdPlaySeconds + 90));
                    gDrawActive = NO;
                    gDrawRemain--;
                    gDrawTapAt = 0;
                    gDrawCoolAt = [[NSDate date] timeIntervalSince1970];
                }
                LCAutoLog(@"[ad] %ld 秒还没结束，放弃本轮（界面可能卡在广告页）",
                          (long)(gAdPlaySeconds + 90));
                gAdSawClose = YES;
            }
        }
    } else if (gAdOpening) {
        // DidLoadSuccess 没来（素材拉取失败 / 广告已无库存），20 秒算本轮失败
        if (gAdOpenAt > 0 &&
            [[NSDate date] timeIntervalSince1970] - gAdOpenAt > 20) {
            // 一次失败不丢整轮：失败多半是因为 token 被上一次用掉了，
            // 换新 token 再开一次。还不行才认输。
            if (!gAdRetried && LCAdCurrentToken().length > 40) {
                gAdRetried = YES;
                LCAutoLog(@"[ad] 20 秒没开出来，换新 token 重试一次");
                gAdOpenAt = [[NSDate date] timeIntervalSince1970];
                (void)LCAdTrigger();
            } else {
                LCAutoLog(@"[ad] 重试也没开出来，本轮作废");
                gAdOpenAt = 0;
                gAdOpening = NO;
                gAdSawClose = YES;   // 借 close 分支推进下一轮
            }
        }
    }
}

static void LCScheduleNext(void) {
    if (!gAdBusy) return;
    if (gAdRemain <= 0) {
        gAdBusy = NO;
        if (gDrawActive) {
            // 连续刷视频：一条广告关掉才算一次，并进入 300 秒冷却
            gDrawActive = NO;
            gDrawDone++;
            gDrawRemain--;
            gDrawTapAt = 0;
            gDrawCoolAt = [[NSDate date] timeIntervalSince1970];
            LCAutoLog(@"[draw] 第 %ld 次完成，剩 %ld 次，冷却 5 分钟",
                      (long)gDrawDone, (long)gDrawRemain);
            if (gDrawRemain <= 0 && gDrawTimer) {
                [gDrawTimer invalidate];
                gDrawTimer = nil;
                LCAutoLog(@"[draw] 全部完成，共 %ld 次", (long)gDrawDone);
            }
            return;
        }
        if (gDurActive) {
            // 领时长：一条广告关掉才算一次
            gDurActive = NO;
            gDurDone++;
            gDurRemain--;
            gDurTapAt = 0;          // 允许立刻点下一次
            LCAutoLog(@"[dur] 第 %ld 次完成，剩 %ld 次", (long)gDurDone, (long)gDurRemain);
            if (gDurRemain <= 0 && gDurTimer) {
                [gDurTimer invalidate];
                gDurTimer = nil;
                LCAutoLog(@"[dur] 全部完成，共 %ld 次", (long)gDurDone);
            }
        } else {
            LCAutoLog(@"[ad] 全部完成，共 %ld 次", (long)gAdTotalCount);
        }
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
    // !!! 这里以前是"已生效，提前关闭" !!!
    // becomeEffective 的真实含义是「这次曝光算有效，可以结算了」，
    // 不是「视频播完了」。实测 15 秒就回调，而广告是 30 秒的。
    // 在这时候关，等于把「领取成功 ×」和「再看一个视频 +300」全跳过了,
    // 用户看到的就是"广告突然没了，直接回福利页"。
    // 现在只记时间，关闭统一交给 LCTick 按文案判断。
    if (gAdBusy && gAdPlaying) {
        gAdEffectiveAt = [[NSDate date] timeIntervalSince1970];
        LCAutoLog(@"[ad] 曝光已生效(%.0fs)，继续播，等广告自己结束",
                  gAdEffectiveAt - gAdPlayStart);
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
// addRecord 侧的入口：只计数，不打日志
static volatile int gTaskLastLen = 0;
static volatile int gTaskLastB64 = 0;
static volatile int gTaskShort = 0;

void LCAdNoteTaskPage(NSString *body, BOOL isBase64) {
    gTaskPageSeen++;
    gTaskLastLen = (int)body.length;
    gTaskLastB64 = isBase64 ? 1 : 0;
    if (isBase64 || body.length < 200) { gTaskShort++; return; }
    gTaskPageParsed++;
    LCAdNotePageResponse(body);
}

// 导出日志时打一行，代替原来每条都打
void LCAdTaskPageStats(void) {
    LCAutoLog(@"[ad] 任务页命中 %d 次，可解析 %d 次，被跳过 %d 次 "
              @"(最后一条 %dB b64=%d)，token %@，schema %@",
              LCAdTaskPageSeen(), LCAdTaskPageParsed(), gTaskShort,
              gTaskLastLen, gTaskLastB64,
              gAdFreshToken ? [NSString stringWithFormat:@"%luB",
                               (unsigned long)gAdFreshToken.length] : @"无",
              gDurSchema ? [NSString stringWithFormat:@"%luB",
                            (unsigned long)gDurSchema.length] : @"无");
}

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

            // 顺手把「领时长」的 schema 抠出来
            if ([key isKindOfClass:[NSString class]] &&
                [key isEqualToString:@"luna_rewards_ads"]) {
                id vv = dd[@"view"];
                if ([vv isKindOfClass:[NSDictionary class]]) {
                    id bb = ((NSDictionary *)vv)[@"button"];
                    if ([bb isKindOfClass:[NSDictionary class]]) {
                        id sc = ((NSDictionary *)bb)[@"schema"];
                        if ([sc isKindOfClass:[NSString class]] && [sc length] > 40 &&
                            [sc hasPrefix:@"sslocal://"]) {
                            if (!gDurSchema || ![gDurSchema isEqualToString:sc]) {
                                gDurSchema = [sc copy];
                                LCAutoLog(@"[dur] 拿到领时长 schema(%luB)",
                                          (unsigned long)[sc length]);
                            }
                        }
                    }
                }
            }

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
    if (!found) {
        // 没匹配到就报一次，别静默 —— 之前就是静默导致误判成"刷新没生效"
        static int missOnce = 0;
        if (missOnce++ < 3) {
            LCAutoLog(@"[ad] 任务页里没找到 music_incentive_ad 的 token(body %luB)",
                      (unsigned long)body.length);
        }
        return;
    }
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
    gAdRetried = NO;
    gAdDumped = NO;
    gAdEffectiveAt = 0;

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
        NSString *tk = LCAdCurrentToken();
        LCAutoLog(@"[ad] 已触发 bridge(token %@)",
                  tk ? [NSString stringWithFormat:@"新的 %luB", (unsigned long)tk.length]
                     : @"沿用点击时那个");
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

#pragma mark - 卡死自救

// 广告 VC 被 present 到浮窗 window 时，App 主 window 里会留一个全屏的
// BDARVLoadingView。广告关掉后它没人移除，整屏点不动，只能杀进程。
// 这里按类名把它摘掉。
static NSInteger LCStripLoading(UIView *v, int depth) {
    if (!v || depth > 40) return 0;
    NSInteger n = 0;
    NSString *cn = NSStringFromClass([v class]);
    BOOL isAdLoading = [cn hasPrefix:@"BDARV"] &&
                       ([cn containsString:@"Loading"] || [cn containsString:@"Indicator"]);
    NSArray *kids = [v.subviews copy];
    for (UIView *k in kids) n += LCStripLoading(k, depth + 1);
    if (isAdLoading && v.superview) {
        [v removeFromSuperview];
        n++;
    }
    return n;
}

NSInteger LCAdCleanupStuck(void) {
    NSInteger n = 0;
    // 广告真的在播时不要动，否则会把正在展示的素材摘了
    if (gAdPlaying || gAdOpening) {
        LCAutoLog(@"[ad] 广告正在播，跳过清理");
        return 0;
    }

    for (UIWindow *w in LCAllWindows()) {
        NSInteger k = LCStripLoading(w.rootViewController.view, 0);
        if (k > 0) {
            LCAutoLog(@"[ad] 摘掉 %ld 个残留 loading 视图 <%@>",
                      (long)k, NSStringFromClass([w class]));
            n += k;
        }
    }

    // 再 dismiss 掉残留在任意 window 上的 presented VC。
    // 只处理非系统 VC，避免把分享面板之类的东西错杀。
    for (UIWindow *w in LCAllWindows()) {
        UIViewController *root = w.rootViewController;
        if (!root.presentedViewController) continue;
        NSString *cn = NSStringFromClass([root.presentedViewController class]);
        if ([cn hasPrefix:@"UI"] || [cn hasPrefix:@"_UI"] ||
            [cn containsString:@"Activity"] || [cn containsString:@"Alert"]) continue;
        LCAutoLog(@"[ad] dismiss 残留 VC <%@>", cn);
        [root dismissViewControllerAnimated:NO completion:nil];
        n++;
    }

    LCAutoLog(@"[ad] 清理完成，共处理 %ld 个视图", (long)n);
    return n;
}

// 领时长的广告不是通过 bridge 触发的，是用户在活动页点按钮后 SDK 自己加载。
// 所以状态机要由外部接管：把 gAdBusy 打开、轮次归零，让 LCTick 只管
// 「等 DidLoadSuccess → 播够 → 点领取成功 → 关闭」，关完 LCScheduleNext
// 看到 gAdRemain<=0 会自动收尾。
static void LCAdBeginExternal(void) {
    if (gAdTimer) { [gAdTimer invalidate]; gAdTimer = nil; }
    gAdBusy      = YES;
    gAdRemain    = 0;
    // 不能设成 gAdOpening —— 那条分支要等 DidLoadSuccess 回调，而领时长的广告
    // 走的是 BDARV（BDARRefactorLynxVideoWrappView + BDASDKVideoPlayer），
    // 不经过 BDUGLuckyADRewardVideoManager，回调永远不来，20 秒后就被判
    // 「重试也没开出来，本轮作废」（实测 04:07:54 就是这样）。
    // 用户点了按钮广告必然在播，直接进播放态，靠轮询找「领取成功」去关。
    gAdOpening   = NO;
    gAdPlaying   = YES;
    gAdPlayStart = [[NSDate date] timeIntervalSince1970];
    gAdClosing   = NO;
    gAdSawClose  = NO;
    gAdDumped    = NO;
    gAdCloseTryAt = 0;
    gAdOpenAt    = [[NSDate date] timeIntervalSince1970];
    gAdTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                repeats:YES
                                                  block:^(NSTimer *t) { LCTick(); }];
    LCAutoLog(@"[dur] 已接管广告状态机，等 DidLoadSuccess");
}

#pragma mark - 领时长（攒时长 听歌不中断）

// 任务 600590 luna_rewards_ads，action=redirect，schema 是
//   sslocal://luckydog/activity_task?luckydog_task_type=luna_watch_ads_settle_vip
// 也就是「看一条激励视频换 1 天 VIP 时长」。广告本身走 lucky 那套，
// 已经 hook 了 DidLoadSuccess / becomeEffective / close，播完能自动关。
// 这里只需要把「点领时长 → 点活动页的广告按钮」这两步接上。

// 金币页是 Lynx 渲染的，任务卡在 Lynx 的 canvas 里 —— UIKit 树里只有
// 一个全屏 LynxView，手势全挂在它身上，合成点击不知道该点哪儿。
// 所以入口改用 schema 直接路由：sslocal://luckydog/activity_task?...
// 这是 App 自己的 scheme，openURL 会回到 App 的 router 去处理。
static BOOL LCOpenSchema(NSString *schema) {
    if (schema.length < 20) return NO;
    NSURL *u = [NSURL URLWithString:schema];
    if (!u) return NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] openURL:u
                                           options:@{}
                                 completionHandler:^(BOOL ok) {
            LCAutoLog(@"[dur] openURL(%@) -> %@", u.scheme, ok ? @"OK" : @"失败");
        }];
    });
    return YES;
}

static NSArray *LCDurationEntryTexts(void) {
    return @[@"领时长", @"去领取时长", @"领取时长"];
}

static NSArray *LCDurationAdTexts(void) {
    return @[@"看广告领时长", @"看视频领时长", @"立即观看", @"立即领取",
             @"看广告", @"观看广告", @"开始观看", @"去观看", @"免费领取"];
}

static void LCDurationTick(void) {
    if (gDurRemain <= 0) {
        [gDurTimer invalidate];
        gDurTimer = nil;
        LCAutoLog(@"[dur] 完成，共领 %ld 次", (long)gDurDone);
        return;
    }
    // 广告正在走，交给广告模块
    if (gAdPlaying || gAdOpening) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (gDurTapAt > 0 && now - gDurTapAt < 6) return;   // 点击限流

    // ① 活动页里的广告按钮
    UIView *btn = LCFindByTextAnywhere(LCDurationAdTexts());
    if (btn) {
        gDurTapAt = now;
        BOOL ok = LCTapLynxView(btn);
        LCAutoLog(@"[dur] 活动页点「%@」<%@> %@",
                  LCTextOfView(btn), NSStringFromClass([btn class]),
                  ok ? @"已发送" : @"点不动");
        if (ok) {
            // 这里不减轮次。之前一点就减，广告其实还在播，
            // 3 次点击等于 1 次广告，日志却写「完成，共领 3 次」（假完成）。
            // 改成广告真关掉时在 LCScheduleNext 里记账。
            gDurActive = YES;
            LCAdBeginExternal();
        }
        return;
    }

    // ② 金币任务卡里的「领时长」按钮。整页是 Lynx 画的，只能合成触摸。
    if (LCTapCardButton(@"攒时长 听歌不中断")) {
        gDurTapAt = now;
        gDurActive = YES;
        LCAdBeginExternal();
        return;
    }

    // ③ 用 schema 打开活动页（合成触摸也不灵时的备用）
    // 活动页加载要时间，25 秒内不重复 openURL，否则会一直重跳。
    if (gDurSchema.length > 20 && gDurOpenFails < 3 &&
        (gDurOpenAt <= 0 || now - gDurOpenAt > 25)) {
        gDurOpenAt = now;
        LCAutoLog(@"[dur] 用 schema 打开领时长活动页");
        if (LCOpenSchema(gDurSchema)) return;
        gDurOpenFails++;
    }

    // ④ 实在没有 schema 才退回文案点击
    btn = LCFindByTextAnywhere(LCDurationEntryTexts());
    if (btn) {
        gDurTapAt = now;
        BOOL ok = LCTapLynxView(btn);
        LCAutoLog(@"[dur] 点入口「%@」<%@> %@",
                  LCTextOfView(btn), NSStringFromClass([btn class]),
                  ok ? @"已发送" : @"点不动");
        return;
    }

    // ④ 什么都没有 —— 金币页是 Lynx 画的，UI 点不动，schema 也进不去时
    // 只能请用户手动点一次。点进去之后 tick 会接手：找广告按钮 → 自动播 → 自动关。
    static NSTimeInterval lastWarn = 0;
    if (now - lastWarn > 20) {
        lastWarn = now;
        if (gDurSchema.length <= 20) {
            LCAutoLog(@"[dur] 还没拿到 schema，请等金币页刷出来再点一次");
        } else {
            LCAutoLog(@"[dur] 进不去活动页 —— 请手动点一次「领时长」，进去后我会接手");
        }
        LCDumpAdViewTree();
    }
}

// 菜单「打开领时长页」用：单独验证 sslocal:// 路由通不通，
// 不用等整个 ×3 流程跑一遍。
BOOL LCAdOpenDurationPage(void) {
    if (gDurSchema.length <= 20) {
        LCAutoLog(@"[dur] 还没有 schema(需要先让金币任务页加载一次)");
        return NO;
    }
    BOOL ok = LCOpenSchema(gDurSchema);
    LCAutoLog(@"[dur] 手动打开活动页 -> %@", ok ? @"已发出" : @"失败");
    return ok;
}

#pragma mark - 连续刷视频（任务 601232 luna_treasure_draw_duration）

// 点「连续刷视频赚金币」卡片右侧的「去完成」→ 拉起激励视频（rit=73032）
// → 播完自动关 → 领金币 → 冷却 300 秒（服务端 countdown_config.end_time
//   减 last_completed_time 实测正好 300）→ 再来。
// 上限 20 次/天（stats.total_times）。
static void LCAutoDrawTick(void) {
    if (gDrawRemain <= 0) {
        [gDrawTimer invalidate];
        gDrawTimer = nil;
        LCAutoLog(@"[draw] 全部完成，共 %ld 次", (long)gDrawDone);
        return;
    }
    if (gAdPlaying || gAdOpening) return;      // 广告在走，等它

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    // 冷却期：服务端 300 秒，多给 15 秒余量
    if (gDrawCoolAt > 0 && now - gDrawCoolAt < 315) {
        return;
    }
    if (gDrawTapAt > 0 && now - gDrawTapAt < 8) return;

    if (LCTapCardButton(@"连续刷视频赚金币")) {
        gDrawTapAt = now;
        gDrawCoolAt = 0;
        gDrawActive = YES;
        LCAdBeginExternal();
        return;
    }

    // 找不到按钮 —— 可能还在冷却（按钮文案变成倒计时），也可能页面滚走了
    static NSTimeInterval lastWarn = 0;
    if (now - lastWarn > 30) {
        lastWarn = now;
        LCAutoLog(@"[draw] 没找到「连续刷视频赚金币」的按钮，抓一次界面树");
        LCDumpAdViewTree();
    }
}

void LCAutoDraw(NSInteger times) {
    if (times <= 0) times = 1;
    if (times > 20) times = 20;
    gDrawRemain = times;
    gDrawDone = 0;
    gDrawActive = NO;
    gDrawTapAt = 0;
    gDrawCoolAt = 0;
    LCAutoLog(@"[draw] 开始连续刷视频 ×%ld（每轮约 5 分钟冷却）", (long)times);
    if (gDrawTimer) [gDrawTimer invalidate];
    gDrawTimer = [NSTimer scheduledTimerWithTimeInterval:5.0
                                                 repeats:YES
                                                   block:^(NSTimer *t) { LCAutoDrawTick(); }];
    LCAutoDrawTick();
}

void LCAutoDuration(NSInteger times) {
    if (times <= 0) times = 1;
    if (times > 10) times = 10;
    gDurRemain = times;
    gDurDone = 0;
    gDurTapAt = 0;
    gDurOpenAt = 0;
    gDurOpenFails = 0;
    gDurActive = NO;
    LCAutoLog(@"[dur] 开始领时长 ×%ld", (long)times);
    if (gDurTimer) [gDurTimer invalidate];
    gDurTimer = [NSTimer scheduledTimerWithTimeInterval:1.5
                                                repeats:YES
                                                  block:^(NSTimer *t) { LCDurationTick(); }];
    LCDurationTick();
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
