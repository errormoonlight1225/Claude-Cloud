#import "TRPanel.h"
#import "TRRecorder.h"

static UIWindowScene *TRActiveWindowScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        if (s.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)s;
        if (!fallback) fallback = (UIWindowScene *)s;
    }
    return fallback;
}

static UIWindow *TRMakeWindow(CGRect frame) {
    UIWindowScene *scene = TRActiveWindowScene();
    UIWindow *w = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:frame];
    w.frame = frame;
    return w;
}

#pragma mark - Panel window

static const CGFloat kBubble = 46;
static const CGFloat kPanelW = 168;

@interface TRPanelWindow ()
@property (nonatomic) BOOL expanded;
@property (nonatomic, copy) NSString *selectedName;
@property (nonatomic) NSUInteger repeatCount;   // 0 = ∞
@property (nonatomic) double speed;
@end

@implementation TRPanelWindow {
    UIView *_container;
    UIButton *_bubble;
    UIStackView *_stack;
    UILabel *_status;
    UIButton *_recordBtn, *_playBtn, *_pickBtn, *_repeatBtn, *_speedBtn;
    UIWindow *_alertWindow;
}

+ (instancetype)shared {
    static TRPanelWindow *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIWindowScene *scene = TRActiveWindowScene();
        s = scene ? [[TRPanelWindow alloc] initWithWindowScene:scene]
                  : [[TRPanelWindow alloc] initWithFrame:CGRectZero];
        [s commonInit];
    });
    return s;
}

- (void)commonInit {
    self.windowLevel = UIWindowLevelAlert + 100;
    self.backgroundColor = UIColor.clearColor;
    self.rootViewController = [UIViewController new];
    self.rootViewController.view.backgroundColor = UIColor.clearColor;
    self.repeatCount = 1;
    self.speed = 1.0;
    self.selectedName = [TRRecorder shared].savedRecordingNames.firstObject;

    _container = [[UIView alloc] init];
    _container.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.88];
    _container.layer.cornerRadius = 14;
    _container.layer.masksToBounds = YES;
    _container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.rootViewController.view addSubview:_container];

    _bubble = [UIButton buttonWithType:UIButtonTypeSystem];
    [_bubble setTitle:@"TR" forState:UIControlStateNormal];
    _bubble.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [_bubble setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [_bubble addTarget:self action:@selector(expand) forControlEvents:UIControlEventTouchUpInside];
    [_container addSubview:_bubble];

    _status = [UILabel new];
    _status.textColor = UIColor.whiteColor;
    _status.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    _status.textAlignment = NSTextAlignmentCenter;
    _status.numberOfLines = 2;

    _recordBtn = [self buttonWithAction:@selector(recordTapped)];
    _playBtn   = [self buttonWithAction:@selector(playTapped)];
    _pickBtn   = [self buttonWithAction:@selector(pickTapped)];
    _repeatBtn = [self buttonWithAction:@selector(repeatTapped)];
    _speedBtn  = [self buttonWithAction:@selector(speedTapped)];
    UIButton *collapse = [self buttonWithAction:@selector(collapse)];
    [collapse setTitle:@"收起" forState:UIControlStateNormal];

    _stack = [[UIStackView alloc] initWithArrangedSubviews:@[_status, _recordBtn, _playBtn, _pickBtn,
                                                            _repeatBtn, _speedBtn, collapse]];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 6;
    [_container addSubview:_stack];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    [self.rootViewController.view addGestureRecognizer:pan];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refresh)
                                                 name:TRStateDidChangeNotification object:nil];

    CGRect sb = UIScreen.mainScreen.bounds;
    self.frame = CGRectMake(sb.size.width - kBubble - 8, sb.size.height * 0.35, kBubble, kBubble);
    [self applyLayout];
    [self refresh];
}

- (UIButton *)buttonWithAction:(SEL)sel {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    b.layer.cornerRadius = 8;
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    b.titleLabel.adjustsFontSizeToFitWidth = YES;
    b.titleLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [b.heightAnchor constraintEqualToConstant:34].active = YES;
    [b addTarget:self action:sel forControlEvents:UIControlEventTouchUpInside];
    return b;
}

#pragma mark Layout

