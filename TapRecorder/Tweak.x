#import <UIKit/UIKit.h>
#import "Sources/TRRecorder.h"
#import "Sources/TRPanel.h"

// `notifyutil -p com.taprecorder.toggle` shows/hides the panel.
static void TRToggleCallback(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef info) {
    dispatch_async(dispatch_get_main_queue(), ^{ [[TRPanelWindow shared] toggleVisible]; });
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![[TRRecorder shared] setup]) NSLog(@"[TapRecorder] HID setup failed");
        [[TRPanelWindow shared] show];
    });
}

%end

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, TRToggleCallback,
                                    CFSTR("com.taprecorder.toggle"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
