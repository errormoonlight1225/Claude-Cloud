// FilaCrashLog: 记录 Fila 闪退原因（诊断用）
//
// 把 Fila 的 stderr（Swift 的 fatalError 信息会打在这里）和崩溃时的调用栈
// 写到 Switzach 里的 /var/mobile/fila-crash.log，用 Filza 打开就能看。

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <execinfo.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static int g_fd = -1;

static void put(const char *s) { if (g_fd >= 0 && s) write(g_fd, s, strlen(s)); }

static void put_hex(uintptr_t v)
{
    char buf[19] = "0x";
    for (int i = 0; i < 16; i++) buf[2 + i] = "0123456789abcdef"[(v >> ((15 - i) * 4)) & 0xf];
    buf[18] = '\0';
    put(buf);
}

static void dump_stack(void)
{
    void *frames[64];
    int n = backtrace(frames, 64);
    for (int i = 0; i < n; i++) {
        Dl_info info;
        uintptr_t pc = (uintptr_t)frames[i];
        put("  ");
        put_hex(pc);
        if (dladdr(frames[i], &info)) {
            const char *img = info.dli_fname ? strrchr(info.dli_fname, '/') : NULL;
            put(" ");
            put(img ? img + 1 : info.dli_fname);
            put(" +");
            put_hex(pc - (uintptr_t)info.dli_fbase);
            if (info.dli_sname) { put(" "); put(info.dli_sname); }
        }
        put("\n");
    }
}

static void on_signal(int sig, siginfo_t *si, void *ctx)
{
    (void)ctx;
    put("\n=== signal ");
    char num[8]; snprintf(num, sizeof(num), "%d", sig); put(num);
    put(" ("); put(strsignal(sig)); put(") addr ");
    put_hex((uintptr_t)si->si_addr);
    put(" ===\n");
    dump_stack();
    signal(sig, SIG_DFL);
    raise(sig);
}

static void on_exception(NSException *e)
{
    put("\n=== NSException ===\n");
    put(e.name.UTF8String); put(": "); put(e.reason.UTF8String); put("\n");
    for (NSString *line in e.callStackSymbols) { put("  "); put(line.UTF8String); put("\n"); }
}

static void on_exit_hook(void) { put("\n=== exit() called ===\n"); dump_stack(); }

__attribute__((constructor))
static void fila_crashlog_init(void)
{
    char exe[PATH_MAX], root[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0) return;
    if (realpath(exe, root) == NULL) strlcpy(root, exe, sizeof(root));
    size_t len = strlen(root);
    const char *suffix = "/Applications/Fila.app/Fila";
    if (len < strlen(suffix) || strcmp(root + len - strlen(suffix), suffix) != 0) return;
    root[len - strlen(suffix)] = '\0';
    len = strlen(root);
    const char *boot = "/opt/procursus";
    if (len >= strlen(boot) && strcmp(root + len - strlen(boot), boot) == 0) root[len - strlen(boot)] = '\0';

    char path[PATH_MAX];
    snprintf(path, sizeof(path), "%s/var/mobile/fila-crash.log", root);
    g_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (g_fd < 0) {
        snprintf(path, sizeof(path), "%s/fila-crash.log", NSTemporaryDirectory().fileSystemRepresentation);
        g_fd = open(path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    }
    if (g_fd < 0) return;

    char head[256];
    time_t t = time(NULL);
    snprintf(head, sizeof(head), "Fila crash log, pid %d, uid %d, %s", getpid(), getuid(), ctime(&t));
    put(head);
    put("exe: "); put(exe); put("\nhome: "); put(NSHomeDirectory().UTF8String); put("\n\n");

    dup2(g_fd, STDERR_FILENO);          /* Swift fatalError / NSLog 输出 */
    setvbuf(stderr, NULL, _IONBF, 0);

    struct sigaction sa = {0};
    sa.sa_sigaction = on_signal;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    int sigs[] = { SIGSEGV, SIGBUS, SIGTRAP, SIGABRT, SIGILL, SIGFPE, SIGSYS };
    for (size_t i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) sigaction(sigs[i], &sa, NULL);
    NSSetUncaughtExceptionHandler(on_exception);
    atexit(on_exit_hook);
}
