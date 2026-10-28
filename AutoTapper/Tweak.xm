// AutoTapper - iOS 自动点击辅助插件
// Theos rootless 构建目标为 iOS 15+；私有 HID API 的可用性需在目标系统实测
//
// 原理:越狱环境下通过 IOKit HID 合成数字化仪(触摸)事件,
//       实现无需 target app 配合的系统级自动点击。

#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <Vision/Vision.h>

// ---------------------------------------------------------------------------
// IOKit HID 私有接口声明
// ---------------------------------------------------------------------------
typedef struct __IOHIDEvent *IOHIDEventRef;
#if defined(__LP64__)
typedef double IOHIDFloat;
#else
typedef float IOHIDFloat;
#endif
typedef uint32_t IOHIDDigitizerTransducerType;
typedef uint32_t IOOptionBits;
#define kIOHIDEventFieldDigitizerIsDisplayIntegrated 720921u

extern "C" {
IOHIDEventRef IOHIDEventCreateDigitizerEvent(
    CFAllocatorRef allocator, uint64_t timeStamp,
    IOHIDDigitizerTransducerType type, uint32_t index, uint32_t identity,
    uint32_t eventMask, uint32_t buttonMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat twist,
    Boolean range, Boolean touch, IOOptionBits options);

IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(
    CFAllocatorRef allocator, uint64_t timeStamp,
    uint32_t index, uint32_t identity, uint32_t eventMask,
    IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
    IOHIDFloat tipPressure, IOHIDFloat twist,
    Boolean range, Boolean touch, IOOptionBits options);

void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, IOOptionBits options);
void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, int64_t value);
}

// BackBoardServices 事件分发接口
typedef struct __BKSHIDEventDeliveryManager *BKSHIDEventDeliveryManagerRef;

// 触摸事件掩码
#define kIOHIDDigitizerEventRange   0x00000001
#define kIOHIDDigitizerEventTouch   0x00000002
#define kIOHIDDigitizerEventPosition 0x00000004

// ---------------------------------------------------------------------------
// 全局状态
// ---------------------------------------------------------------------------
static CGPoint gTapPoint = CGPointMake(200, 400);
static NSTimeInterval gInterval = 0.5;      // 两次点击间隔(秒)
static BOOL gRunning = NO;
static NSTimer *gTimer = nil;
static NSTimer *gDamaiSafetyTimer = nil;
static BOOL gDamaiMode = NO;
static NSInteger gPlanIndex = 0;

static NSString * const kATTapXKey = @"AutoTapper.tapX";
static NSString * const kATTapYKey = @"AutoTapper.tapY";
static NSString * const kATIntervalKey = @"AutoTapper.interval";
static NSString * const kATDamaiModeKey = @"AutoTapper.damaiMode";
static NSString * const kATPlanIndexKey = @"AutoTapper.planIndex";
static NSString * const kATPlanStepsKey = @"AutoTapper.planSteps";

static NSArray<NSString *> *ATDefaultAssistSteps(void) {
    return @[
        @"打开目标活动页面",
        @"人工选择场次与票档",
        @"核对数量、价格和购票规则",
        @"人工核对订单信息",
        @"由本人完成官方页面上的后续操作"
    ];
}

static NSArray<NSString *> *ATAssistSteps(void) {
    // User-editable saved checklist only; it is never interpreted as executable actions.
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kATPlanStepsKey];
    if (saved.count == ATDefaultAssistSteps().count) {
        BOOL valid = YES;
        for (id item in saved) {
            if (![item isKindOfClass:[NSString class]] ||
                [((NSString *)item) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0) {
                valid = NO;
                break;
            }
        }
        if (valid) return (NSArray<NSString *> *)saved;
    }
    return ATDefaultAssistSteps();
}

