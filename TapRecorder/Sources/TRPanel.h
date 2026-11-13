#pragma once
#import <UIKit/UIKit.h>

/// Floating, draggable control panel shown above every app (lives in SpringBoard).
@interface TRPanelWindow : UIWindow
+ (instancetype)shared;
- (void)show;
- (void)toggleVisible;
@end
