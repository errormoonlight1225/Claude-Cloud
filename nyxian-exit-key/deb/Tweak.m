/*
 * ExitKey — 悬浮退出键（越狱插件 .deb）
 *
 * 注入到每个 UIKit App，在 App 里显示一个可拖动的红色 ✕：
 *   - 单击：结束当前 App（回到 Nyxian / 伪越狱桌面）
 *   - 长按：菜单 —— 退出 App / 本次隐藏按钮
 *   - 拖动：移动按钮，松手吸附到左右边缘，位置会被记住
 *
 * 不 Hook 任何方法，不依赖 Substrate / ElleKit 的 API，
 * 只要插件加载器把 dylib 注入进 App 就能工作。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <stdlib.h>

static NSString *const kEKPositionKey = @"ExitKey.ButtonCenter";
static const CGFloat kEKButtonSize = 36.0;
static const NSTimeInterval kEKIdleDelay = 2.5;   /* 多久不碰就变淡 */
static const CGFloat kEKIdleAlpha = 0.35;         /* 变淡后的透明度 */
static const CGFloat kEKTuck = 0.45;              /* 变淡时缩进屏幕边缘的比例 */

#pragma mark - 是否应该在当前进程显示

static BOOL EKShouldRun(void)
{
    NSBundle *main = NSBundle.mainBundle;
    NSString *path = main.bundlePath;
    NSString *bid = main.bundleIdentifier ?: @"";

    /* 只在真正的 App 里显示，跳过 App 扩展、守护进程等 */
    if (![path.pathExtension isEqualToString:@"app"]) return NO;

    /* 跳过桌面 / 宿主本身，否则会把整个环境退出 */
    NSArray *skip = @[
        @"com.apple.springboard",
        @"org.emexlabs.nyxian",
        @"com.apple.PineBoard",
        @"com.apple.InCallService",
    ];
    if ([skip containsObject:bid]) return NO;
    return YES;
}

#pragma mark - 只拦截按钮触摸的透明窗口

@interface EKOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *button;
@end

@implementation EKOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    if (self.button != nil && hit != nil && [hit isDescendantOfView:self.button]) return hit;
    return nil; /* 其它触摸穿透给 App */
}
@end

@interface EKRootViewController : UIViewController
@end

@implementation EKRootViewController
- (void)loadView
{
    self.view = [UIView new];
    self.view.backgroundColor = UIColor.clearColor;
}
/* 不影响 App 自己的状态栏和旋转 */
- (BOOL)prefersStatusBarHidden { return UIApplication.sharedApplication.statusBarHidden; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end

#pragma mark - 控制器

@interface EKController : NSObject
@property (nonatomic, strong) EKOverlayWindow *window;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic) CGPoint restCenter;   /* 吸边后的正常位置 */
@property (nonatomic) NSUInteger idleToken;
+ (instancetype)shared;
- (void)tryInstall;
@end

@implementation EKController

+ (instancetype)shared
{
    static EKController *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [EKController new]; });
    return s;
}

- (UIWindowScene *)activeScene
{
    UIWindowScene *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
        if (fallback == nil) fallback = (UIWindowScene *)scene;
    }
    return fallback;
}

- (void)tryInstall
{
    UIWindowScene *scene = [self activeScene];
    if (scene == nil) return;

    if (self.window != nil) {
        /* App 换了 scene（比如重新连接）就跟过去 */
        if (self.window.windowScene != scene) self.window.windowScene = scene;
        return;
    }

    EKOverlayWindow *window = [[EKOverlayWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelAlert + 100;
    window.backgroundColor = UIColor.clearColor;
    window.rootViewController = [EKRootViewController new];

    UIButton *button = [self makeButton];
    [window.rootViewController.view addSubview:button];
    window.button = button;
    window.hidden = NO; /* 不 makeKey，避免抢键盘焦点 */

    self.window = window;
    self.button = button;
    [self restorePosition];
}

- (UIButtonConfiguration *)buttonConfiguration
{
    UIButtonConfiguration *config = nil;
    /* iOS 26 有原生 Liquid Glass 按钮样式，优先用它 */
    SEL glass = NSSelectorFromString(@"glassButtonConfiguration");
    if ([UIButtonConfiguration respondsToSelector:glass]) {
        config = ((UIButtonConfiguration *(*)(id, SEL))[UIButtonConfiguration methodForSelector:glass])(UIButtonConfiguration.class, glass);
    }
    if (config == nil) {
        config = [UIButtonConfiguration plainButtonConfiguration];
        config.background.visualEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
        config.background.strokeColor = [UIColor colorWithWhite:1.0 alpha:0.25];
        config.background.strokeWidth = 0.5;
    }
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.contentInsets = NSDirectionalEdgeInsetsZero;
    config.baseForegroundColor = UIColor.labelColor;
    config.image = [UIImage systemImageNamed:@"xmark"
                           withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightSemibold]];
    return config;
}

- (UIButton *)makeButton
{
    UIButtonConfiguration *config = [self buttonConfiguration];

    UIAction *quit = [UIAction actionWithTitle:@"退出 App" image:nil identifier:nil handler:^(__unused UIAction *a) {
        [EKController quitApp];
    }];

    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:quit];
    button.frame = CGRectMake(0, 0, kEKButtonSize, kEKButtonSize);
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.15;
    button.layer.shadowRadius = 4;
    button.layer.shadowOffset = CGSizeMake(0, 1);
    button.accessibilityLabel = @"退出 App";

    __weak typeof(self) weakSelf = self;
    UIAction *menuQuit = [UIAction actionWithTitle:@"退出 App"
                                             image:[UIImage systemImageNamed:@"xmark.circle"]
                                        identifier:nil
                                           handler:^(__unused UIAction *a) { [EKController quitApp]; }];
    menuQuit.attributes = UIMenuElementAttributesDestructive;
    UIAction *hide = [UIAction actionWithTitle:@"本次隐藏按钮"
                                         image:[UIImage systemImageNamed:@"eye.slash"]
                                    identifier:nil
                                       handler:^(__unused UIAction *a) { weakSelf.window.hidden = YES; }];
    button.menu = [UIMenu menuWithTitle:@"ExitKey" children:@[menuQuit, hide]];
    button.showsMenuAsPrimaryAction = NO; /* 单击 = 退出，长按 = 菜单 */

    /* 一碰就醒过来 */
    [button addAction:[UIAction actionWithHandler:^(__unused UIAction *a) { [weakSelf wake]; }]
     forControlEvents:UIControlEventTouchDown];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [button addGestureRecognizer:pan];
    return button;
}

