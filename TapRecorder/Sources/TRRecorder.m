#import "TRRecorder.h"
#import "TRHID.h"

NSString *const TRStateDidChangeNotification = @"TRStateDidChangeNotification";

static NSString *const kStorageDir = @"/var/mobile/Library/TapRecorder";
static const uint64_t kFallbackSenderID = 0x000000010000027FULL;

// JSON keys for a touch
#define K_ID  @"i"
#define K_X   @"x"
#define K_Y   @"y"
#define K_MASK @"m"
#define K_RANGE @"r"
#define K_TOUCH @"t"
#define K_PRESS @"p"
#define K_MAJ @"ma"
#define K_MIN @"mi"

static mach_timebase_info_data_t sTimebase;

static double TRTicksToSeconds(uint64_t ticks) {
    return (double)ticks * sTimebase.numer / sTimebase.denom / 1e9;
}
static uint64_t TRSecondsToTicks(double s) {
    return (uint64_t)(s * 1e9 * sTimebase.denom / sTimebase.numer);
}

static void TRHIDCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event);

@interface TRRecorder ()
@property (nonatomic, readwrite) TRState state;
@property (nonatomic, readwrite) NSUInteger progress;
@property (nonatomic, readwrite) NSUInteger playLoopTotal;
@property (atomic) BOOL cancelPlayback;
@property (atomic) BOOL capturing;
- (void)handleDigitizerEvent:(IOHIDEventRef)event;
@end

@implementation TRRecorder {
    IOHIDEventSystemClientRef _monitorClient;   // only touched on the HID thread
    IOHIDEventSystemClientRef _dispatchClient;  // only touched on the playback thread
    NSThread *_hidThread;
    CFRunLoopRef _hidRunLoop;

    // Recording state (HID thread only)
    NSMutableArray<NSDictionary *> *_frames;
    uint64_t _firstTimestamp;
    uint64_t _senderID;
    NSMutableSet<NSNumber *> *_activeIDs;
    NSMutableSet<NSNumber *> *_ignoredIDs;
    NSMutableDictionary<NSNumber *, NSDictionary *> *_lastTouchByID;
}

+ (instancetype)shared {
    static TRRecorder *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [TRRecorder new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        mach_timebase_info(&sTimebase);
        _activeIDs = [NSMutableSet set];
        _ignoredIDs = [NSMutableSet set];
        _lastTouchByID = [NSMutableDictionary dictionary];
        [[NSFileManager defaultManager] createDirectoryAtPath:kStorageDir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    }
    return self;
}

- (BOOL)setup {
    if (_ready) return YES;
    // Only resolve symbols here. No HID client is created until the user
    // actually presses record / play, so SpringBoard launch is not affected.
    if (!TRHIDLoad()) return NO;

    // Dedicated thread + run loop that receives HID events while recording,
    // so the SpringBoard main thread is never involved.
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    _hidThread = [[NSThread alloc] initWithBlock:^{
        self->_hidRunLoop = (CFRunLoopRef)CFRetain(CFRunLoopGetCurrent());
        NSRunLoop *rl = [NSRunLoop currentRunLoop];
        [rl addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];  // keep alive
        dispatch_semaphore_signal(sem);
        while (YES) {
            @autoreleasepool { [rl runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]]; }
        }
    }];
    _hidThread.name = @"TapRecorder.hid";
    _hidThread.qualityOfService = NSQualityOfServiceUserInteractive;
    [_hidThread start];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) return NO;

    _ready = YES;
    return YES;
}

- (void)performOnHIDThread:(dispatch_block_t)block {
    CFRunLoopPerformBlock(_hidRunLoop, kCFRunLoopDefaultMode, block);
    CFRunLoopWakeUp(_hidRunLoop);
}

- (void)notifyChanged {
    void (^post)(void) = ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:TRStateDidChangeNotification object:self];
    };
    if ([NSThread isMainThread]) post(); else dispatch_async(dispatch_get_main_queue(), post);
}

#pragma mark - Recording

