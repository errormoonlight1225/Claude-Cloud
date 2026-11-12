// nxjob.m - see nxjob.h.

#import "nxjob.h"
#import <sys/wait.h>

static NSString *const NXJobErrorDomain = @"NXJobError";

@implementation NXJob

+ (nullable instancetype)jobFromPlistAtPath:(NSString *)path error:(NSError **)error
{
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    if (!data) return nil;
    id obj = [NSPropertyListSerialization propertyListWithData:data
                                                       options:NSPropertyListImmutable
                                                        format:NULL
                                                         error:error];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        if (error) *error = [NSError errorWithDomain:NXJobErrorDomain code:1
                               userInfo:@{NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat:@"%@: not a plist dictionary", path]}];
        return nil;
    }
    return [self jobFromDictionary:obj sourcePath:path error:error];
}

+ (nullable instancetype)jobFromDictionary:(NSDictionary *)d
                                 sourcePath:(nullable NSString *)path
                                      error:(NSError **)error
{
    NSString *label = d[@"Label"];
    if (![label isKindOfClass:[NSString class]] || label.length == 0) {
        if (error) *error = [NSError errorWithDomain:NXJobErrorDomain code:2
                               userInfo:@{NSLocalizedDescriptionKey: @"missing Label"}];
        return nil;
    }

    NXJob *j = [NXJob new];
    j.label      = label;
    j.sourcePath = path;

    id prog = d[@"Program"];
    if ([prog isKindOfClass:[NSString class]]) j.program = prog;

    id args = d[@"ProgramArguments"];
    if ([args isKindOfClass:[NSArray class]]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id x in args) if ([x isKindOfClass:[NSString class]]) [a addObject:x];
        j.programArguments = a;
    } else {
        j.programArguments = @[];
    }

    if (j.program == nil && j.programArguments.count == 0) {
        if (error) *error = [NSError errorWithDomain:NXJobErrorDomain code:3
                               userInfo:@{NSLocalizedDescriptionKey:
                                   [NSString stringWithFormat:@"%@: needs Program or ProgramArguments", label]}];
        return nil;
    }

    id env = d[@"EnvironmentVariables"];
    if ([env isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (id k in env) {
            id v = env[k];
            if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSString class]]) m[k] = v;
        }
        j.environment = m;
    } else {
        j.environment = @{};
    }

    if ([d[@"WorkingDirectory"]  isKindOfClass:[NSString class]]) j.workingDirectory  = d[@"WorkingDirectory"];
    if ([d[@"RootDirectory"]     isKindOfClass:[NSString class]]) j.rootDirectory     = d[@"RootDirectory"];
    if ([d[@"StandardOutPath"]   isKindOfClass:[NSString class]]) j.standardOutPath   = d[@"StandardOutPath"];
    if ([d[@"StandardErrorPath"] isKindOfClass:[NSString class]]) j.standardErrorPath = d[@"StandardErrorPath"];
    if ([d[@"StandardInPath"]    isKindOfClass:[NSString class]]) j.standardInPath    = d[@"StandardInPath"];
    if ([d[@"UserName"]          isKindOfClass:[NSString class]]) j.userName          = d[@"UserName"];
    if ([d[@"GroupName"]         isKindOfClass:[NSString class]]) j.groupName         = d[@"GroupName"];

    j.runAtLoad = [d[@"RunAtLoad"] respondsToSelector:@selector(boolValue)] && [d[@"RunAtLoad"] boolValue];
    j.disabled  = [d[@"Disabled"]  respondsToSelector:@selector(boolValue)] && [d[@"Disabled"]  boolValue];

    id ti = d[@"ThrottleInterval"];
    j.throttleInterval = [ti respondsToSelector:@selector(doubleValue)] ? [ti doubleValue] : 10.0;
    if (j.throttleInterval < 0) j.throttleInterval = 0;

    id si = d[@"StartInterval"];
    j.startInterval = [si respondsToSelector:@selector(integerValue)] ? [si integerValue] : 0;

    id ka = d[@"KeepAlive"];
    if (ka != nil) {
        j.keepAlivePresent = YES;
        if ([ka isKindOfClass:[NSNumber class]]) {
            j.keepAliveAlways = [ka boolValue];
        } else if ([ka isKindOfClass:[NSDictionary class]]) {
            id se = ka[@"SuccessfulExit"];
            id cr = ka[@"Crashed"];
            if ([se isKindOfClass:[NSNumber class]]) j.kaSuccessfulExit = se;
            if ([cr isKindOfClass:[NSNumber class]]) j.kaCrashed = cr;
        }
    }

    j.state = NXJobStateUnloaded;
    j.pid   = -1;
    return j;
}

