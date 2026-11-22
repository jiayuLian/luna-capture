#import "LunaCapture.h"

#pragma mark - 只让按钮吃触摸的 window

@interface LCFloatWindow : UIWindow
@property (nonatomic, assign) BOOL menuOpen;
@end

@implementation LCFloatWindow

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    // 菜单展开时接管全屏(用于点遮罩关闭),其余时候只有按钮自己响应
    if (self.menuOpen) return YES;
    UIView *root = self.rootViewController.view;
    if (!root) return NO;
    CGPoint p = [root convertPoint:point fromView:self];
    UIView *hit = [root hitTest:p withEvent:event];
    return (hit != nil && hit != root);
}

@end

#pragma mark - 浮层控制器

@interface LCFloatVC : UIViewController
@property (nonatomic, strong) UIButton *btn;
@property (nonatomic, strong) UIView *menuMask;
@property (nonatomic, assign) CGRect buttonRect;
- (void)lcExport:(BOOL)har;
- (void)runAutoClaim;
- (void)runAutoAd;
- (void)stopAutoAd;
- (void)exportLog;
- (void)showAutoTail;
@end

static LCFloatWindow *gWindow = nil;

// 取 App 自己的 view controller 用来弹系统分享,绝不能返回我们自己的 window
static UIViewController *LCAppVC(void) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w == gWindow) continue;
        if (w.isHidden || !w.rootViewController) continue;
        UIViewController *vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        return vc;
    }
    return nil;
}

@implementation LCFloatVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = self.buttonRect;
    btn.backgroundColor = [UIColor colorWithRed:0.98 green:0.19 blue:0.35 alpha:0.94];
    btn.layer.cornerRadius = CGRectGetWidth(self.buttonRect) / 2.0;
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOpacity = 0.35;
    btn.layer.shadowRadius = 4;
    btn.layer.shadowOffset = CGSizeMake(0, 2);
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [btn setTitle:@"0" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    [btn addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [btn addGestureRecognizer:pan];

    [self.view addSubview:btn];
    self.btn = btn;

    [[NSNotificationCenter defaultCenter] addObserverForName:@"LCUpdate"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
        if (!self.btn) return;
        NSString *t = [NSString stringWithFormat:@"%@", n.object];
        [self.btn setTitle:t forState:UIControlStateNormal];
    }];

    [self refresh];
}

- (void)refresh {
    NSUInteger n = [[LCCapture shared] count];
    [self.btn setTitle:[NSString stringWithFormat:@"%lu", (unsigned long)n]
              forState:UIControlStateNormal];
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.view];
    CGRect f = self.btn.frame;
    f.origin.x += t.x;
    f.origin.y += t.y;
    // 夹在屏幕内,别拖丢
    CGRect bounds = self.view.bounds;
    f.origin.x = MAX(0, MIN(f.origin.x, CGRectGetWidth(bounds) - CGRectGetWidth(f)));
    f.origin.y = MAX(0, MIN(f.origin.y, CGRectGetHeight(bounds) - CGRectGetHeight(f) - 34));
    self.btn.frame = f;
    [g setTranslation:CGPointZero inView:self.view];
}

#pragma mark 菜单(自绘,不依赖 present,避免容器尺寸问题)

- (void)onTap {
    if (self.menuMask) {
        [self hideMenu];
        return;
    }
    [self showMenu];
}