- (void)startRecording {
    if (!_ready || self.state != TRStateIdle) return;
    self.progress = 0;
    self.state = TRStateRecording;
    [self notifyChanged];

    [self performOnHIDThread:^{
        self->_frames = [NSMutableArray array];
        self->_firstTimestamp = 0;
        self->_senderID = 0;
        [self->_activeIDs removeAllObjects];
        [self->_ignoredIDs removeAllObjects];
        [self->_lastTouchByID removeAllObjects];

        IOHIDEventSystemClientRef c = NULL;
        // Prefer a "monitor" client (type 1) so we see every HID event, fall back to an admin client.
        if (TRHID.ClientCreateWithType) c = TRHID.ClientCreateWithType(kCFAllocatorDefault, 1, NULL);
        if (!c) c = TRHID.ClientCreate(kCFAllocatorDefault);
        if (!c) {
            NSLog(@"[TapRecorder] failed to create HID monitor client");
            dispatch_async(dispatch_get_main_queue(), ^{
                self.state = TRStateIdle;
                [self notifyChanged];
            });
            return;
        }
        TRHID.ClientRegisterCallback(c, TRHIDCallback, (__bridge void *)self, NULL);
        TRHID.ClientSchedule(c, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
        self->_monitorClient = c;
        self.capturing = YES;
    }];
}

static void TRHIDCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event) {
    TRRecorder *rec = (__bridge TRRecorder *)target;
    if (!rec.capturing) return;
    if (TRHID.GetType(event) != kTRHIDEventTypeDigitizer) return;
    [rec handleDigitizerEvent:event];
}

- (void)handleDigitizerEvent:(IOHIDEventRef)event {
    // Only the built-in touch screen.
    if (TRHID.GetInteger(event, kTRDigIsDisplayIntegrated) == 0) return;

    NSMutableArray *fingers = [NSMutableArray array];
    CFArrayRef children = TRHID.GetChildren(event);
    CFIndex n = children ? CFArrayGetCount(children) : 0;
    if (n > 0) {
        for (CFIndex i = 0; i < n; i++) {
            IOHIDEventRef child = (IOHIDEventRef)CFArrayGetValueAtIndex(children, i);
            if (TRHID.GetType(child) != kTRHIDEventTypeDigitizer) continue;
            if (TRHID.GetInteger(child, kTRDigType) != kTRTransducerFinger) continue;
            [fingers addObject:[NSValue valueWithPointer:child]];
        }
    } else if (TRHID.GetInteger(event, kTRDigType) == kTRTransducerFinger) {
        [fingers addObject:[NSValue valueWithPointer:event]];
    }
    if (fingers.count == 0) return;

    CGRect ignoreRect = self.ignoredNormalizedRect;
    NSMutableArray *touches = [NSMutableArray array];

    for (NSValue *v in fingers) {
        IOHIDEventRef f = (IOHIDEventRef)v.pointerValue;
        NSNumber *idn = @(TRHID.GetInteger(f, kTRDigIdentity));
        double x = TRHID.GetFloat(f, kTRDigX);
        double y = TRHID.GetFloat(f, kTRDigY);
        BOOL touch = TRHID.GetInteger(f, kTRDigTouch) != 0;
        BOOL range = TRHID.GetInteger(f, kTRDigRange) != 0;

        BOOL ignored = [_ignoredIDs containsObject:idn];
        BOOL active = [_activeIDs containsObject:idn];

        if (!ignored && !active && touch) {
            // New finger down: drop it if it lands on our own panel.
            if (CGRectContainsPoint(ignoreRect, CGPointMake(x, y))) {
                [_ignoredIDs addObject:idn];
                ignored = YES;
            } else {
                [_activeIDs addObject:idn];
                active = YES;
            }
        }
        if (!touch) {
            [_ignoredIDs removeObject:idn];
            [_activeIDs removeObject:idn];
        }
        // Skip panel touches and lift events for fingers we never saw go down
        // (e.g. a finger that was already on screen when recording began).
        if (ignored || !active) continue;

        NSDictionary *t = @{
            K_ID: idn,
            K_X: @(x), K_Y: @(y),
            K_MASK: @(TRHID.GetInteger(f, kTRDigEventMask)),
            K_RANGE: @(range), K_TOUCH: @(touch),
            K_PRESS: @(TRHID.GetFloat(f, kTRDigPressure)),
            K_MAJ: @(TRHID.GetFloat(f, kTRDigMajorRadius)),
            K_MIN: @(TRHID.GetFloat(f, kTRDigMinorRadius)),
        };
        [touches addObject:t];
        if (touch) _lastTouchByID[idn] = t; else [_lastTouchByID removeObjectForKey:idn];
    }
    if (touches.count == 0) return;

    uint64_t ts = TRHID.GetTimeStamp(event);
    if (_firstTimestamp == 0) {
        _firstTimestamp = ts;
        _senderID = TRHID.GetSenderID(event);
    }
    double t = ts >= _firstTimestamp ? TRTicksToSeconds(ts - _firstTimestamp) : 0;
    [_frames addObject:@{ @"t": @(t), @"touches": touches }];
    NSUInteger count = _frames.count;
    if (count % 6 == 1) {  // throttle UI updates
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.state != TRStateRecording) return;
            self.progress = count;
            [self notifyChanged];
        });
    }
}

