#import "LunaCapture.h"

#pragma mark - 只让按钮吃触摸的 window(不挡 App 其他区域)

@interface LCFloatWindow : UIWindow
@end

@implementation LCFloatWindow

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    for (UIView *v in self.subviews) {
        if (!v.hidden && CGRectContainsPoint(v.frame, point)) return YES;
    }
    return NO;
}

@end

#pragma mark - 悬浮控制器

@interface LCFloatVC : UIViewController
@property (nonatomic, strong) UIButton *btn;
@end

static LCFloatWindow *gWindow = nil;

static UIViewController *LCTopVC(void) {
    UIWindow *key = nil;
    NSArray *wins = [UIApplication sharedApplication].windows;
    for (NSInteger i = (NSInteger)wins.count - 1; i >= 0; i--) {
        UIWindow *w = wins[(NSUInteger)i];
        if (w.isKeyWindow && w != gWindow) { key = w; break; }
    }
    if (!key) key = gWindow;
    UIViewController *vc = key.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void LCPresentShare(NSString *path, UIView *anchor) {
    if (path.length == 0) return;
    NSURL *u = [NSURL fileURLWithPath:path];
    UIActivityViewController *avc =
        [[UIActivityViewController alloc] initWithActivityItems:@[u]
                                         applicationActivities:nil];
    UIViewController *top = LCTopVC();
    if (avc.popoverPresentationController) {
        avc.popoverPresentationController.sourceView = anchor;
        avc.popoverPresentationController.sourceRect = anchor.bounds;
    }
    [top presentViewController:avc animated:YES completion:nil];
}

@implementation LCFloatVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    CGFloat size = 54;
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake(0, 0, size, size);
    btn.backgroundColor = [UIColor colorWithRed:0.98 green:0.19 blue:0.35 alpha:0.92];
    btn.layer.cornerRadius = size / 2.0;
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOpacity = 0.35;
    btn.layer.shadowRadius = 4;
    btn.layer.shadowOffset = CGSizeMake(0, 2);
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [btn setTitle:@"0" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];

    [btn addTarget:self
            action:@selector(onTap)
  forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [btn addGestureRecognizer:pan];

    [self.view addSubview:btn];
    self.btn = btn;

    [[NSNotificationCenter defaultCenter] addObserverForName:@"LCUpdate"
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *n) {
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
    CGPoint t = [g translationInView:nil];
    CGPoint c = self.view.window.center;
    self.view.window.center = CGPointMake(c.x + t.x, c.y + t.y);
    [g setTranslation:CGPointZero inView:nil];
}

- (void)onTap {
    UIAlertController *ac =
        [UIAlertController alertControllerWithTitle:@"LunaCapture"
                                            message:[NSString stringWithFormat:
                                                     @"已记录 %lu 条 · %@",
                                                     (unsigned long)[[LCCapture shared] count],
                                                     LC_VER]
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    [ac addAction:[UIAlertAction actionWithTitle:@"导出 HAR"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        NSString *p = [[LCCapture shared] exportHAR];
        LCPresentShare(p, self.btn);
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"导出 JSON"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction *a) {
        NSString *p = [[LCCapture shared] exportJSON];
        LCPresentShare(p, self.btn);
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"清空"
                                           style:UIAlertActionStyleDestructive
                                         handler:^(UIAlertAction *a) {
        [[LCCapture shared] clear];
    }]];

    [ac addAction:[UIAlertAction actionWithTitle:@"收起按钮"
                                           style:UIAlertActionStyleCancel
                                         handler:^(UIAlertAction *a) {
        gWindow.hidden = YES;
    }]];

    if (ac.popoverPresentationController) {
        ac.popoverPresentationController.sourceView = self.btn;
        ac.popoverPresentationController.sourceRect = self.btn.bounds;
    }
    [LCTopVC() presentViewController:ac animated:YES completion:nil];
}

@end

#pragma mark - 安装

static void LCSetupUI_inner(void) {
    if (gWindow) {
        gWindow.hidden = NO;
        return;
    }

    CGRect screen = [UIScreen mainScreen].bounds;
    CGFloat size = 54;
    CGFloat x = screen.size.width - size - 12;
    CGFloat y = screen.size.height * 0.35;

    UIWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                w = [[LCFloatWindow alloc] initWithWindowScene:(UIWindowScene *)s];
                break;
            }
        }
    }
    if (!w) w = [[LCFloatWindow alloc] initWithFrame:screen];

    w.frame = CGRectMake(x, y, size, size);
    w.windowLevel = UIWindowLevelAlert + 50;
    w.backgroundColor = [UIColor clearColor];
    w.rootViewController = [LCFloatVC new];
    w.hidden = NO;

    gWindow = w;
    NSLog(@"[LC] UI ready");
}

void LCSetupUI(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        LCSetupUI_inner();
    });
}