- (void)showMenu {
    CGRect b = self.view.bounds;

    UIView *mask = [[UIView alloc] initWithFrame:b];
    mask.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    [mask addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                     action:@selector(hideMenu)]];

    CGFloat pw = 250;
    CGFloat rowH = 46;
    NSArray *titles = @[@"导出 HAR", @"导出 JSON", @"导出日志", @"导出界面树",
                        @"自动领奖", @"广告全自动 ×10", @"停止广告",
                        @"清空记录", @"关闭菜单"];
    CGFloat ph = 54 + rowH * (CGFloat)titles.count + 12;

    UIView *panel = [[UIView alloc] initWithFrame:CGRectMake((b.size.width - pw) / 2.0,
                                                             (b.size.height - ph) / 2.0,
                                                             pw, ph)];
    panel.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.98];
    panel.layer.cornerRadius = 16;
    panel.layer.shadowColor = [UIColor blackColor].CGColor;
    panel.layer.shadowOpacity = 0.25;
    panel.layer.shadowRadius = 16;
    panel.layer.shadowOffset = CGSizeMake(0, 6);
    [mask addSubview:panel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 14, pw - 32, 40)];
    title.numberOfLines = 2;
    title.font = [UIFont boldSystemFontOfSize:13];
    title.textColor = [UIColor darkGrayColor];
    title.text = [NSString stringWithFormat:@"LunaCapture %@\n已记录 %lu 条",
                  LC_VER, (unsigned long)[[LCCapture shared] count]];
    [panel addSubview:title];

    for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
        UIButton *row = [UIButton buttonWithType:UIButtonTypeCustom];
        row.frame = CGRectMake(0, 54 + rowH * i, pw, rowH);
        row.tag = i;
        row.titleLabel.font = [UIFont systemFontOfSize:16];
        [row setTitle:titles[(NSUInteger)i] forState:UIControlStateNormal];
        UIColor *c = [UIColor darkTextColor];
        if (i == 2) c = [UIColor systemGreenColor];     // 导出日志
        if (i == 3) c = [UIColor systemTealColor];      // 导出界面树
        if (i == 4 || i == 5) c = [UIColor systemBlueColor];   // 自动领奖 / 广告
        if (i == 6) c = [UIColor systemOrangeColor];    // 停止
        if (i == 7) c = [UIColor systemRedColor];       // 清空记录
        [row setTitleColor:c forState:UIControlStateNormal];
        [row addTarget:self action:@selector(onMenuRow:) forControlEvents:UIControlEventTouchUpInside];

        if (i > 0) {
            UIView *line = [[UIView alloc] initWithFrame:CGRectMake(16, 0, pw - 32, 0.5)];
            line.backgroundColor = [UIColor colorWithWhite:0 alpha:0.12];
            [row addSubview:line];
        }
        [panel addSubview:row];
    }

    [self.view addSubview:mask];
    self.menuMask = mask;
    gWindow.menuOpen = YES;
}

- (void)hideMenu {
    [self.menuMask removeFromSuperview];
    self.menuMask = nil;
    gWindow.menuOpen = NO;
    [self refresh];
}

- (void)onMenuRow:(UIButton *)sender {
    switch (sender.tag) {
        case 0: [self lcExport:YES]; break;
        case 1: [self lcExport:NO];  break;
        case 2: [self exportLog]; break;
        case 3:
            LCDumpAdViewTree();
            [self hideMenu];
            [self toast:@"界面树已写入 lc_view.txt\n导出日志时一起带走"];
            break;
        case 4: [self runAutoClaim]; break;
        case 5: [self runAutoAd]; break;
        case 6: [self stopAutoAd]; break;
        case 7:
            [[LCCapture shared] clear];
            [self hideMenu];
            break;
        default:
            [self hideMenu];
            break;
    }
}

// 导出日志。沙盒 Documents 在「文件」App 里看不到,
// 所以和 HAR 一样走系统分享面板(AirDrop / 存到文件 / 发微信都行)。
- (void)exportLog {
    NSString *p = LCAutoExportLog();
    if (p.length == 0) {
        [self toast:@"日志导出失败"];
        return;
    }
    NSURL *u = [NSURL fileURLWithPath:p];
    UIActivityViewController *avc =
        [[UIActivityViewController alloc] initWithActivityItems:@[u]
                                         applicationActivities:nil];
    avc.popoverPresentationController.sourceView = self.btn;
    avc.popoverPresentationController.sourceRect = self.btn.bounds;

    UIViewController *top = LCAppVC();
    if (!top) top = self;
    [self hideMenu];
    [top presentViewController:avc animated:YES completion:nil];
}

// 自动领奖:走 App 自己的网络层发 do_action,签名与设备指纹由 App 生成。
// 先把菜单收起,否则日志 toast 会被遮罩挡住。
- (void)runAutoClaim {
    [self hideMenu];

    if (LCAutoBusy()) {
        [self toast:@"上一轮还在跑,稍等"];
        return;
    }
    if (!LCAutoPrepare()) {
        [self toast:@"先打开一次金币页再运行"];
        return;
    }

    [self toast:@"开始领奖,约 20 秒"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LCAutoRun();
    });

    // 固定两个时间点取日志尾。不用递归 block —— 自引用会触发
    // -Warc-retain-cycles,在 -Werror 下直接编译失败。
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [ws showAutoTail];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(32 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [ws showAutoTail];
    });
}