static void ATLoadSavedSettings(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    if ([defaults objectForKey:kATTapXKey] && [defaults objectForKey:kATTapYKey]) {
        gTapPoint = CGPointMake([defaults doubleForKey:kATTapXKey],
                                [defaults doubleForKey:kATTapYKey]);
    }
    if ([defaults objectForKey:kATIntervalKey]) {
        double storedInterval = [defaults doubleForKey:kATIntervalKey];
        if (storedInterval >= 0.1 && storedInterval <= 3.0) gInterval = storedInterval;
    }
    if ([defaults objectForKey:kATDamaiModeKey]) {
        gDamaiMode = [defaults boolForKey:kATDamaiModeKey];
    }
    NSInteger savedIndex = [defaults integerForKey:kATPlanIndexKey];
    NSInteger count = (NSInteger)ATAssistSteps().count;
    gPlanIndex = MAX(0, MIN(savedIndex, count));
}

static void ATSaveSavedSettings(void) {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setDouble:gTapPoint.x forKey:kATTapXKey];
    [defaults setDouble:gTapPoint.y forKey:kATTapYKey];
    [defaults setDouble:gInterval forKey:kATIntervalKey];
    [defaults setBool:gDamaiMode forKey:kATDamaiModeKey];
    [defaults setInteger:gPlanIndex forKey:kATPlanIndexKey];
}

// ---------------------------------------------------------------------------
// 事件合成与分发
// ---------------------------------------------------------------------------
static uint64_t currentMachTime(void) {
    // IOHIDEvent constructors expect raw mach_absolute_time() ticks, not nanoseconds.
    return mach_absolute_time();
}

// 通过 UIApplication 私有接口将合成事件注入事件队列
static void sendDigitizerEvent(CGPoint pt, BOOL down) {
    // _enqueueHIDEvent: expects display-space points for the digitizer coordinates.
    IOHIDFloat nx = (IOHIDFloat)pt.x;
    IOHIDFloat ny = (IOHIDFloat)pt.y;

    uint32_t mask = kIOHIDDigitizerEventTouch | kIOHIDDigitizerEventPosition;
    if (down) mask |= kIOHIDDigitizerEventRange;

    IOHIDEventRef parent = IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, currentMachTime(),
        3 /* kIOHIDDigitizerTransducerTypeHand */, 0, 0,
        mask, 0, nx, ny, 0, down ? 1.0 : 0.0, 0,
        down, down, 0);

    IOHIDEventRef finger = IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, currentMachTime(),
        1, 2, mask, nx, ny, 0, down ? 1.0 : 0.0, 0,
        down, down, 0);

    if (parent && finger) {
        IOHIDEventSetIntegerValue(parent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        IOHIDEventAppendEvent(parent, finger, 0);
        // 经由 UIApplication 的私有 _enqueueHIDEvent: 注入
        UIApplication *app = [UIApplication sharedApplication];
        SEL sel = NSSelectorFromString(@"_enqueueHIDEvent:");
        if ([app respondsToSelector:sel]) {
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [app performSelector:sel withObject:(__bridge id)parent];
            #pragma clang diagnostic pop
        }
    }
    if (finger) CFRelease(finger);
    if (parent) CFRelease(parent);
}

static void performOneTap(void) {
    sendDigitizerEvent(gTapPoint, YES);   // touch down
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sendDigitizerEvent(gTapPoint, NO); // touch up
    });
}

// ---------------------------------------------------------------------------
// 悬浮控制面板
// ---------------------------------------------------------------------------
@interface ATControlPanel : UIView
@property (nonatomic, strong) UIButton *toggleBtn;
@property (nonatomic, strong) UILabel *infoLabel;
@property (nonatomic, strong) UIButton *modeBtn;
@property (nonatomic, strong) UIButton *ocrBtn;
@property (nonatomic, strong) UIButton *planBtn;
@property (nonatomic, assign) CGPoint lastCenter;
@end

