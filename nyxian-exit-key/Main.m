/*
 * ExitKey — Nyxian 悬浮退出键 (KEXT)
 *
 * 在 Nyxian 的窗口服务器上方加一个可拖动的悬浮按钮：
 *   - 单击：退出当前在前台的 App（等同于点它窗口的关闭按钮，并结束进程）
 *   - 长按：菜单 —— 退出当前 App / 退出全部 App / 多任务 / 回到桌面
 *   - 拖动：移动按钮，松手自动吸附到屏幕边缘，位置会被记住
 *
 * 这样运行别的软件时不用再把整个 Nyxian 关掉重开。
 *
 * 所有对 Nyxian 内部类的调用都先检查 respondsToSelector:，
 * 如果以后 Nyxian 改了接口，按钮只会失效，不会让环境崩溃。
 *
 * 目标：Nyxian 0.11.6.x（ksurface 0.11.5），iOS 18+
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <LindChain/ProcEnvironment/Surface/libkern/kxld/image.h>
#include <LindChain/ProcEnvironment/Surface/libkern/klog.h>

#define KEXT_IDENTITY "$(NXBundleIdentifier)"

static NSString *const kEKPositionKey = @"ExitKey.ButtonCenter";
static const CGFloat kEKButtonSize = 46.0;

#pragma mark - Nyxian 内部接口声明（仅用于编译，运行时都会检查）

@protocol EKWindowServer <NSObject>
+ (instancetype)shared;
@property (nonatomic, readonly) UIWindowScene *windowScene;
@property (nonatomic, weak, readonly) id fullScreenWindow;
@property (nonatomic, strong, readonly) NSMutableDictionary<NSNumber *, id> *windows;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *windowOrder;
- (void)windowWantsToClose:(id)window;
- (void)closeWindowWithIdentifier:(id_t)identifier withCompletion:(void (^)(BOOL))completion;
- (void)showAppSwitcherExternal;
- (void)windowsGetOutOfMyWay;
- (void)unfocusFocusedWindow;
@end

@protocol EKWindow <NSObject>
@property (nonatomic) id_t identifier;
@property (nonatomic) id session;
@end

@protocol EKWindowSession <NSObject>
@property (nonatomic) BOOL isFocused;
@property (nonatomic) BOOL isActive;
@property (nonatomic, strong) id process;
@end

@protocol EKProcess <NSObject>
@property (nonatomic, strong) NSString *bundleIdentifier;
- (void)terminate;
@end

@protocol EKProcessManager <NSObject>
+ (instancetype)shared;
- (void)closeIfRunningUsingBundleIdentifier:(NSString *)bundleIdentifier;
- (void)killAllRunningProcesses;
@end

#pragma mark - 工具函数

static id EKGet(id obj, NSString *key)
{
    if (obj == nil) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static id<EKWindowServer> EKWindowServer(void)
{
    Class cls = NSClassFromString(@"NXWindowServer");
    if (cls == Nil || ![cls respondsToSelector:@selector(shared)]) return nil;
    return [(Class<EKWindowServer>)cls shared];
}

static id<EKProcessManager> EKProcessManager(void)
{
    Class cls = NSClassFromString(@"PEProcessManager");
    if (cls == Nil || ![cls respondsToSelector:@selector(shared)]) return nil;
    return [(Class<EKProcessManager>)cls shared];
}

/* 找出当前在最前面的 App 窗口：先找有焦点的，再找全屏的，最后按窗口顺序 */
static id EKFrontWindow(id<EKWindowServer> ws)
{
    if (ws == nil) return nil;

    NSDictionary *windows = EKGet(ws, @"windows");
    if (![windows isKindOfClass:[NSDictionary class]] || windows.count == 0) return nil;

    for (id window in windows.allValues) {
        id session = EKGet(window, @"session");
        if ([EKGet(session, @"isFocused") boolValue]) return window;
    }

    id full = EKGet(ws, @"fullScreenWindow");
    if (full != nil) return full;

    NSArray *order = EKGet(ws, @"windowOrder");
    if ([order isKindOfClass:[NSArray class]]) {
        for (NSNumber *ident in order.reverseObjectEnumerator) {
            id window = windows[ident];
            if (window != nil) return window;
        }
    }
    return windows.allValues.firstObject;
}

