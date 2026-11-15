// nxmanager.m - see nxmanager.h.

#import "nxmanager.h"
#import "nxcontrol.h"
#import <spawn.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <pwd.h>
#import <grp.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>

extern char **environ;

static NSTimeInterval now(void) { return [NSDate timeIntervalSinceReferenceDate]; }

// A job that crashes faster than this many seconds after launch counts as a
// "fast crash"; after a run of them the throttle stretches out (backoff).
static const NSTimeInterval kFastCrashWindow = 5.0;
static const NSInteger      kFastCrashGiveUp = 10;  // stop auto-restart past this

@implementation NXManager {
    NSMutableDictionary<NSString *, NXJob *> *_jobs;    // label -> job
    NSMutableDictionary<NSNumber *, NSString *> *_byPid; // pid -> label
    NSMutableDictionary<NSString *, NSNumber *> *_overrides; // label -> disabled
}

- (instancetype)initWithOverridesPath:(NSString *)overridesPath
{
    if ((self = [super init])) {
        _jobs = [NSMutableDictionary dictionary];
        _byPid = [NSMutableDictionary dictionary];
        _overridesPath = [overridesPath copy];
        _overrides = [self loadOverrides];
        _searchPaths = @[];
    }
    return self;
}

#pragma mark - overrides persistence

- (NSMutableDictionary *)loadOverrides
{
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:_overridesPath];
    return d ? [d mutableCopy] : [NSMutableDictionary dictionary];
}

- (void)saveOverrides
{
    [_overrides writeToFile:_overridesPath atomically:YES];
}

- (BOOL)effectiveDisabled:(NXJob *)j
{
    NSNumber *o = _overrides[j.label];
    return o ? o.boolValue : j.disabled;
}

#pragma mark - spawning

// Resolve UserName/GroupName to ids; returns NO if a name was given but unknown.
- (BOOL)resolveUser:(NXJob *)j uid:(uid_t *)uid gid:(gid_t *)gid wantUid:(BOOL *)wantUid wantGid:(BOOL *)wantGid
{
    *wantUid = *wantGid = NO;
    if (j.userName) {
        struct passwd *pw = getpwnam(j.userName.UTF8String);
        if (!pw) return NO;
        *uid = pw->pw_uid; *gid = pw->pw_gid; *wantUid = YES; *wantGid = YES;
    }
    if (j.groupName) {
        struct group *gr = getgrnam(j.groupName.UTF8String);
        if (!gr) return NO;
        *gid = gr->gr_gid; *wantGid = YES;
    }
    return YES;
}

static int openRedirect(const char *path, int flags)
{
    return path ? open(path, flags, 0644) : -1;
}