- (NSArray<NSString *> *)resolvedArguments
{
    if (self.programArguments.count > 0) {
        if (self.program.length > 0 &&
            ![self.programArguments.firstObject isEqual:self.program]) {
            // Program overrides argv[0]'s executable but argv is preserved; the
            // caller execs `program` with this argv.
        }
        return self.programArguments;
    }
    return self.program ? @[self.program] : @[];
}

- (BOOL)wantsRestartAfterExit
{
    if (self.disabled) return NO;

    // KeepAlive dictionary conditions take precedence when present.
    if (self.kaSuccessfulExit != nil || self.kaCrashed != nil) {
        int st = self.lastWaitStatus;  // W* macros take the address of their arg
        BOOL exited   = WIFEXITED(st);
        BOOL success  = exited && WEXITSTATUS(st) == 0;
        BOOL crashed  = WIFSIGNALED(st);
        if (self.kaSuccessfulExit != nil) {
            // SuccessfulExit=YES: keep alive only if it exited 0; NO: only if nonzero.
            if (self.kaSuccessfulExit.boolValue)  return success;
            else                                  return exited && !success;
        }
        if (self.kaCrashed != nil) {
            if (self.kaCrashed.boolValue)  return crashed;
            else                           return !crashed;
        }
        return NO;
    }

    if (self.keepAliveAlways) return YES;

    // No KeepAlive: a RunAtLoad job runs once and stays down after it exits.
    return NO;
}

- (NSString *)oneLineStatus
{
    NSString *pidStr = (self.state == NXJobStateRunning) ?
        [NSString stringWithFormat:@"%d", self.pid] : @"-";
    NSString *last = @"-";
    if (self.hasExited) {
        int st = self.lastWaitStatus;
        if (WIFEXITED(st))        last = [NSString stringWithFormat:@"%d", WEXITSTATUS(st)];
        else if (WIFSIGNALED(st)) last = [NSString stringWithFormat:@"-%d", WTERMSIG(st)];
    }
    return [NSString stringWithFormat:@"%-8@ %-8@ %@", pidStr, last, self.label];
}

- (NSString *)detailedPrint
{
    NSMutableString *s = [NSMutableString string];
    [s appendFormat:@"%@ = {\n", self.label];
    [s appendFormat:@"\tstate = %@\n", @[@"unloaded",@"loaded",@"running",@"stopping"][self.state]];
    [s appendFormat:@"\tpid = %@\n", self.state == NXJobStateRunning ? @(self.pid) : @"-"];
    if (self.hasExited) {
        int st = self.lastWaitStatus;
        if (WIFEXITED(st))
            [s appendFormat:@"\tlast exit code = %d\n", WEXITSTATUS(st)];
        else if (WIFSIGNALED(st))
            [s appendFormat:@"\tlast terminating signal = %d\n", WTERMSIG(st)];
    }
    [s appendFormat:@"\tprogram = %@\n", self.program ?: self.programArguments.firstObject ?: @"?"];
    [s appendFormat:@"\targuments = %@\n", [self.programArguments componentsJoinedByString:@" "]];
    if (self.userName)  [s appendFormat:@"\tusername = %@\n", self.userName];
    if (self.groupName) [s appendFormat:@"\tgroupname = %@\n", self.groupName];
    [s appendFormat:@"\trunatload = %@\n", self.runAtLoad ? @"true" : @"false"];
    if (self.keepAlivePresent) [s appendFormat:@"\tkeepalive = %@\n", self.keepAliveAlways ? @"true" : @"conditional"];
    [s appendFormat:@"\tthrottle = %.0f s\n", self.throttleInterval];
    if (self.startInterval > 0) [s appendFormat:@"\tstartinterval = %ld s\n", (long)self.startInterval];
    [s appendFormat:@"\tspawns = %ld\n", (long)self.spawnCount];
    if (self.sourcePath) [s appendFormat:@"\tpath = %@\n", self.sourcePath];
    [s appendString:@"}\n"];
    return s;
}

@end