@implementation ATControlPanel

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
        self.layer.cornerRadius = 14;
        self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;

        _infoLabel = [[UILabel alloc] initWithFrame:CGRectMake(10, 8, frame.size.width - 20, 34)];
        _infoLabel.textColor = [UIColor whiteColor];
        _infoLabel.font = [UIFont systemFontOfSize:11];
        _infoLabel.numberOfLines = 2;
        _infoLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_infoLabel];

        _toggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _toggleBtn.frame = CGRectMake(10, 46, frame.size.width - 20, 36);
        _toggleBtn.backgroundColor = [UIColor systemGreenColor];
        _toggleBtn.layer.cornerRadius = 8;
        [_toggleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _toggleBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
        [_toggleBtn addTarget:self action:@selector(toggleTap) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_toggleBtn];

        UIButton *pickBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        pickBtn.frame = CGRectMake(10, 88, (frame.size.width - 26) / 2, 30);
        pickBtn.backgroundColor = [UIColor systemBlueColor];
        pickBtn.layer.cornerRadius = 7;
        [pickBtn setTitle:@"选坐标" forState:UIControlStateNormal];
        [pickBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        pickBtn.titleLabel.font = [UIFont systemFontOfSize:13];
        [pickBtn addTarget:self action:@selector(pickPoint) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:pickBtn];

        UIButton *spdBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        spdBtn.frame = CGRectMake(16 + (frame.size.width - 26) / 2, 88, (frame.size.width - 26) / 2, 30);
        spdBtn.backgroundColor = [UIColor systemOrangeColor];
        spdBtn.layer.cornerRadius = 7;
        [spdBtn setTitle:@"间隔" forState:UIControlStateNormal];
        [spdBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        spdBtn.titleLabel.font = [UIFont systemFontOfSize:13];
        [spdBtn addTarget:self action:@selector(changeInterval) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:spdBtn];

        UIButton *singleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        singleBtn.frame = CGRectMake(10, 122, (frame.size.width - 26) / 2, 28);
        singleBtn.backgroundColor = [UIColor colorWithWhite:0.28 alpha:1.0];
        singleBtn.layer.cornerRadius = 7;
        [singleBtn setTitle:@"单点一次" forState:UIControlStateNormal];
        [singleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        singleBtn.titleLabel.font = [UIFont systemFontOfSize:12];
        [singleBtn addTarget:self action:@selector(singleTap) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:singleBtn];

        _modeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _modeBtn.frame = CGRectMake(16 + (frame.size.width - 26) / 2, 122, (frame.size.width - 26) / 2, 28);
        _modeBtn.backgroundColor = [UIColor systemPurpleColor];
        _modeBtn.layer.cornerRadius = 7;
        [_modeBtn setTitle:@"大麦模式:关" forState:UIControlStateNormal];
        [_modeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _modeBtn.titleLabel.font = [UIFont systemFontOfSize:12];
        [_modeBtn addTarget:self action:@selector(toggleDamaiMode) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_modeBtn];

        _ocrBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _ocrBtn.frame = CGRectMake(10, 156, frame.size.width - 20, 28);
        _ocrBtn.backgroundColor = [UIColor colorWithRed:0.12 green:0.48 blue:0.38 alpha:1.0];
        _ocrBtn.layer.cornerRadius = 7;
        [_ocrBtn setTitle:@"识别文字并定位" forState:UIControlStateNormal];
        [_ocrBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _ocrBtn.titleLabel.font = [UIFont systemFontOfSize:12];
        [_ocrBtn addTarget:self action:@selector(recognizeTargetText) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_ocrBtn];

        _planBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _planBtn.frame = CGRectMake(10, 188, frame.size.width - 20, 26);
        _planBtn.backgroundColor = [UIColor colorWithWhite:0.24 alpha:1.0];
        _planBtn.layer.cornerRadius = 7;
        [_planBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        _planBtn.titleLabel.font = [UIFont systemFontOfSize:12];
        [_planBtn addTarget:self action:@selector(configurePlan) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_planBtn];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(onPan:)];
        [self addGestureRecognizer:pan];

        [self refreshInfo];
    }
    return self;
}

- (void)refreshInfo {
    NSString *mode = gDamaiMode ? @"大麦辅助" : @"通用模式";
    NSString *safety = gDamaiMode ? @" · 10秒自动停" : @"";
    _infoLabel.text = [NSString stringWithFormat:@"%@ (%.0f,%.0f)\n间隔 %.2fs%@",
                       mode, gTapPoint.x, gTapPoint.y, gInterval, safety];
    NSArray<NSString *> *steps = ATAssistSteps();
    NSString *planStatus = (gPlanIndex >= (NSInteger)steps.count)
        ? @"步骤计划:完成" : [NSString stringWithFormat:@"步骤计划 %ld/%lu",
                              (long)(gPlanIndex + 1), (unsigned long)steps.count];
    [_planBtn setTitle:planStatus forState:UIControlStateNormal];
    [_modeBtn setTitle:(gDamaiMode ? @"大麦模式:开" : @"大麦模式:关") forState:UIControlStateNormal];
    _modeBtn.backgroundColor = gDamaiMode ? [UIColor systemOrangeColor] : [UIColor systemPurpleColor];
}

- (void)stopTap {
    gRunning = NO;
    [gTimer invalidate];
    gTimer = nil;
    [gDamaiSafetyTimer invalidate];
    gDamaiSafetyTimer = nil;
    [_toggleBtn setTitle:@"开始" forState:UIControlStateNormal];
    _toggleBtn.backgroundColor = [UIColor systemGreenColor];
}

- (void)toggleTap {
    if (gRunning) {
        [self stopTap];
        return;
    }
    gRunning = YES;
    [_toggleBtn setTitle:@"停止" forState:UIControlStateNormal];
    _toggleBtn.backgroundColor = [UIColor systemRedColor];
    gTimer = [NSTimer scheduledTimerWithTimeInterval:gInterval
                                              repeats:YES
                                                block:^(NSTimer *t){ performOneTap(); }];
    if (gDamaiMode) {
        __weak typeof(self) weakSelf = self;
        gDamaiSafetyTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                              repeats:NO
                                                                block:^(NSTimer *t){ [weakSelf stopTap]; }];
    }
}

- (void)singleTap {
    if (!gRunning) performOneTap();
}

- (void)toggleDamaiMode {
    if (gRunning) [self stopTap];
    gDamaiMode = !gDamaiMode;
    gInterval = gDamaiMode ? 1.0 : 0.5;
    ATSaveSavedSettings();
    [self refreshInfo];
}

- (void)configurePlan {
    NSArray<NSString *> *steps = ATAssistSteps();
    BOOL complete = gPlanIndex >= (NSInteger)steps.count;
    NSString *message = complete
        ? @"所有辅助检查点均已标记完成。计划只记录人工进度，不会自动点击、提交订单或付款。"
        : [NSString stringWithFormat:@"当前步骤 %ld/%lu：\n%@\n\n完成后由你手动标记。计划只提供提示，不会自动跳转或执行购票操作。",
            (long)(gPlanIndex + 1), (unsigned long)steps.count, steps[(NSUInteger)gPlanIndex]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"大麦辅助计划"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    if (!complete) {
        [alert addAction:[UIAlertAction actionWithTitle:@"标记当前步骤完成" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            gPlanIndex = MIN(gPlanIndex + 1, (NSInteger)ATAssistSteps().count);
            ATSaveSavedSettings();
            [weakSelf refreshInfo];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"编辑步骤" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf editPlan]; });
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"重置计划" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            gPlanIndex = 0;
            ATSaveSavedSettings();
            [weakSelf refreshInfo];
        }]];
    } else {
        [alert addAction:[UIAlertAction actionWithTitle:@"重新开始计划" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            gPlanIndex = 0;
            ATSaveSavedSettings();
            [weakSelf refreshInfo];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"编辑步骤" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf editPlan]; });
        }]];
    }
    UIViewController *presenter = self.window.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:alert animated:YES completion:nil];
}