// Launch the job's process. Uses fork/exec so we can set the login context
// (setsid), credentials (setgid/setuid), chdir/chroot and fd redirection the
// way a standard init does. Returns the pid, or -1 with errno set.
- (pid_t)spawnJob:(NXJob *)j
{
    NSArray<NSString *> *argv = j.resolvedArguments;
    if (argv.count == 0) { errno = EINVAL; return -1; }
    NSString *exe = j.program ?: argv.firstObject;

    uid_t uid = 0; gid_t gid = 0; BOOL wantUid = NO, wantGid = NO;
    if (![self resolveUser:j uid:&uid gid:&gid wantUid:&wantUid wantGid:&wantGid]) {
        errno = EINVAL; return -1;
    }

    // Build C arrays before the fork (no Objective-C in the child after fork).
    const char *cexe = strdup(exe.fileSystemRepresentation);
    char **cargv = calloc(argv.count + 1, sizeof(char *));
    for (NSUInteger i = 0; i < argv.count; i++) cargv[i] = strdup(argv[i].UTF8String);

    NSMutableDictionary *envd = [NSMutableDictionary dictionary];
    for (char **e = environ; *e; e++) {
        char *eq = strchr(*e, '=');
        if (!eq) continue;
        envd[[[NSString alloc] initWithBytes:*e length:(eq - *e) encoding:NSUTF8StringEncoding]] =
            [NSString stringWithUTF8String:eq + 1];
    }
    [j.environment enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *s){ envd[k] = v; }];
    char **cenv = calloc(envd.count + 1, sizeof(char *));
    { NSUInteger i = 0; for (NSString *k in envd)
        cenv[i++] = strdup([[NSString stringWithFormat:@"%@=%@", k, envd[k]] UTF8String]); }

    const char *cuser  = j.userName ? strdup(j.userName.UTF8String) : NULL;
    const char *cwd    = j.workingDirectory ? strdup(j.workingDirectory.fileSystemRepresentation) : NULL;
    const char *croot  = j.rootDirectory    ? strdup(j.rootDirectory.fileSystemRepresentation)    : NULL;
    const char *coutp  = j.standardOutPath   ? strdup(j.standardOutPath.fileSystemRepresentation)   : NULL;
    const char *cerrp  = j.standardErrorPath ? strdup(j.standardErrorPath.fileSystemRepresentation) : NULL;
    const char *cinp   = j.standardInPath    ? strdup(j.standardInPath.fileSystemRepresentation)    : NULL;

    pid_t pid = fork();
    if (pid < 0) return -1;

    if (pid == 0) {
        // --- child ---
        setsid();

        if (croot) { if (chroot(croot) != 0) _exit(126); if (chdir("/") != 0) _exit(126); }
        if (wantGid) { if (setgid(gid) != 0) _exit(126); if (cuser) initgroups(cuser, gid); }
        if (wantUid) { if (setuid(uid) != 0) _exit(126); }
        if (cwd) { if (chdir(cwd) != 0) _exit(126); }

        int devnull = open("/dev/null", O_RDWR);
        int fin  = cinp  ? openRedirect(cinp,  O_RDONLY)                 : devnull;
        int fout = coutp ? openRedirect(coutp, O_WRONLY|O_CREAT|O_APPEND): devnull;
        int ferr = cerrp ? openRedirect(cerrp, O_WRONLY|O_CREAT|O_APPEND): devnull;
        if (fin  >= 0) dup2(fin,  STDIN_FILENO);
        if (fout >= 0) dup2(fout, STDOUT_FILENO);
        if (ferr >= 0) dup2(ferr, STDERR_FILENO);
        if (fin  > STDERR_FILENO) close(fin);
        if (fout > STDERR_FILENO) close(fout);
        if (ferr > STDERR_FILENO) close(ferr);
        if (devnull > STDERR_FILENO) close(devnull);

        execve(cexe, cargv, cenv);
        _exit(127);  // exec failed
    }

    // --- parent ---
    free((void *)cexe);
    for (char **p = cargv; *p; p++) free(*p); free(cargv);
    for (char **p = cenv;  *p; p++) free(*p); free(cenv);
    free((void *)cuser); free((void *)cwd); free((void *)croot);
    free((void *)coutp); free((void *)cerrp); free((void *)cinp);
    return pid;
}

- (void)startJob:(NXJob *)j
{
    if (j.state == NXJobStateRunning) return;
    if ([self effectiveDisabled:j]) { j.state = NXJobStateLoaded; return; }

    pid_t pid = [self spawnJob:j];
    if (pid < 0) {
        NSLog(@"nxlaunchd: %@: spawn failed: %s", j.label, strerror(errno));
        j.state = NXJobStateLoaded;
        j.nextStart = now() + MAX(j.throttleInterval, 1.0);  // retry later
        return;
    }
    j.pid = pid;
    j.state = NXJobStateRunning;
    j.lastSpawn = now();
    j.nextStart = 0;
    j.spawnCount++;
    _byPid[@(pid)] = j.label;
}

#pragma mark - reaping & restart policy

- (void)reapPid:(pid_t)pid status:(int)status
{
    NSString *label = _byPid[@(pid)];
    if (!label) return;
    [_byPid removeObjectForKey:@(pid)];
    NXJob *j = _jobs[label];
    if (!j) return;

    j.hasExited = YES;
    j.lastWaitStatus = status;
    j.pid = -1;

    BOOL wasStopping = (j.state == NXJobStateStopping);
    j.state = NXJobStateLoaded;

    // Track fast crashes for backoff / give-up.
    if (now() - j.lastSpawn < kFastCrashWindow) j.fastCrashCount++;
    else                                        j.fastCrashCount = 0;

    // kickstart -k asked for an unconditional restart.
    if (j.pendingRestart) {
        j.pendingRestart = NO;
        j.fastCrashCount = 0;
        j.nextStart = now();
        return;
    }

    if (wasStopping) return;  // an explicit stop/unload: do not revive here

    if (![self effectiveDisabled:j] && [j wantsRestartAfterExit]) {
        if (j.fastCrashCount >= kFastCrashGiveUp) {
            NSLog(@"nxlaunchd: %@: too many fast crashes, not restarting", j.label);
            return;
        }
        NSTimeInterval backoff = j.throttleInterval;
        if (j.fastCrashCount > 0) backoff = MIN(j.throttleInterval * (1 << MIN(j.fastCrashCount, 5)), 300.0);
        j.nextStart = now() + backoff;
    }
}