- (void)applyLayout {
    CGRect f = self.frame;
    CGSize size;
    if (self.expanded) {
        _bubble.hidden = YES;
        _stack.hidden = NO;
        CGSize fit = [_stack systemLayoutSizeFittingSize:CGSizeMake(kPanelW - 20, 0)
                           withHorizontalFittingPriority:UILayoutPriorityRequired
                                 verticalFittingPriority:UILayoutPriorityFittingSizeLevel];
        size = CGSizeMake(kPanelW, fit.height + 20);
        _stack.frame = CGRectMake(10, 10, kPanelW - 20, fit.height);
        _container.layer.cornerRadius = 14;
    } else {
        _bubble.hidden = NO;
        _stack.hidden = YES;
        size = CGSizeMake(kBubble, kBubble);
        _bubble.frame = CGRectMake(0, 0, kBubble, kBubble);
        _container.layer.cornerRadius = kBubble / 2;
    }
    // Keep the panel's right edge stable if it was docked on the right.
    CGRect screen = self.screen.bounds;
    BOOL rightSide = CGRectGetMidX(f) > screen.size.width / 2;
    f.origin.x = rightSide ? CGRectGetMaxX(f) - size.width : f.origin.x;
    f.size = size;
    self.frame = [self clamp:f];
    _container.frame = self.bounds;
    [self updateIgnoredRect];
}

- (CGRect)clamp:(CGRect)f {
    CGRect b = self.screen.bounds;
    f.origin.x = MAX(4, MIN(f.origin.x, b.size.width - f.size.width - 4));
    f.origin.y = MAX(30, MIN(f.origin.y, b.size.height - f.size.height - 20));
    return f;
}

/// Tells the recorder where we are (in the portrait/fixed space the digitizer uses).
- (void)updateIgnoredRect {
    UIScreen *scr = self.screen;
    id<UICoordinateSpace> fixed = scr.fixedCoordinateSpace;
    CGRect r = [self convertRect:CGRectInset(self.bounds, -6, -6) toCoordinateSpace:fixed];
    CGSize s = fixed.bounds.size;
    if (self.hidden || s.width <= 0 || s.height <= 0) {
        [TRRecorder shared].ignoredNormalizedRect = CGRectNull;
        return;
    }
    [TRRecorder shared].ignoredNormalizedRect =
        CGRectMake(r.origin.x / s.width, r.origin.y / s.height, r.size.width / s.width, r.size.height / s.height);
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint d = [g translationInView:self];
    CGRect f = self.frame;
    f.origin.x += d.x;
    f.origin.y += d.y;
    self.frame = [self clamp:f];
    [g setTranslation:CGPointZero inView:self];
    if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        [self updateIgnoredRect];
    }
}

- (void)expand { self.expanded = YES; [self refresh]; }
- (void)collapse { self.expanded = NO; [self refresh]; }

#pragma mark Visibility

- (void)show {
    self.hidden = NO;
    [self updateIgnoredRect];
}

- (void)toggleVisible {
    self.hidden = !self.hidden;
    [self updateIgnoredRect];
}

#pragma mark State

- (void)refresh {
    TRRecorder *r = [TRRecorder shared];
    BOOL recording = r.state == TRStateRecording;
    BOOL playing = r.state == TRStatePlaying;

    switch (r.state) {
        case TRStateIdle:
            _status.text = r.ready ? @"就绪" : @"HID 初始化失败";
            break;
        case TRStateRecording:
            _status.text = [NSString stringWithFormat:@"● 录制中\n%lu 帧", (unsigned long)r.progress];
            break;
        case TRStatePlaying:
            _status.text = r.playLoopTotal == 0
                ? [NSString stringWithFormat:@"▶ 播放中\n第 %lu 次 / ∞", (unsigned long)r.progress]
                : [NSString stringWithFormat:@"▶ 播放中\n第 %lu / %lu 次", (unsigned long)r.progress,
                                             (unsigned long)r.playLoopTotal];
            break;
    }

    [_recordBtn setTitle:recording ? @"■ 停止录制" : @"● 录制" forState:UIControlStateNormal];
    _recordBtn.backgroundColor = recording ? [UIColor colorWithRed:0.85 green:0.2 blue:0.2 alpha:0.9]
                                           : [UIColor colorWithWhite:1 alpha:0.14];
    _recordBtn.enabled = !playing;
    _recordBtn.alpha = playing ? 0.4 : 1;

    [_playBtn setTitle:playing ? @"■ 停止播放" : @"▶ 播放" forState:UIControlStateNormal];
    _playBtn.backgroundColor = playing ? [UIColor colorWithRed:0.2 green:0.55 blue:0.95 alpha:0.9]
                                       : [UIColor colorWithWhite:1 alpha:0.14];
    BOOL canPlay = playing || (!recording && self.selectedName.length > 0);
    _playBtn.enabled = canPlay;
    _playBtn.alpha = canPlay ? 1 : 0.4;

    [_pickBtn setTitle:[NSString stringWithFormat:@"📂 %@", self.selectedName ?: @"无录制"]
              forState:UIControlStateNormal];
    _pickBtn.enabled = r.state == TRStateIdle;

    [_repeatBtn setTitle:self.repeatCount == 0 ? @"🔁 次数: ∞"
                        : [NSString stringWithFormat:@"🔁 次数: %lu", (unsigned long)self.repeatCount]
                forState:UIControlStateNormal];
    [_speedBtn setTitle:[NSString stringWithFormat:@"⏩ 速度: %gx", self.speed] forState:UIControlStateNormal];

    // Bubble colour reflects state while collapsed.
    _container.backgroundColor = recording ? [UIColor colorWithRed:0.75 green:0.1 blue:0.1 alpha:0.9]
                               : playing   ? [UIColor colorWithRed:0.1 green:0.4 blue:0.85 alpha:0.9]
                                           : [UIColor colorWithWhite:0.08 alpha:0.88];
    [_bubble setTitle:recording ? @"●" : playing ? @"▶" : @"TR" forState:UIControlStateNormal];

    [self applyLayout];
}