+ (void)quitApp
{
    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
    /* 给触感一点时间，然后正常退出进程，宿主会关闭这个 App 的窗口 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        exit(0);
    });
}

#pragma mark 拖动 + 吸边

- (void)handlePan:(UIPanGestureRecognizer *)pan
{
    UIView *button = pan.view;
    UIView *container = button.superview;
    if (container == nil) return;
    if (pan.state == UIGestureRecognizerStateBegan) [self wake];

    CGPoint t = [pan translationInView:container];
    button.center = CGPointMake(button.center.x + t.x, button.center.y + t.y);
    [pan setTranslation:CGPointZero inView:container];

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGPoint target = [self snappedCenter:button.center];
        self.restCenter = target;
        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:0 animations:^{
            button.center = target;
        } completion:nil];
        [self scheduleIdle];
        [NSUserDefaults.standardUserDefaults setObject:NSStringFromCGPoint(target) forKey:kEKPositionKey];
    }
}

- (CGPoint)snappedCenter:(CGPoint)p
{
    UIView *container = self.button.superview;
    CGRect b = container.bounds;
    UIEdgeInsets safe = container.safeAreaInsets;
    CGFloat half = kEKButtonSize / 2.0, margin = 8.0;

    CGFloat minX = CGRectGetMinX(b) + safe.left + half + margin;
    CGFloat maxX = CGRectGetMaxX(b) - safe.right - half - margin;
    CGFloat minY = CGRectGetMinY(b) + safe.top + half + margin;
    CGFloat maxY = CGRectGetMaxY(b) - safe.bottom - half - margin;

    CGFloat x = (p.x < CGRectGetMidX(b)) ? minX : maxX;
    CGFloat y = MIN(MAX(p.y, minY), maxY);
    return CGPointMake(x, y);
}

- (void)restorePosition
{
    UIView *container = self.button.superview;
    [container layoutIfNeeded];

    CGPoint p = CGPointMake(CGRectGetMaxX(container.bounds), CGRectGetHeight(container.bounds) * 0.35);
    NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kEKPositionKey];
    if (saved.length) p = CGPointFromString(saved);
    self.restCenter = [self snappedCenter:p];
    self.button.center = self.restCenter;
    [self scheduleIdle];
}

#pragma mark 闲置变淡 + 缩进边缘

- (void)wake
{
    self.idleToken++;
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self.button.alpha = 1.0;
        self.button.center = self.restCenter;
    } completion:nil];
    [self scheduleIdle];
}

- (void)scheduleIdle
{
    NSUInteger token = ++self.idleToken;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kEKIdleDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) self_ = weakSelf;
        if (self_ == nil || self_.idleToken != token) return;
        if (self_.button.isTracking) { [self_ scheduleIdle]; return; }
        UIView *container = self_.button.superview;
        CGFloat shift = kEKButtonSize * kEKTuck;
        BOOL left = self_.restCenter.x < CGRectGetMidX(container.bounds);
        CGPoint tucked = CGPointMake(self_.restCenter.x + (left ? -shift : shift), self_.restCenter.y);
        [UIView animateWithDuration:0.35 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
            self_.button.alpha = kEKIdleAlpha;
            self_.button.center = tucked;
        } completion:nil];
    });
}

@end

#pragma mark - 入口

__attribute__((constructor))
static void ExitKeyInit(void)
{
    @autoreleasepool {
        if (!EKShouldRun()) return;

        void (^install)(NSNotification *) = ^(__unused NSNotification *n) {
            [[EKController shared] tryInstall];
        };
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:install];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:install];
    }
}
