// nxjob.h - a single launchd job, parsed from a standard launchd plist.
//
// Original work for this project. Reads the ordinary launchd keys (Label,
// Program/ProgramArguments, RunAtLoad, KeepAlive, EnvironmentVariables,
// Standard{Out,Error,In}Path, UserName/GroupName, WorkingDirectory,
// ThrottleInterval, StartInterval, Disabled) so that plists written for the
// system launchd load unchanged.

#import <Foundation/Foundation.h>
#import <sys/types.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(int, NXJobState) {
    NXJobStateUnloaded = 0,  // not in the table
    NXJobStateLoaded,        // known, not running (waiting, throttled, or done)
    NXJobStateRunning,       // has a live pid
    NXJobStateStopping,      // SIGTERM sent, waiting for it to die
};

@interface NXJob : NSObject

// --- static configuration (from the plist) ---
@property (nonatomic, copy)   NSString *label;              // required, unique
@property (nonatomic, copy, nullable) NSString *sourcePath; // plist on disk, if any
@property (nonatomic, copy, nullable) NSString *program;    // explicit executable
@property (nonatomic, copy)   NSArray<NSString *> *programArguments;
@property (nonatomic, copy)   NSDictionary<NSString *, NSString *> *environment;
@property (nonatomic, copy, nullable) NSString *workingDirectory;
@property (nonatomic, copy, nullable) NSString *rootDirectory;
@property (nonatomic, copy, nullable) NSString *standardOutPath;
@property (nonatomic, copy, nullable) NSString *standardErrorPath;
@property (nonatomic, copy, nullable) NSString *standardInPath;
@property (nonatomic, copy, nullable) NSString *userName;
@property (nonatomic, copy, nullable) NSString *groupName;
@property (nonatomic, assign) BOOL runAtLoad;
@property (nonatomic, assign) BOOL disabled;               // from the plist
@property (nonatomic, assign) NSTimeInterval throttleInterval; // default 10s
@property (nonatomic, assign) NSInteger startInterval;     // 0 = none

// KeepAlive: either an unconditional bool, or a dictionary of conditions.
@property (nonatomic, assign) BOOL keepAlivePresent;
@property (nonatomic, assign) BOOL keepAliveAlways;        // KeepAlive = <true/>
@property (nonatomic, strong, nullable) NSNumber *kaSuccessfulExit; // dict subkey
@property (nonatomic, strong, nullable) NSNumber *kaCrashed;        // dict subkey

// --- runtime state ---
@property (nonatomic, assign) NXJobState state;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, assign) BOOL hasExited;
@property (nonatomic, assign) int lastWaitStatus;         // raw waitpid() status
@property (nonatomic, assign) NSTimeInterval lastSpawn;
@property (nonatomic, assign) NSTimeInterval nextStart;   // 0 = asap when loaded
@property (nonatomic, assign) NSInteger spawnCount;
@property (nonatomic, assign) NSInteger fastCrashCount;   // consecutive quick crashes
@property (nonatomic, assign) BOOL pendingRestart;        // kickstart -k: revive on reap

+ (nullable instancetype)jobFromPlistAtPath:(NSString *)path error:(NSError **)error;
+ (nullable instancetype)jobFromDictionary:(NSDictionary *)dict
                                 sourcePath:(nullable NSString *)path
                                      error:(NSError **)error;

// Decide, given the last exit, whether the supervisor should bring it back.
- (BOOL)wantsRestartAfterExit;

// The resolved argv (Program + ProgramArguments, or ProgramArguments alone).
- (NSArray<NSString *> *)resolvedArguments;

- (NSString *)oneLineStatus;   // for `list`
- (NSString *)detailedPrint;   // for `print`
@end

NS_ASSUME_NONNULL_END
