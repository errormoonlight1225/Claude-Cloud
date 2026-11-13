#import <UIKit/UIKit.h>
#import "Sources/TRRecorder.h"
#import "Sources/TRPanel.h"

// Written before we initialise and removed once SpringBoard has stayed alive
// for a while. If it is still there on the next launch, the previous attempt
// hung or crashed, so we skip initialisation once instead of looping.
static NSString *const kLaunchGuard = @"/var/mobile/Library/TapRecorder/.launch_guard";

// `notifyutil -p com.taprecorder.toggle` shows/hides the panel.
static void TRToggleCallback(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ [[TRPanelWindow shared] toggleVisible]; });
}

static void TRInitialize(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:kLaunchGuard]) {
        [fm removeItemAtPath:kLaunchGuard error:nil];
        NSLog(@"[TapRecorder] previous launch did not finish initialising – skipping this time");
        return;
    }
    [fm createDirectoryAtPath:kLaunchGuard.stringByDeletingLastPathComponent
  withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createFileAtPath:kLaunchGuard contents:[NSData data] attributes:nil];

    @try {
        if (![[TRRecorder shared] setup]) NSLog(@"[TapRecorder] HID setup failed");
        [[TRPanelWindow shared] show];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TRToggleCallback,
                                        CFSTR("com.taprecorder.toggle"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    } @catch (NSException *e) {
        NSLog(@"[TapRecorder] init exception: %@", e);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[NSFileManager defaultManager] removeItemAtPath:kLaunchGuard error:nil];
    });
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    // Wait until SpringBoard has fully settled before touching anything.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TRInitialize();
    });
}

%end