- (void)tickNow
{
    NSTimeInterval t = now();
    for (NXJob *j in _jobs.allValues) {
        if (j.state != NXJobStateLoaded) continue;
        if ([self effectiveDisabled:j]) continue;

        BOOL due = NO;
        if (j.nextStart > 0 && t >= j.nextStart) due = YES;
        else if (j.nextStart == 0 && j.spawnCount == 0 && j.runAtLoad) due = YES;
        else if (j.nextStart == 0 && j.keepAliveAlways && j.spawnCount == 0) due = YES;
        // StartInterval periodic launches
        if (!due && j.startInterval > 0 && j.spawnCount > 0 && t >= j.lastSpawn + j.startInterval) due = YES;

        if (due) [self startJob:j];
    }
}

- (NSTimeInterval)nextDeadline
{
    NSTimeInterval best = 0;
    for (NXJob *j in _jobs.allValues) {
        if (j.state != NXJobStateLoaded || [self effectiveDisabled:j]) continue;
        NSTimeInterval d = 0;
        if (j.nextStart > 0) d = j.nextStart;
        else if (j.startInterval > 0 && j.spawnCount > 0) d = j.lastSpawn + j.startInterval;
        if (d > 0 && (best == 0 || d < best)) best = d;
    }
    return best;
}

#pragma mark - operations

- (NSArray<NSString *> *)expandToPlists:(NSArray<NSString *> *)paths
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *p in paths) {
        BOOL dir = NO;
        NSString *real = NXRealPath(p);     // Foundation gets the real location; names stay as given
        if ([fm fileExistsAtPath:real isDirectory:&dir] && dir) {
            for (NSString *name in [[fm contentsOfDirectoryAtPath:real error:NULL] sortedArrayUsingSelector:@selector(compare:)])
                if ([name.pathExtension isEqualToString:@"plist"])
                    [out addObject:[p stringByAppendingPathComponent:name]];
        } else {
            [out addObject:p];
        }
    }
    return out;
}

- (NSString *)loadPaths:(NSArray<NSString *> *)paths ok:(BOOL *)ok
{
    NSMutableString *msg = [NSMutableString string];
    BOOL any = NO;
    for (NSString *path in [self expandToPlists:paths]) {
        NSError *err = nil;
        NXJob *j = [NXJob jobFromPlistAtPath:path error:&err];
        if (!j) { [msg appendFormat:@"load %@: %@\n", path, err.localizedDescription]; continue; }
        if (_jobs[j.label]) { [msg appendFormat:@"%@: already loaded\n", j.label]; continue; }
        j.state = NXJobStateLoaded;
        _jobs[j.label] = j;
        any = YES;
        if (j.runAtLoad && ![self effectiveDisabled:j]) [self startJob:j];
    }
    if (ok) *ok = any || msg.length == 0;
    if (msg.length == 0) [msg appendString:@""];
    return msg;
}

- (NXJob *)jobForTarget:(NSString *)t
{
    if (_jobs[t]) return _jobs[t];
    // allow a plist path as target
    for (NXJob *j in _jobs.allValues) if ([j.sourcePath isEqualToString:t]) return j;
    return nil;
}

- (void)terminateJob:(NXJob *)j signal:(int)sig
{
    if (j.state == NXJobStateRunning && j.pid > 0) {
        j.state = NXJobStateStopping;
        kill(j.pid, sig);
    }
}