#pragma mark Actions

- (void)recordTapped {
    TRRecorder *r = [TRRecorder shared];
    if (r.state == TRStateRecording) {
        [r stopRecordingWithCompletion:^(NSString *name) {
            if (name) self.selectedName = name;
            [self refresh];
        }];
    } else {
        [self updateIgnoredRect];
        [r startRecording];
    }
}

- (void)playTapped {
    TRRecorder *r = [TRRecorder shared];
    if (r.state == TRStatePlaying) {
        [r stopPlayback];
    } else if (self.selectedName) {
        if (![r playRecordingNamed:self.selectedName repeatCount:self.repeatCount speed:self.speed]) {
            [self presentMessage:@"无法播放该录制（文件损坏或为空）"];
        }
    }
}

- (void)repeatTapped {
    NSArray<NSNumber *> *opts = @[@1, @3, @5, @10, @50, @0];
    NSUInteger i = [opts indexOfObject:@(self.repeatCount)];
    self.repeatCount = opts[(i == NSNotFound ? 0 : i + 1) % opts.count].unsignedIntegerValue;
    [self refresh];
}

- (void)speedTapped {
    NSArray<NSNumber *> *opts = @[@0.5, @1, @1.5, @2, @4];
    NSUInteger i = [opts indexOfObject:@(self.speed)];
    self.speed = opts[(i == NSNotFound ? 0 : i + 1) % opts.count].doubleValue;
    [self refresh];
}

- (void)pickTapped {
    NSArray<NSString *> *names = [TRRecorder shared].savedRecordingNames;
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"选择录制"
        message:names.count ? [TRRecorder shared].storageDirectory : @"还没有录制"
        preferredStyle:UIAlertControllerStyleAlert];
    for (NSString *n in [names subarrayWithRange:NSMakeRange(0, MIN(names.count, 15))]) {
        NSString *title = [n isEqualToString:self.selectedName] ? [@"✓ " stringByAppendingString:n] : n;
        [ac addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(id a) {
            self.selectedName = n;
            [self refresh];
            [self dismissAlertWindow];
        }]];
    }
    if (self.selectedName) {
        NSString *sel = self.selectedName;
        [ac addAction:[UIAlertAction actionWithTitle:[@"删除 " stringByAppendingString:sel]
                                               style:UIAlertActionStyleDestructive handler:^(id a) {
            [[TRRecorder shared] deleteRecordingNamed:sel];
            self.selectedName = [TRRecorder shared].savedRecordingNames.firstObject;
            [self refresh];
            [self dismissAlertWindow];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:^(id a) {
        [self dismissAlertWindow];
    }]];
    [self presentAlert:ac];
}

#pragma mark Alerts (presented from a temporary full-screen window)

- (void)presentMessage:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"TapRecorder" message:msg
                                                         preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:^(id a) {
        [self dismissAlertWindow];
    }]];
    [self presentAlert:ac];
}

- (void)presentAlert:(UIAlertController *)ac {
    [self dismissAlertWindow];
    _alertWindow = TRMakeWindow(UIScreen.mainScreen.bounds);
    _alertWindow.windowLevel = self.windowLevel + 1;
    _alertWindow.backgroundColor = UIColor.clearColor;
    _alertWindow.rootViewController = [UIViewController new];
    _alertWindow.rootViewController.view.backgroundColor = UIColor.clearColor;
    _alertWindow.hidden = NO;
    [_alertWindow.rootViewController presentViewController:ac animated:YES completion:nil];
}

- (void)dismissAlertWindow {
    _alertWindow.hidden = YES;
    _alertWindow = nil;
}

@end