- (void)stopRecordingWithCompletion:(void (^)(NSString *))completion {
    if (self.state != TRStateRecording) { if (completion) completion(nil); return; }
    self.capturing = NO;

    [self performOnHIDThread:^{
        if (self->_monitorClient) {
            if (TRHID.ClientUnschedule)
                TRHID.ClientUnschedule(self->_monitorClient, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
            CFRelease(self->_monitorClient);
            self->_monitorClient = NULL;
        }

        // Make sure every finger is lifted at the end.
        if (self->_lastTouchByID.count > 0 && self->_frames.count > 0) {
            double lastT = [self->_frames.lastObject[@"t"] doubleValue] + 0.016;
            NSMutableArray *lifts = [NSMutableArray array];
            for (NSDictionary *t in self->_lastTouchByID.allValues) {
                NSMutableDictionary *m = [t mutableCopy];
                m[K_TOUCH] = @NO; m[K_RANGE] = @NO;
                m[K_MASK] = @(kTRDigMaskRange | kTRDigMaskTouch);
                [lifts addObject:m];
            }
            [self->_frames addObject:@{ @"t": @(lastT), @"touches": lifts }];
        }
        [self->_lastTouchByID removeAllObjects];

        NSString *name = nil;
        if (self->_frames.count > 0) {
            NSDateFormatter *df = [NSDateFormatter new];
            df.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
            name = [df stringFromDate:[NSDate date]];
            NSDictionary *doc = @{
                @"version": @1,
                @"name": name,
                @"senderID": [NSString stringWithFormat:@"0x%016llX", self->_senderID ?: kFallbackSenderID],
                @"duration": self->_frames.lastObject[@"t"],
                @"frames": self->_frames,
            };
            NSError *err = nil;
            NSData *data = [NSJSONSerialization dataWithJSONObject:doc options:0 error:&err];
            if (!data || ![data writeToFile:[self pathForName:name] atomically:YES]) {
                NSLog(@"[TapRecorder] save failed: %@", err);
                name = nil;
            }
        }
        self->_frames = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.state = TRStateIdle;
            self.progress = 0;
            [self notifyChanged];
            if (completion) completion(name);
        });
    }];
}

#pragma mark - Storage

- (NSString *)storageDirectory { return kStorageDir; }

- (NSString *)pathForName:(NSString *)name {
    return [kStorageDir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]];
}

- (NSArray<NSString *> *)savedRecordingNames {
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kStorageDir error:nil];
    NSMutableArray *names = [NSMutableArray array];
    for (NSString *f in files) {
        if ([f.pathExtension isEqualToString:@"json"]) [names addObject:f.stringByDeletingPathExtension];
    }
    [names sortUsingSelector:@selector(compare:)];
    return names.reverseObjectEnumerator.allObjects;
}

- (void)deleteRecordingNamed:(NSString *)name {
    [[NSFileManager defaultManager] removeItemAtPath:[self pathForName:name] error:nil];
}

#pragma mark - Playback

- (BOOL)playRecordingNamed:(NSString *)name repeatCount:(NSUInteger)repeatCount speed:(double)speed {
    if (!_ready || self.state != TRStateIdle) return NO;
    NSData *data = [NSData dataWithContentsOfFile:[self pathForName:name]];
    NSDictionary *doc = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *frames = [doc isKindOfClass:NSDictionary.class] ? doc[@"frames"] : nil;
    if (frames.count == 0) return NO;

    uint64_t sender = strtoull([doc[@"senderID"] UTF8String] ?: "0", NULL, 16);
    if (sender == 0) sender = kFallbackSenderID;
    if (speed <= 0) speed = 1.0;

    self.cancelPlayback = NO;
    self.playLoopTotal = repeatCount;
    self.progress = 0;
    self.state = TRStatePlaying;
    [self notifyChanged];

    NSThread *th = [[NSThread alloc] initWithBlock:^{
        [self playbackLoop:frames sender:sender repeat:repeatCount speed:speed];
    }];
    th.qualityOfService = NSQualityOfServiceUserInteractive;
    th.name = @"TapRecorder.playback";
    [th start];
    return YES;
}

- (void)stopPlayback {
    if (self.state == TRStatePlaying) self.cancelPlayback = YES;
}