// 循环看激励视频。
// 广告本身仍由 App 播放(真实曝光),这里只是反复替用户点那个按钮,
// 所以服务端看到的时长、曝光、完播都是真的,不需要伪造 time_token。
- (void)runAutoAd {
    [self hideMenu];

    if (!LCAdHasTemplate()) {
        [self toast:@"先在 App 里手动点一次\n「看广告赚金币」\n让它把参数录下来"];
        return;
    }
    if (LCAdBusy()) {
        [self toast:@"广告循环已经在跑"];
        return;
    }

    LCAdRun(10);
    [self toast:@"全自动:开广告→播16秒→自动关\n每轮约21秒,共10轮"];

    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [ws showAutoTail]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(130 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [ws showAutoTail]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(230 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [ws showAutoTail]; });
}

- (void)stopAutoAd {
    [self hideMenu];
    if (!LCAdBusy()) {
        [self toast:@"当前没在跑"];
        return;
    }
    LCAdStop();
    [self toast:@"已停止"];
}

- (void)showAutoTail {
    NSString *log = LCAutoLogText();
    if (log.length == 0) {
        [self toast:@"还没有日志"];
        return;
    }
    NSArray *lines = [log componentsSeparatedByString:@"\n"];
    NSUInteger n = lines.count;
    NSUInteger take = MIN((NSUInteger)4, n);
    NSString *tail = [[lines subarrayWithRange:NSMakeRange(n - take, take)]
                      componentsJoinedByString:@"\n"];
    [self toast:tail];
}

// 方法名不能叫 export:,那是 UIResponder 自带的(iOS 16+),会撞签名
- (void)lcExport:(BOOL)har {
    NSString *p = har ? [[LCCapture shared] exportHAR]
                      : [[LCCapture shared] exportJSON];
    if (p.length == 0) {
        [self toast:@"导出失败,看控制台日志"];
        return;
    }

    [self hideMenu];

    UIActivityViewController *avc =
        [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:p]]
                                         applicationActivities:nil];
    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.sourceView = self.btn;
        avc.popoverPresentationController.sourceRect = self.btn.bounds;
    }
    // 一定要弹在 App 自己的 VC 上,弹在这个全屏浮窗里会出容器尺寸问题
    UIViewController *host = LCAppVC() ?: self;
    [host presentViewController:avc animated:YES completion:nil];
}

- (void)toast:(NSString *)msg {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = msg;
    l.font = [UIFont systemFontOfSize:14];
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.82];
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 2;
    l.layer.cornerRadius = 10;
    l.clipsToBounds = YES;
    CGSize s = [l sizeThatFits:CGSizeMake(260, 200)];
    l.frame = CGRectMake((self.view.bounds.size.width - s.width - 32) / 2.0,
                         self.view.bounds.size.height - 140,
                         s.width + 32, s.height + 20);
    [self.view addSubview:l];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [l removeFromSuperview]; });
}

@end

#pragma mark - 安装

static void LCScheduleUI(int attempt);

static BOOL LCSetupUI_inner(void) {
    if (gWindow) {
        gWindow.hidden = NO;
        return YES;
    }

    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat size = 54;
    CGFloat x = screen.size.width - size - 12;
    CGFloat y = screen.size.height * 0.35;

    LCFloatWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                w = [[LCFloatWindow alloc] initWithWindowScene:(UIWindowScene *)s];
                break;
            }
        }
        if (!w) return NO;   // 场景没就绪,下一轮再试
    } else {
        w = [[LCFloatWindow alloc] initWithFrame:screen];
    }

    // window 必须全屏:设成 54x54 会让 present 出来的系统控件被压进这个小容器
    w.frame = screen;
    w.windowLevel = UIWindowLevelAlert + 50;
    w.backgroundColor = [UIColor clearColor];
    w.menuOpen = NO;

    LCFloatVC *vc = [LCFloatVC new];
    vc.buttonRect = CGRectMake(x, y, size, size);
    w.rootViewController = vc;
    w.hidden = NO;

    gWindow = w;
    return YES;
}

static void LCScheduleUI(int attempt) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (LCSetupUI_inner()) {
            NSLog(@"[LC] UI ready (attempt %d)", attempt);
            return;
        }
        if (attempt < 30) {
            LCScheduleUI(attempt + 1);
        } else {
            NSLog(@"[LC] UI gave up after %d attempts", attempt);
        }
    });
}

void LCSetupUI(void) {
    LCScheduleUI(0);
}