static NSString *EKBundleIDForWindow(id window)
{
    id process = EKGet(EKGet(window, @"session"), @"process");
    id bid = EKGet(process, @"bundleIdentifier");
    return [bid isKindOfClass:[NSString class]] ? bid : nil;
}

/* 关闭一个窗口并确保它的进程被结束 */
static void EKCloseWindow(id<EKWindowServer> ws, id window)
{
    if (ws == nil || window == nil) return;
    NSString *bundleID = EKBundleIDForWindow(window);

    if ([ws respondsToSelector:@selector(windowWantsToClose:)]) {
        /* 与窗口自带关闭按钮走同一条路径 */
        [ws windowWantsToClose:window];
    } else if ([ws respondsToSelector:@selector(closeWindowWithIdentifier:withCompletion:)]) {
        id_t ident = (id_t)[EKGet(window, @"identifier") intValue];
        [ws closeWindowWithIdentifier:ident withCompletion:nil];
    }

    /* 窗口关闭动画结束后，如果进程还活着就把它结束掉 */
    if (bundleID != nil) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            id<EKProcessManager> pm = EKProcessManager();
            if ([pm respondsToSelector:@selector(closeIfRunningUsingBundleIdentifier:)]) {
                [pm closeIfRunningUsingBundleIdentifier:bundleID];
            }
        });
    }
}

#pragma mark - 只拦截按钮触摸的透明窗口

@interface EKOverlayWindow : UIWindow
@property (nonatomic, weak) UIView *passthroughExceptView;
@end

@implementation EKOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *hit = [super hitTest:point withEvent:event];
    UIView *button = self.passthroughExceptView;
    if (button != nil && hit != nil && [hit isDescendantOfView:button]) return hit;
    return nil; /* 其它位置的触摸全部穿透给下面的 App */
}
@end

@interface EKOverlayViewController : UIViewController
@end

@implementation EKOverlayViewController
- (void)loadView
{
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.backgroundColor = UIColor.clearColor;
}
- (BOOL)prefersStatusBarHidden { return NO; }
- (UIStatusBarStyle)preferredStatusBarStyle { return UIStatusBarStyleDefault; }
@end

#pragma mark - 控制器

@interface EKController : NSObject
@property (nonatomic, strong) EKOverlayWindow *window;
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) UIImpactFeedbackGenerator *haptic;
@property (nonatomic) NSInteger attempts;
+ (instancetype)shared;
- (void)installWhenReady;
- (void)uninstall;
@end

@implementation EKController

+ (instancetype)shared
{
    static EKController *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [EKController new]; });
    return shared;
}

/* 内核启动时窗口服务器可能还没建好，每 0.5 秒重试一次，最多 2 分钟 */
- (void)installWhenReady
{
    if (self.window != nil) return;

    id<EKWindowServer> ws = EKWindowServer();
    UIWindowScene *scene = EKGet(ws, @"windowScene");
    if (scene == nil) {
        if (++self.attempts > 240) return;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self installWhenReady];
        });
        return;
    }
    [self buildInScene:scene];
}

- (void)buildInScene:(UIWindowScene *)scene
{
    self.haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];

    EKOverlayWindow *window = [[EKOverlayWindow alloc] initWithWindowScene:scene];
    window.windowLevel = UIWindowLevelStatusBar + 50;
    window.backgroundColor = UIColor.clearColor;
    window.rootViewController = [EKOverlayViewController new];

    UIButton *button = [self makeButton];
    [window.rootViewController.view addSubview:button];
    window.passthroughExceptView = button;

    self.window = window;
    self.button = button;

    window.hidden = NO; /* 不 makeKey，避免抢走 App 的键盘焦点 */
    [self restorePosition];
}

