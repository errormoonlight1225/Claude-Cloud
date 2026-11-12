// nxmanager.h - the job table and supervisor.
//
// Holds every loaded NXJob, spawns and reaps their processes, and applies the
// KeepAlive / throttle policy. The daemon's run loop drives it: feed it reaped
// pids with -reapPid:status:, call -tickNow for due (re)starts, and ask
// -nextDeadline when to wake next.

#import <Foundation/Foundation.h>
#import "nxjob.h"

NS_ASSUME_NONNULL_BEGIN

@interface NXManager : NSObject

// Directories scanned by -loadFromSearchPaths (LaunchDaemons dirs).
@property (nonatomic, copy) NSArray<NSString *> *searchPaths;
// Where enable/disable overrides persist.
@property (nonatomic, copy) NSString *overridesPath;

- (instancetype)initWithOverridesPath:(NSString *)overridesPath;

// --- operations, each returns human-readable text and sets *ok ---
- (NSString *)loadPaths:(NSArray<NSString *> *)paths ok:(BOOL *)ok;
- (NSString *)unloadTargets:(NSArray<NSString *> *)targets ok:(BOOL *)ok;
- (NSString *)startLabels:(NSArray<NSString *> *)labels ok:(BOOL *)ok;
- (NSString *)stopLabels:(NSArray<NSString *> *)labels ok:(BOOL *)ok;
- (NSString *)kickstartLabels:(NSArray<NSString *> *)labels hard:(BOOL)hard ok:(BOOL *)ok;
- (NSString *)listFilter:(nullable NSString *)filter ok:(BOOL *)ok;
- (NSString *)printLabel:(NSString *)label ok:(BOOL *)ok;
- (NSString *)setLabels:(NSArray<NSString *> *)labels disabled:(BOOL)disabled ok:(BOOL *)ok;

// Load every *.plist under searchPaths at boot and start RunAtLoad jobs.
- (void)loadFromSearchPaths;

// --- run-loop hooks ---
- (void)reapPid:(pid_t)pid status:(int)status;   // a child was waitpid'd
- (void)tickNow;                                  // start anything now due
- (NSTimeInterval)nextDeadline;                   // absolute time, or 0 if none
- (void)terminateAllForShutdown;                  // SIGTERM everything

@end

NS_ASSUME_NONNULL_END