- (void)editPlan {
    NSArray<NSString *> *steps = ATAssistSteps();
    UIAlertController *editor = [UIAlertController alertControllerWithTitle:@"编辑辅助计划"
        message:@"每项只作为人工步骤提醒，不会执行自动点击或订单操作。" preferredStyle:UIAlertControllerStyleAlert];
    for (NSUInteger i = 0; i < steps.count; i++) {
        [editor addTextFieldWithConfigurationHandler:^(UITextField *field) {
            field.text = steps[i];
            field.placeholder = [NSString stringWithFormat:@"步骤 %lu", (unsigned long)(i + 1)];
            field.clearButtonMode = UITextFieldViewModeWhileEditing;
        }];
    }
    [editor addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [editor addAction:[UIAlertAction actionWithTitle:@"保存步骤" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSMutableArray<NSString *> *updated = [NSMutableArray arrayWithCapacity:steps.count];
        NSArray<NSString *> *defaults = ATDefaultAssistSteps();
        [editor.textFields enumerateObjectsUsingBlock:^(UITextField *field, NSUInteger idx, BOOL *stop) {
            NSString *value = [field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [updated addObject:(value.length > 0 ? value : defaults[idx])];
        }];
        [[NSUserDefaults standardUserDefaults] setObject:updated forKey:kATPlanStepsKey];
        gPlanIndex = 0; // Editing a plan starts its checklist from the beginning.
        ATSaveSavedSettings();
        [weakSelf refreshInfo];
    }]];
    UIViewController *presenter = self.window.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:editor animated:YES completion:nil];
}

