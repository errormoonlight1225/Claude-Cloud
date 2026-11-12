// nxlaunchd - a small launchd-compatible service supervisor.
//
// It reads standard launchd plists, runs and supervises the jobs (RunAtLoad,
// KeepAlive, throttling, StartInterval), and answers nxlaunchctl over an
// AF_UNIX control socket. It is an ordinary init-style daemon: it runs on a
// host that already lets it fork and exec (a jailbroken device's rootless
// prefix, or any Unix). It is not itself a sandbox-escape or code-loader.

#import <Foundation/Foundation.h>
#import "nxmanager.h"
#import "nxcontrol.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/wait.h>
#import <sys/stat.h>
#import <poll.h>
#import <unistd.h>
#import <fcntl.h>
#import <signal.h>
#import <errno.h>

static int gChildPipe[2] = { -1, -1 };  // self-pipe woken by SIGCHLD
static volatile sig_atomic_t gStop = 0;

static void onSigchld(int sig) { (void)sig; char b = 1; (void)write(gChildPipe[1], &b, 1); }
static void onStop(int sig)    { (void)sig; gStop = 1; char b = 2; (void)write(gChildPipe[1], &b, 1); }

static void setNonBlock(int fd) { fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK); }

static NSString *socketPath(void)
{
    const char *env = getenv("LAUNCHD_SOCKET");
    return env ? @(env) : @(NX_DEFAULT_SOCKET);
}

static NSString *statePath(void)
{
    const char *env = getenv("LAUNCHD_OVERRIDES");
    if (env) return @(env);
    return @(NX_PREFIX "/var/db/nxlaunchd.overrides.plist");
}

// Ensure the parent directory of `path` exists.
static void ensureParentDir(NSString *path)
{
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
        withIntermediateDirectories:YES attributes:nil error:NULL];
}

static int makeListenSocket(NSString *path)
{
    ensureParentDir(path);
    unlink(path.fileSystemRepresentation);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un addr; memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path.fileSystemRepresentation, sizeof(addr.sun_path) - 1);
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) { close(fd); return -1; }
    chmod(path.fileSystemRepresentation, 0600);
    if (listen(fd, 16) != 0) { close(fd); return -1; }
    return fd;
}

// Handle one request/reply on an accepted connection (blocking, one-shot).
static void serveClient(int cfd, NXManager *mgr)
{
    NSDictionary *req = NXReadMessage(cfd);
    if (!req) { close(cfd); return; }

    NSString *op = req[NXReqOp];
    NSArray *args = [req[NXReqArgs] isKindOfClass:[NSArray class]] ? req[NXReqArgs] : @[];
    NSDictionary *flags = [req[NXReqFlags] isKindOfClass:[NSDictionary class]] ? req[NXReqFlags] : @{};
    BOOL ok = YES;
    NSString *text = @"";

    @try {
        if      ([op isEqual:NXOpLoad] || [op isEqual:NXOpBootstrap]) text = [mgr loadPaths:args ok:&ok];
        else if ([op isEqual:NXOpUnload] || [op isEqual:NXOpBootout]) text = [mgr unloadTargets:args ok:&ok];
        else if ([op isEqual:NXOpStart])     text = [mgr startLabels:args ok:&ok];
        else if ([op isEqual:NXOpStop])      text = [mgr stopLabels:args ok:&ok];
        else if ([op isEqual:NXOpKickstart]) text = [mgr kickstartLabels:args hard:[flags[@"kill"] boolValue] ok:&ok];
        else if ([op isEqual:NXOpList])      text = [mgr listFilter:args.firstObject ok:&ok];
        else if ([op isEqual:NXOpPrint])     text = [mgr printLabel:(args.firstObject ?: @"") ok:&ok];
        else if ([op isEqual:NXOpEnable])    text = [mgr setLabels:args disabled:NO ok:&ok];
        else if ([op isEqual:NXOpDisable])   text = [mgr setLabels:args disabled:YES ok:&ok];
        else { ok = NO; text = [NSString stringWithFormat:@"unknown op: %@\n", op]; }
    } @catch (NSException *e) {
        ok = NO; text = [NSString stringWithFormat:@"internal error: %@\n", e.reason];
    }

    NXWriteMessage(cfd, @{ NXRepOK: @(ok), NXRepText: (text ?: @""), NXRepCode: @(ok ? 0 : 1) });
    close(cfd);
}

static void drainReaped(NXManager *mgr)
{
    int status; pid_t pid;
    while ((pid = waitpid(-1, &status, WNOHANG)) > 0)
        [mgr reapPid:pid status:status];
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        NXManager *mgr = [[NXManager alloc] initWithOverridesPath:statePath()];

        // Optional: directories to scan at boot, from argv or a default.
        NSMutableArray *search = [NSMutableArray array];
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--daemons-dir") == 0 && i + 1 < argc) [search addObject:@(argv[++i])];
        }
        if (search.count == 0) {
            [search addObject:@(NX_PREFIX "/Library/LaunchDaemons")];
        }
        mgr.searchPaths = search;

        if (pipe(gChildPipe) != 0) { perror("pipe"); return 1; }
        setNonBlock(gChildPipe[0]); setNonBlock(gChildPipe[1]);

        struct sigaction sa; memset(&sa, 0, sizeof(sa));
        sa.sa_handler = onSigchld; sigemptyset(&sa.sa_mask); sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
        sigaction(SIGCHLD, &sa, NULL);
        sa.sa_handler = onStop;    sa.sa_flags = 0;
        sigaction(SIGTERM, &sa, NULL); sigaction(SIGINT, &sa, NULL);
        signal(SIGPIPE, SIG_IGN);

        int lfd = makeListenSocket(socketPath());
        if (lfd < 0) { NSLog(@"nxlaunchd: cannot listen on %@: %s", socketPath(), strerror(errno)); return 1; }
        NSLog(@"nxlaunchd: listening on %@", socketPath());

        [mgr loadFromSearchPaths];
        [mgr tickNow];

        while (!gStop) {
            struct pollfd pfds[2] = {
                { .fd = lfd,           .events = POLLIN },
                { .fd = gChildPipe[0], .events = POLLIN },
            };
            NSTimeInterval deadline = [mgr nextDeadline];
            int timeout = -1;
            if (deadline > 0) {
                NSTimeInterval dt = deadline - [NSDate timeIntervalSinceReferenceDate];
                timeout = dt <= 0 ? 0 : (int)(dt * 1000) + 1;
            }

            int n = poll(pfds, 2, timeout);
            if (n < 0) { if (errno == EINTR) continue; break; }

            if (pfds[1].revents & POLLIN) {       // SIGCHLD / stop self-pipe
                char buf[64]; while (read(gChildPipe[0], buf, sizeof(buf)) > 0) {}
                drainReaped(mgr);
            }
            if (pfds[0].revents & POLLIN) {       // a control connection
                int cfd = accept(lfd, NULL, NULL);
                if (cfd >= 0) { @autoreleasepool { serveClient(cfd, mgr); } }
            }
            drainReaped(mgr);                      // catch any between poll wakeups
            [mgr tickNow];                         // start anything now due
        }

        NSLog(@"nxlaunchd: shutting down");
        [mgr terminateAllForShutdown];
        // Give children a moment to exit, reaping as they go.
        for (int i = 0; i < 50; i++) { drainReaped(mgr); usleep(100 * 1000); }
        unlink(socketPath().fileSystemRepresentation);
    }
    return 0;
}