- (NSString *)unloadTargets:(NSArray<NSString *> *)targets ok:(BOOL *)ok
{
    NSMutableString *msg = [NSMutableString string];
    // targets may be plist paths; expand dirs too
    NSMutableArray *labels = [NSMutableArray array];
    for (NSString *t in [self expandToPlists:targets]) {
        NXJob *j = [self jobForTarget:t];
        if (!j) { // maybe a bare label slipped through expand
            j = _jobs[t];
        }
        if (j) [labels addObject:j.label];
        else   [msg appendFormat:@"%@: not loaded\n", t];
    }
    for (NSString *t in targets) if (_jobs[t]) [labels addObject:t];

    for (NSString *label in [NSSet setWithArray:labels]) {
        NXJob *j = _jobs[label];
        if (!j) continue;
        j.disabled = YES;                 // prevent restart on the reap
        [self terminateJob:j signal:SIGTERM];
        [_jobs removeObjectForKey:label];
    }
    if (ok) *ok = msg.length == 0;        // a target that was not loaded is an error
    return msg;
}

- (NSString *)startLabels:(NSArray<NSString *> *)labels ok:(BOOL *)ok
{
    NSMutableString *msg = [NSMutableString string];
    for (NSString *l in labels) {
        NXJob *j = _jobs[l];
        if (!j) { [msg appendFormat:@"%@: not loaded\n", l]; continue; }
        j.fastCrashCount = 0; j.nextStart = 0;
        [self startJob:j];
    }
    if (ok) *ok = YES;
    return msg;
}

- (NSString *)stopLabels:(NSArray<NSString *> *)labels ok:(BOOL *)ok
{
    NSMutableString *msg = [NSMutableString string];
    for (NSString *l in labels) {
        NXJob *j = _jobs[l];
        if (!j) { [msg appendFormat:@"%@: not loaded\n", l]; continue; }
        if (j.state != NXJobStateRunning) { [msg appendFormat:@"%@: not running\n", l]; continue; }
        [self terminateJob:j signal:SIGTERM];
    }
    if (ok) *ok = YES;
    return msg;
}

- (NSString *)kickstartLabels:(NSArray<NSString *> *)labels hard:(BOOL)hard ok:(BOOL *)ok
{
    NSMutableString *msg = [NSMutableString string];
    for (NSString *l in labels) {
        NXJob *j = _jobs[l];
        if (!j) { [msg appendFormat:@"%@: not loaded\n", l]; continue; }
        if (j.state == NXJobStateRunning) {
            if (hard) {
                // Kill the current instance; the reap will bring it straight back.
                j.pendingRestart = YES;
                kill(j.pid, SIGKILL);
            } else {
                [msg appendFormat:@"%@: already running (use -k to restart)\n", l];
            }
            continue;
        }
        j.fastCrashCount = 0; j.nextStart = 0;
        [self startJob:j];
    }
    if (ok) *ok = YES;
    return msg;
}

- (NSString *)listFilter:(NSString *)filter ok:(BOOL *)ok
{
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%-8@ %-8@ %@\n", @"PID", @"Status", @"Label"];
    for (NSString *label in [_jobs.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (filter && [label rangeOfString:filter].location == NSNotFound) continue;
        [s appendFormat:@"%@\n", [_jobs[label] oneLineStatus]];
    }
    if (ok) *ok = YES;
    return s;
}

- (NSString *)printLabel:(NSString *)label ok:(BOOL *)ok
{
    NXJob *j = _jobs[label];
    if (!j) { if (ok) *ok = NO; return [NSString stringWithFormat:@"%@: not loaded\n", label]; }
    if (ok) *ok = YES;
    return [j detailedPrint];
}

- (NSString *)setLabels:(NSArray<NSString *> *)labels disabled:(BOOL)disabled ok:(BOOL *)ok
{
    for (NSString *l in labels) _overrides[l] = @(disabled);
    [self saveOverrides];
    // apply immediately
    for (NSString *l in labels) {
        NXJob *j = _jobs[l];
        if (!j) continue;
        if (disabled && j.state == NXJobStateRunning) { j.disabled = YES; [self terminateJob:j signal:SIGTERM]; }
        if (!disabled) { j.nextStart = 0; }
    }
    if (ok) *ok = YES;
    return @"";
}

- (void)loadFromSearchPaths
{
    BOOL ok = NO;
    if (_searchPaths.count) [self loadPaths:_searchPaths ok:&ok];
}

- (void)terminateAllForShutdown
{
    for (NXJob *j in _jobs.allValues) {
        j.disabled = YES;
        [self terminateJob:j signal:SIGTERM];
    }
}

@end