- (void)recognizeTargetText {
    if (gRunning) [self stopTap];
    UIWindow *win = self.window;
    if (!win) return;

    UIAlertController *ask = [UIAlertController alertControllerWithTitle:@"文字识别定位"
        message:@"输入页面上可见的目标文字（例如“选择场次”）。识别后只定位坐标，不会自动点击；请确认位置后手动点“单点一次”。"
        preferredStyle:UIAlertControllerStyleAlert];
    [ask addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"输入要查找的文字";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    __weak typeof(self) weakSelf = self;
    [ask addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ask addAction:[UIAlertAction actionWithTitle:@"识别" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *target = ask.textFields.firstObject.text ?: @"";
        if (target.length == 0) return;
        UIWindow *currentWindow = weakSelf.window;
        if (!currentWindow) return;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:currentWindow.bounds];
        UIImage *snapshot = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [currentWindow drawViewHierarchyInRect:currentWindow.bounds afterScreenUpdates:NO];
        }];
        if (!snapshot.CGImage) return;

        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] init];
        request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
        request.usesLanguageCorrection = YES;
        request.recognitionLanguages = @[@"zh-Hans", @"en-US"];
        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:snapshot.CGImage options:@{}];
        NSError *error = nil;
        if (![handler performRequests:@[request] error:&error]) {
            UIAlertController *failed = [UIAlertController alertControllerWithTitle:@"识别失败"
                message:error.localizedDescription ?: @"请稍后重试。" preferredStyle:UIAlertControllerStyleAlert];
            [failed addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [currentWindow.rootViewController presentViewController:failed animated:YES completion:nil];
            return;
        }
        NSString *needle = [target stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        VNRecognizedTextObservation *match = nil;
        for (VNRecognizedTextObservation *observation in request.results) {
            NSString *candidate = [observation topCandidates:1].firstObject.string;
            if (candidate.length && [candidate localizedCaseInsensitiveContainsString:needle]) {
                match = observation;
                break;
            }
        }
        if (!match) {
            UIAlertController *notFound = [UIAlertController alertControllerWithTitle:@"未找到文字"
                message:@"请确认目标文字当前显示在屏幕上，尝试输入更短的关键词。" preferredStyle:UIAlertControllerStyleAlert];
            [notFound addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [currentWindow.rootViewController presentViewController:notFound animated:YES completion:nil];
            return;
        }
        CGRect box = match.boundingBox;
        CGFloat px = CGRectGetMidX(box) * currentWindow.bounds.size.width;
        CGFloat py = (1.0 - CGRectGetMidY(box)) * currentWindow.bounds.size.height;
        gTapPoint = CGPointMake(px, py);
        ATSaveSavedSettings();
        [weakSelf refreshInfo];
        UIAlertController *found = [UIAlertController alertControllerWithTitle:@"已定位目标文字"
            message:[NSString stringWithFormat:@"“%@”\n坐标：(%.0f, %.0f)\n不会自动点击，请检查是否定位正确。", needle, px, py]
            preferredStyle:UIAlertControllerStyleAlert];
        [found addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [found addAction:[UIAlertAction actionWithTitle:@"确认单击一次" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            // One user-confirmed tap only; never loop or auto-submit a purchase.
            performOneTap();
        }]];
        [currentWindow.rootViewController presentViewController:found animated:YES completion:nil];
    }]];
    UIViewController *presenter = win.rootViewController;
    while (presenter.presentedViewController) presenter = presenter.presentedViewController;
    [presenter presentViewController:ask animated:YES completion:nil];
}

