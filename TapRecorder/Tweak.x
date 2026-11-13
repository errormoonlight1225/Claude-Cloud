#import <UIKit/UIKit.h>
#import "Sources/TRLog.h"
#import "Sources/TRRecorder.h"
#import "Sources/TRPanel.h"

#define TR_DIR @"/var/mobile/Library/TapRecorder"
// Create this file (e.g. with Filza) to stop the tweak from doing anything.
static NSString *const kDisableFile = TR_DIR @"/disable";
// Present while SpringBoard is starting up with the tweak active. If it is
// still there on the next launch, that launch crashed or hung, so we skip.
static NSString *const kLaunchGuard = TR_DIR @"/.launch_guard";

// `notifyutil -p com.taprecorder.toggle` shows/hides the panel.
static void TRToggleCallback(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ [[TRPanelWindow shared] toggleVisible]; });
}

static void TRInitialize(void) {
    TRLog(@"init: start");
    @try {
        TRLog(@"init: HID setup");
        BOOL ok = [[TRRecorder shared] setup];
        TRLog(@"init: HID setup %@", ok ? @"ok" : @"FAILED");

        TRLog(@"init: creating panel");
        TRPanelWindow *panel = [TRPanelWindow shared];
        TRLog(@"init: showing panel");
        [panel show];
        TRLog(@"init: panel shown, frame=%@", NSStringFromCGRect(panel.frame));

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge void *)panel,
                                        TRToggleCallback, CFSTR("com.taprecorder.toggle"), NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    } @catch (NSException *e) {
        TRLog(@"init: EXCEPTION %@", e);
    }
    TRLog(@"init: done");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[NSFileManager defaultManager] removeItemAtPath:kLaunchGuard error:nil];
        TRLog(@"SpringBoard stable for 15s, launch guard cleared");
    });
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    TRLog(@"SpringBoard finished launching");
    // Wait until SpringBoard has fully settled before touching anything.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TRInitialize();
    });
}

%end

%ctor {
    @autoreleasepool {
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:TR_DIR withIntermediateDirectories:YES attributes:nil error:nil];
        TRLog(@"----- loaded into %@ -----", NSProcessInfo.processInfo.processName);

        if ([fm fileExistsAtPath:kDisableFile]) {
            TRLog(@"disable file present, doing nothing");
            return;
        }
        if ([fm fileExistsAtPath:kLaunchGuard]) {
            [fm removeItemAtPath:kLaunchGuard error:nil];
            TRLog(@"previous launch did not finish (hang/crash) - skipping this launch");
            return;
        }
        [fm createFileAtPath:kLaunchGuard contents:[NSData data] attributes:nil];

        %init;
        TRLog(@"hooks installed");
    }
}