/// Sleeps until `target`, waking regularly to check for cancellation.
- (BOOL)waitUntil:(uint64_t)target {
    const uint64_t slice = TRSecondsToTicks(0.05);
    while (!self.cancelPlayback) {
        uint64_t now = mach_absolute_time();
        if (now >= target) return YES;
        mach_wait_until(target - now > slice ? now + slice : target);
    }
    return NO;
}

- (void)playbackLoop:(NSArray *)frames sender:(uint64_t)sender repeat:(NSUInteger)repeat speed:(double)speed {
    if (!_dispatchClient) _dispatchClient = TRHID.ClientCreate(kCFAllocatorDefault);
    if (!_dispatchClient) {
        NSLog(@"[TapRecorder] failed to create HID dispatch client");
        self.cancelPlayback = YES;
    }
    NSMutableDictionary<NSNumber *, NSDictionary *> *down = [NSMutableDictionary dictionary];

    for (NSUInteger loop = 0; repeat == 0 || loop < repeat; loop++) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.progress = loop + 1; [self notifyChanged]; });

        uint64_t base = mach_absolute_time() + TRSecondsToTicks(0.2);
        for (NSDictionary *frame in frames) {
            uint64_t target = base + TRSecondsToTicks([frame[@"t"] doubleValue] / speed);
            if (![self waitUntil:target]) goto done;
            NSArray *touches = frame[@"touches"];
            [self dispatchTouches:touches sender:sender];
            for (NSDictionary *t in touches) {
                if ([t[K_TOUCH] boolValue]) down[t[K_ID]] = t; else [down removeObjectForKey:t[K_ID]];
            }
        }
        // Short pause between loops.
        if (![self waitUntil:mach_absolute_time() + TRSecondsToTicks(0.5)]) goto done;
    }

done:
    if (down.count > 0) {
        // Lift any finger still pressed so nothing gets stuck.
        NSMutableArray *lifts = [NSMutableArray array];
        for (NSDictionary *t in down.allValues) {
            NSMutableDictionary *m = [t mutableCopy];
            m[K_TOUCH] = @NO; m[K_RANGE] = @NO;
            m[K_MASK] = @(kTRDigMaskRange | kTRDigMaskTouch);
            [lifts addObject:m];
        }
        [self dispatchTouches:lifts sender:sender];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        self.state = TRStateIdle;
        self.progress = 0;
        [self notifyChanged];
    });
}

- (void)dispatchTouches:(NSArray<NSDictionary *> *)touches sender:(uint64_t)sender {
    if (touches.count == 0 || !_dispatchClient) return;
    uint64_t now = mach_absolute_time();

    uint32_t parentMask = 0;
    BOOL anyTouch = NO, anyRange = NO;
    for (NSDictionary *t in touches) {
        parentMask |= [t[K_MASK] unsignedIntValue];
        anyTouch |= [t[K_TOUCH] boolValue];
        anyRange |= [t[K_RANGE] boolValue];
    }

    IOHIDEventRef parent = TRHID.CreateDigitizer(kCFAllocatorDefault, now, kTRTransducerHand,
                                                 0, 0, parentMask, 0, 0, 0, 0, 0, 0,
                                                 anyRange, anyTouch, 0);
    if (!parent) return;
    TRHID.SetInteger(parent, kTRDigIsDisplayIntegrated, 1);

    for (NSDictionary *t in touches) {
        uint32_t idn = [t[K_ID] unsignedIntValue];
        IOHIDEventRef child = TRHID.CreateFinger(kCFAllocatorDefault, now, idn, idn,
                                                 [t[K_MASK] unsignedIntValue],
                                                 [t[K_X] doubleValue], [t[K_Y] doubleValue], 0,
                                                 [t[K_PRESS] doubleValue], 0,
                                                 [t[K_RANGE] boolValue], [t[K_TOUCH] boolValue], 0);
        if (!child) continue;
        double maj = [t[K_MAJ] doubleValue], min = [t[K_MIN] doubleValue];
        if (maj > 0) TRHID.SetFloat(child, kTRDigMajorRadius, maj);
        if (min > 0) TRHID.SetFloat(child, kTRDigMinorRadius, min);
        TRHID.SetInteger(child, kTRDigIsDisplayIntegrated, 1);
        TRHID.AppendEvent(parent, child, 0);
        CFRelease(child);
    }

    TRHID.SetSenderID(parent, sender);
    TRHID.ClientDispatch(_dispatchClient, parent);
    CFRelease(parent);
}

@end