- (void)pickPoint {
    // 进入选点模式:全屏覆盖层,点哪记哪
    UIWindow *win = self.window;
    UIView *overlay = [[UIView alloc] initWithFrame:win.bounds];
    overlay.backgroundColor = [UIColor colorWithWhite:0 alpha:0.2];
    overlay.tag = 9911;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
        initWithTarget:self action:@selector(onPickTap:)];
    [overlay addGestureRecognizer:tap];
    [win addSubview:overlay];
}

- (void)onPickTap:(UITapGestureRecognizer *)g {
    gTapPoint = [g locationInView:g.view.window];
    [[g.view.window viewWithTag:9911] removeFromSuperview];
    ATSaveSavedSettings();
    [self refreshInfo];
}

- (void)changeInterval {
    // 在 0.1 / 0.3 / 0.5 / 1.0 / 2.0 之间循环
    NSArray *steps = gDamaiMode ? @[@1.0, @1.5, @2.0, @3.0] : @[@0.1, @0.3, @0.5, @1.0, @2.0];
    NSUInteger idx = [steps indexOfObject:@(gInterval)];
    idx = (idx == NSNotFound) ? 0 : (idx + 1) % steps.count;
    gInterval = [steps[idx] doubleValue];
    ATSaveSavedSettings();
    [self refreshInfo];
    // Restart only the repeating click timer. Keep the existing Damai safety timer alive,
    // so changing the interval cannot extend the current 10-second run window.
    if (gRunning) {
        [gTimer invalidate];
        gTimer = [NSTimer scheduledTimerWithTimeInterval:gInterval
                                                   repeats:YES
                                                     block:^(NSTimer *t){ performOneTap(); }];
    }
}

- (void)onPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    if (g.state == UIGestureRecognizerStateBegan) _lastCenter = self.center;
    self.center = CGPointMake(_lastCenter.x + t.x, _lastCenter.y + t.y);
}

@end

// ---------------------------------------------------------------------------
// 注入:在每个 app 启动后挂一个悬浮面板
// ---------------------------------------------------------------------------
static ATControlPanel *gPanel = nil;

static void showPanel(void) {
    if (gPanel && gPanel.window) return;
    ATLoadSavedSettings();
    gPanel = nil;
    UIWindow *key = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow) { key = w; break; }
            }
        }
    }
    if (!key) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindow *candidate = ((UIWindowScene *)scene).windows.firstObject;
            if (candidate) { key = candidate; break; }
        }
    }
    if (!key) return;

    gPanel = [[ATControlPanel alloc] initWithFrame:CGRectMake(20, 120, 170, 224)];
    [key addSubview:gPanel];
}

%hook UIApplication
- (void)_runWithMainScene:(id)scene transitionContext:(id)ctx completion:(id)completion {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ showPanel(); });
}
%end

%ctor {
    // 仅在有 UI 的前台进程中注入
    @autoreleasepool {
        NSString *bundleID = [NSBundle mainBundle].bundleIdentifier;
        if (bundleID.length == 0) return;
        // 跳过明显的系统守护进程
        if ([bundleID hasPrefix:@"com.apple.springboard"]) return;
    }
    // Activate the Logos UIApplication hook after process checks.
    %init;
}
