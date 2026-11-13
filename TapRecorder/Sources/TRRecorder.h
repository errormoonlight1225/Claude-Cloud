#pragma once
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TRState) {
    TRStateIdle,
    TRStateRecording,
    TRStatePlaying,
};

extern NSString *const TRStateDidChangeNotification;

@interface TRRecorder : NSObject

+ (instancetype)shared;

/// Loads IOKit symbols and creates the HID clients. Safe to call more than once.
- (BOOL)setup;
@property (nonatomic, readonly) BOOL ready;

@property (nonatomic, readonly) TRState state;
/// Frames captured so far (recording) or the current loop index (playing).
@property (nonatomic, readonly) NSUInteger progress;
@property (nonatomic, readonly) NSUInteger playLoopTotal;  // 0 = infinite

/// Touches that start inside this rect (normalized 0..1, portrait/fixed
/// coordinate space) are dropped while recording – used for the panel itself.
@property (atomic) CGRect ignoredNormalizedRect;

- (void)startRecording;
/// Stops recording and saves to disk. Returns the saved name or nil if nothing was captured.
- (nullable NSString *)stopRecording;

/// repeatCount 0 = loop forever. speed: 1.0 = real time.
- (BOOL)playRecordingNamed:(NSString *)name repeatCount:(NSUInteger)repeatCount speed:(double)speed;
- (void)stopPlayback;

- (NSArray<NSString *> *)savedRecordingNames;   // newest first
- (void)deleteRecordingNamed:(NSString *)name;
- (NSString *)storageDirectory;

@end

NS_ASSUME_NONNULL_END
