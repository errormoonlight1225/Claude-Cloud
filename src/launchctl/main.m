// nxlaunchctl - the client for nxlaunchd.
//
// Usage mirrors the common launchctl verbs:
//   nxlaunchctl load   <plist|dir> ...
//   nxlaunchctl unload <plist|label> ...
//   nxlaunchctl start  <label> ...
//   nxlaunchctl stop   <label> ...
//   nxlaunchctl kickstart [-k] <label> ...
//   nxlaunchctl list   [label-substring]
//   nxlaunchctl print  <label>
//   nxlaunchctl enable  <label> ...
//   nxlaunchctl disable <label> ...
//   nxlaunchctl bootstrap <plist> ... | bootout <plist|label> ...

#import <Foundation/Foundation.h>
#import "nxcontrol.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>
#import <errno.h>

static NSString *socketPath(void)
{
    const char *env = getenv("LAUNCHD_SOCKET");
    return env ? @(env) : NXRealPath(@(NX_DEFAULT_SOCKET));
}

static void usage(void)
{
    fprintf(stderr,
        "usage: nxlaunchctl <command> [args]\n"
        "  load|bootstrap <plist|dir>...   unload|bootout <plist|label>...\n"
        "  start|stop <label>...           kickstart [-k] <label>...\n"
        "  list [filter]                   print <label>\n"
        "  enable|disable <label>...\n");
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 2) { usage(); return 2; }

        NSString *cmd = @(argv[1]);
        NSMutableArray<NSString *> *args = [NSMutableArray array];
        NSMutableDictionary *flags = [NSMutableDictionary dictionary];
        for (int i = 2; i < argc; i++) {
            NSString *a = @(argv[i]);
            if ([cmd isEqualToString:@"kickstart"] && [a isEqualToString:@"-k"]) { flags[@"kill"] = @YES; continue; }
            [args addObject:a];
        }

        static NSDictionary *map;
        map = @{
            @"load": NXOpLoad, @"bootstrap": NXOpBootstrap,
            @"unload": NXOpUnload, @"bootout": NXOpBootout,
            @"start": NXOpStart, @"stop": NXOpStop, @"kickstart": NXOpKickstart,
            @"list": NXOpList, @"print": NXOpPrint,
            @"enable": NXOpEnable, @"disable": NXOpDisable,
        };
        NSString *op = map[cmd];
        if (!op) { usage(); return 2; }

        // Resolve relative plist paths to absolute so the daemon can find them.
        // unload/bootout also take a label, which must be left as it is: there,
        // only something that looks like a path or names an existing file is one.
        BOOL loading = [op isEqual:NXOpLoad] || [op isEqual:NXOpBootstrap];
        if (loading || [op isEqual:NXOpUnload] || [op isEqual:NXOpBootout]) {
            NSFileManager *fm = [NSFileManager defaultManager];
            NSString *cwd = [fm currentDirectoryPath];
            NSMutableArray *abs = [NSMutableArray array];
            for (NSString *a in args) {
                BOOL isPath = loading || [a containsString:@"/"] || [fm fileExistsAtPath:a];
                [abs addObject:(a.isAbsolutePath || !isPath) ? a : [cwd stringByAppendingPathComponent:a]];
            }
            args = abs;
        }

        int fd = NXSocketConnect(socketPath());
        if (fd < 0) {
            fprintf(stderr, "nxlaunchctl: cannot reach nxlaunchd at %s: %s\n",
                    socketPath().UTF8String, strerror(errno));
            return 1;
        }

        NSDictionary *req = @{ NXReqOp: op, NXReqArgs: args, NXReqFlags: flags };
        if (!NXWriteMessage(fd, req)) { fprintf(stderr, "nxlaunchctl: write failed\n"); return 1; }

        NSDictionary *rep = NXReadMessage(fd);
        close(fd);
        if (!rep) { fprintf(stderr, "nxlaunchctl: no reply\n"); return 1; }

        NSString *text = rep[NXRepText];
        if (text.length) fputs(text.UTF8String, stdout);
        return [rep[NXRepCode] intValue];
    }
}