- (UIButton *)makeButton
{
    UIButtonConfiguration *config = [UIButtonConfiguration filledButtonConfiguration];
    config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    config.baseBackgroundColor = [UIColor colorWithRed:0.90 green:0.22 blue:0.21 alpha:0.88];
    config.baseForegroundColor = UIColor.whiteColor;
    config.image = [UIImage systemImageNamed:@"xmark"
                           withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightBold]];

    __weak typeof(self) weakSelf = self;
    UIAction *primary = [UIAction actionWithTitle:@"退出当前 App" image:nil identifier:nil handler:^(__unused UIAction *a) {
        [weakSelf quitFrontApp];
    }];

    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:primary];
    button.frame = CGRectMake(0, 0, kEKButtonSize, kEKButtonSize);
    button.layer.shadowColor = UIColor.blackColor.CGColor;
    button.layer.shadowOpacity = 0.3;
    button.layer.shadowRadius = 6;
    button.layer.shadowOffset = CGSizeMake(0, 2);
    button.alpha = 0.85;
    button.accessibilityLabel = @"退出当前 App";

    /* 长按菜单（单击仍然是 primaryAction） */
    button.menu = [self makeMenu];
    button.showsMenuAsPrimaryAction = NO;

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [button addGestureRecognizer:pan];
    return button;
}

- (UIMenu *)makeMenu
{
    __weak typeof(self) weakSelf = self;
    UIAction *quit = [UIAction actionWithTitle:@"退出当前 App"
                                         image:[UIImage systemImageNamed:@"xmark.circle"]
                                    identifier:nil
                                       handler:^(__unused UIAction *a) { [weakSelf quitFrontApp]; }];
    UIAction *quitAll = [UIAction actionWithTitle:@"退出全部 App"
                                            image:[UIImage systemImageNamed:@"xmark.octagon"]
                                       identifier:nil
                                          handler:^(__unused UIAction *a) { [weakSelf quitAllApps]; }];
    quitAll.attributes = UIMenuElementAttributesDestructive;
    UIAction *switcher = [UIAction actionWithTitle:@"多任务"
                                             image:[UIImage systemImageNamed:@"square.stack"]
                                        identifier:nil
                                           handler:^(__unused UIAction *a) { [weakSelf showSwitcher]; }];
    UIAction *home = [UIAction actionWithTitle:@"回到桌面（不退出）"
                                         image:[UIImage systemImageNamed:@"house"]
                                    identifier:nil
                                       handler:^(__unused UIAction *a) { [weakSelf goHome]; }];
    return [UIMenu menuWithTitle:@"ExitKey" children:@[quit, quitAll, switcher, home]];
}

#pragma mark 动作

- (void)quitFrontApp
{
    id<EKWindowServer> ws = EKWindowServer();
    id window = EKFrontWindow(ws);
    if (window == nil) {
        [self toast:@"没有正在运行的 App"];
        return;
    }
    [self.haptic impactOccurred];
    EKCloseWindow(ws, window);
}

- (void)quitAllApps
{
    id<EKWindowServer> ws = EKWindowServer();
    NSDictionary *windows = EKGet(ws, @"windows");
    NSArray *all = [windows isKindOfClass:[NSDictionary class]] ? windows.allValues : @[];
    for (id window in all) EKCloseWindow(ws, window);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        id<EKProcessManager> pm = EKProcessManager();
        if ([pm respondsToSelector:@selector(killAllRunningProcesses)]) [pm killAllRunningProcesses];
    });

    [self.haptic impactOccurred];
    [self toast:all.count ? [NSString stringWithFormat:@"已退出 %lu 个 App", (unsigned long)all.count] : @"没有正在运行的 App"];
}

- (void)showSwitcher
{
    id<EKWindowServer> ws = EKWindowServer();
    if ([ws respondsToSelector:@selector(showAppSwitcherExternal)]) [ws showAppSwitcherExternal];
}

- (void)goHome
{
    id<EKWindowServer> ws = EKWindowServer();
    if ([ws respondsToSelector:@selector(windowsGetOutOfMyWay)]) [ws windowsGetOutOfMyWay];
    else if ([ws respondsToSelector:@selector(unfocusFocusedWindow)]) [ws unfocusFocusedWindow];
}

#pragma mark 拖动 + 吸边

- (void)handlePan:(UIPanGestureRecognizer *)pan
{
    UIView *button = pan.view;
    UIView *container = button.superview;
    if (container == nil) return;

    CGPoint t = [pan translationInView:container];
    button.center = CGPointMake(button.center.x + t.x, button.center.y + t.y);
    [pan setTranslation:CGPointZero inView:container];

    if (pan.state == UIGestureRecognizerStateEnded || pan.state == UIGestureRecognizerStateCancelled) {
        CGPoint target = [self snappedCenter:button.center];
        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.5 options:0 animations:^{
            button.center = target;
        } completion:nil];
        @try {
            [NSUserDefaults.standardUserDefaults setObject:NSStringFromCGPoint(target) forKey:kEKPositionKey];
        } @catch (__unused NSException *e) {}
    }
}

- (CGPoint)snappedCenter:(CGPoint)p
{
    UIView *container = self.button.superview;
    CGRect bounds = container.bounds;
    UIEdgeInsets safe = container.safeAreaInsets;
    CGFloat half = kEKButtonSize / 2.0, margin = 8.0;

    CGFloat minX = bounds.origin.x + safe.left + half + margin;
    CGFloat maxX = CGRectGetMaxX(bounds) - safe.right - half - margin;
    CGFloat minY = bounds.origin.y + safe.top + half + margin;
    CGFloat maxY = CGRectGetMaxY(bounds) - safe.bottom - half - margin;

    CGFloat x = (p.x < CGRectGetMidX(bounds)) ? minX : maxX;
    CGFloat y = MIN(MAX(p.y, minY), maxY);
    return CGPointMake(x, y);
}

- (void)restorePosition
{
    UIView *container = self.button.superview;
    [container layoutIfNeeded];

    CGPoint p = CGPointMake(CGRectGetMaxX(container.bounds), CGRectGetHeight(container.bounds) * 0.35);
    @try {
        NSString *saved = [NSUserDefaults.standardUserDefaults stringForKey:kEKPositionKey];
        if (saved.length) p = CGPointFromString(saved);
    } @catch (__unused NSException *e) {}

    self.button.center = [self snappedCenter:p];
}

#pragma mark 提示

- (void)toast:(NSString *)text
{
    UIView *container = self.window.rootViewController.view;
    if (container == nil) return;

    UILabel *label = [UILabel new];
    label.text = text;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    label.textAlignment = NSTextAlignmentCenter;
    label.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    label.layer.cornerRadius = 14;
    label.layer.masksToBounds = YES;
    [label sizeToFit];
    label.bounds = CGRectMake(0, 0, label.bounds.size.width + 28, 32);
    label.center = CGPointMake(CGRectGetMidX(container.bounds), container.safeAreaInsets.top + 40);
    label.userInteractionEnabled = NO;
    label.alpha = 0;
    [container addSubview:label];

    [UIView animateWithDuration:0.2 animations:^{ label.alpha = 1; } completion:^(__unused BOOL f) {
        [UIView animateWithDuration:0.3 delay:1.2 options:0 animations:^{ label.alpha = 0; } completion:^(__unused BOOL f2) {
            [label removeFromSuperview];
        }];
    }];
}

- (void)uninstall
{
    self.attempts = INT_MAX; /* 停止重试 */
    self.window.hidden = YES;
    self.window = nil;
    self.button = nil;
}

@end

#pragma mark - KEXT 入口

kern_return_t kinit(void)
{
    klog_log(KEXT_IDENTITY, "ExitKey loaded");
    /* init 是同步执行的，不能在这里等 UI，丢到主线程异步安装 */
    dispatch_async(dispatch_get_main_queue(), ^{
        [[EKController shared] installWhenReady];
    });
    return KERN_SUCCESS;
}

kern_return_t kdeinit(void)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [[EKController shared] uninstall];
    });
    return KERN_SUCCESS;
}

EXPORT_KSURFACE_MODULE({
    .magic = KSURFACE_KMOD_MAGIC,
    .abi_version = KSURFACE_KMOD_ABI_VERSION,
    .identifier = KEXT_IDENTITY,
    .version = KMOD_VERSION(1, 0, 0),
    .flags = KMOD_FLAG_PERSISTENT,
    .dependency_count = 2,
    .init = kinit,
    .deinit = kdeinit,
    .start = NULL,
    .stop = NULL,
    .dependencies = {
        {
            .identifier = "com.apple.iphoneos",
            .min_version = KMOD_VERSION(18, 0, 0),
            .max_version = KMOD_VERSION(99, 99, 99),
        },
        {
            .identifier = "ksurface",
            .min_version = KMOD_VERSION(0, 11, 5),
            .max_version = KMOD_VERSION(0, 11, 99),
        }
    },
})
