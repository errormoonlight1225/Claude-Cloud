// Host test for the /var/jb path layer. It plays Nyxian's part by exporting
// `<function>__ptr` slots that point at the real libc functions, lets
// nxjbpath.c install itself into them, then calls through the slots the way a
// guest's interposed calls would.
//
//   make -C src/rtpatch test
//
// NXJB_VROOT must name an existing empty directory (the Makefile makes one).

#define _GNU_SOURCE
#include <dirent.h>
#include <spawn.h>
#include <sys/stat.h>
#include <sys/wait.h>

#include "../nxjbpath.c"

// ---- the slots (what libBroadpatch exports on the device) ----
static int fake_open_nocancel(const char *p, int f, mode_t m) { return open(p, f, m); }

#define SLOT(name) void *name##__ptr = (void *)name
SLOT(open); SLOT(openat); SLOT(stat); SLOT(lstat); SLOT(fstatat);
SLOT(access); SLOT(faccessat); SLOT(unlink); SLOT(unlinkat);
SLOT(rename); SLOT(renameat); SLOT(link); SLOT(symlink); SLOT(symlinkat);
SLOT(readlink); SLOT(readlinkat); SLOT(mkdir); SLOT(mkdirat); SLOT(rmdir);
SLOT(chdir); SLOT(opendir); SLOT(chmod); SLOT(chown); SLOT(lchown); SLOT(fchownat);
SLOT(truncate); SLOT(realpath); SLOT(posix_spawn); SLOT(posix_spawnp);
SLOT(execv); SLOT(execve); SLOT(execvp); SLOT(execl); SLOT(execlp); SLOT(execle);
void *__open_nocancel__ptr = (void *)fake_open_nocancel;

// call through a slot with the function's own type
#define VIA(name) ((__typeof__(&name))name##__ptr)

static int failures;
#define CHECK(cond, what) do { if (!(cond)) { failures++; \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, what); } } while (0)

static const char *real(const char *rest)
{
    static char buf[4][PATH_MAX]; static int i;
    char *b = buf[i++ & 3];
    snprintf(b, PATH_MAX, "%s/var/jb%s", getenv("NXJB_VROOT"), rest);
    return b;
}
static int exists(const char *p) { struct stat sb; return lstat(p, &sb) == 0; }
static void linkis(const char *p, const char *want)
{
    char got[PATH_MAX]; ssize_t n = readlink(p, got, sizeof got - 1);
    if (n < 0) { CHECK(0, p); return; }
    got[n] = '\0';
    if (strcmp(got, want) != 0) { failures++; fprintf(stderr, "FAIL link %s -> %s, want %s\n", p, got, want); }
}

static void test_pure(void)
{
    char o[64];
    CHECK(nx_jb_rest("/var/jb") && nx_jb_rest("/var/jb")[0] == '\0', "exact");
    CHECK(strcmp(nx_jb_rest("/var/jb/usr"), "/usr") == 0, "below");
    CHECK(strcmp(nx_jb_rest("/private/var/jb/x"), "/x") == 0, "private");
    CHECK(strcmp(nx_jb_rest("//var/jb/x"), "/x") == 0, "double slash");
    CHECK(nx_jb_rest("/var/jbx") == NULL, "prefix of a longer name");
    CHECK(nx_jb_rest("/var/mobile") == NULL, "other path");
    CHECK(nx_jb_rest("var/jb") == NULL, "relative");
    CHECK(nx_jb_rest(NULL) == NULL, "null");
    CHECK(strcmp(nx_jbmap("/R", "/var/jb/a", o, sizeof o), "/R/var/jb/a") == 0, "map");
    CHECK(strcmp(nx_jbmap("/R", "/etc/a", o, sizeof o), "/etc/a") == 0, "map other");
    { char tiny[8]; const char *p = "/var/jb/long/path"; CHECK(nx_jbmap("/R", p, tiny, sizeof tiny) == p, "no fit"); }

    struct { const char *link, *target, *want; } rel[] = {
        { "usr/bin/sh", "usr/bin/bash", "bash" },
        { "usr/bin/x", "usr/lib/y", "../lib/y" },
        { "usr/bin/x", "usr/binary", "../binary" },
        { "usr/bin/x", "usr/bin", "../bin" },
        { "usr/bin/x", "usr", "../../usr" },
        { "a", "b/c", "b/c" },
        { "a/b/c/d", "e", "../../../e" },
        { "usr/bin/x", "usr/bin/", "." },
    };
    for (size_t i = 0; i < sizeof rel / sizeof *rel; i++) {
        const char *r = nx_relative_target(rel[i].link, rel[i].target, o, sizeof o);
        if (r == NULL || strcmp(r, rel[i].want) != 0) {
            failures++;
            fprintf(stderr, "FAIL rel(%s, %s) = %s, want %s\n", rel[i].link, rel[i].target,
                    r ? r : "(null)", rel[i].want);
        }
    }
    CHECK(nx_relative_target("a/../b", "c", o, sizeof o) == NULL, "dotdot in link");
    CHECK(nx_relative_target("a/b", "/c", o, sizeof o) == NULL, "absolute target");
}

int main(void)
{
    const char *vroot = getenv("NXJB_VROOT");
    if (vroot == NULL) { fprintf(stderr, "set NXJB_VROOT\n"); return 2; }
    test_pure();
    CHECK(g_hooked >= 33, "slots hooked");

    char jb[PATH_MAX]; snprintf(jb, sizeof jb, "%s/var", vroot);
    mkdir(jb, 0755); mkdir(real(""), 0755);

    // directories and files
    CHECK(VIA(mkdir)("/var/jb/etc", 0755) == 0 && exists(real("/etc")), "mkdir");
    CHECK(VIA(mkdirat)(AT_FDCWD, "/var/jb/usr", 0755) == 0, "mkdirat");
    CHECK(VIA(mkdir)("/var/jb/usr/bin", 0755) == 0 && VIA(mkdir)("/var/jb/usr/lib", 0755) == 0, "mkdir 2");
    int fd = VIA(open)("/var/jb/etc/hello", O_CREAT | O_WRONLY, 0640);
    CHECK(fd >= 0 && exists(real("/etc/hello")), "open O_CREAT");
    if (fd >= 0) { CHECK(write(fd, "hi\n", 3) == 3, "write"); close(fd); }
    struct stat sb;
    CHECK(VIA(stat)("/var/jb/etc/hello", &sb) == 0 && sb.st_size == 3, "stat");
    CHECK((sb.st_mode & 0777) == 0640, "mode passed through open");
    CHECK(VIA(lstat)("/private/var/jb/etc/hello", &sb) == 0, "lstat /private");
    CHECK(VIA(fstatat)(AT_FDCWD, "/var/jb/etc/hello", &sb, 0) == 0, "fstatat");
    CHECK(VIA(access)("/var/jb/etc/hello", R_OK) == 0, "access");
    CHECK(VIA(faccessat)(AT_FDCWD, "/var/jb/etc/hello", R_OK, 0) == 0, "faccessat");
    CHECK(VIA(access)("/var/jb/etc/missing", F_OK) != 0 && errno == ENOENT, "access missing");
    fd = VIA(openat)(AT_FDCWD, "/var/jb/etc/hello", O_RDONLY);
    CHECK(fd >= 0, "openat"); if (fd >= 0) close(fd);
    fd = ((int (*)(const char *, int, mode_t))__open_nocancel__ptr)("/var/jb/etc/nc", O_CREAT | O_WRONLY, 0600);
    CHECK(fd >= 0 && exists(real("/etc/nc")), "__open_nocancel"); if (fd >= 0) close(fd);
    CHECK(stat(real("/etc/nc"), &sb) == 0 && (sb.st_mode & 0777) == 0600, "__open_nocancel mode");
    CHECK(VIA(chmod)("/var/jb/etc/hello", 0600) == 0, "chmod");
    CHECK(VIA(truncate)("/var/jb/etc/hello", 1) == 0 && stat(real("/etc/hello"), &sb) == 0 && sb.st_size == 1, "truncate");
    CHECK(VIA(chown)("/var/jb/etc/hello", getuid(), getgid()) == 0, "chown");

    // a path outside /var/jb is left alone
    CHECK(VIA(stat)("/", &sb) == 0 && VIA(access)("/var/jb-not", F_OK) != 0, "other paths");

    // rename, link, unlink
    CHECK(VIA(rename)("/var/jb/etc/hello", "/var/jb/etc/hello2") == 0 && exists(real("/etc/hello2")), "rename");
    CHECK(VIA(link)("/var/jb/etc/hello2", "/var/jb/etc/hello3") == 0 && exists(real("/etc/hello3")), "link");
    CHECK(VIA(unlink)("/var/jb/etc/hello3") == 0 && !exists(real("/etc/hello3")), "unlink");
    CHECK(VIA(unlinkat)(AT_FDCWD, "/var/jb/etc/nc", 0) == 0, "unlinkat");

    // symlinks: absolute /var/jb targets must not be stored as such
    CHECK(VIA(open)("/var/jb/usr/bin/bash", O_CREAT | O_WRONLY, 0755) >= 0, "create bash");
    CHECK(VIA(symlink)("/var/jb/usr/bin/bash", "/var/jb/usr/bin/sh") == 0, "symlink same dir");
    linkis(real("/usr/bin/sh"), "bash");
    CHECK(VIA(symlink)("/var/jb/usr/lib/x", "/var/jb/usr/bin/y") == 0, "symlink other dir");
    linkis(real("/usr/bin/y"), "../lib/x");
    CHECK(VIA(symlinkat)("relative-stays", AT_FDCWD, "/var/jb/usr/bin/z") == 0, "symlinkat relative");
    linkis(real("/usr/bin/z"), "relative-stays");
    CHECK(VIA(symlink)("/etc/passwd", "/var/jb/usr/bin/p") == 0, "symlink outside");
    linkis(real("/usr/bin/p"), "/etc/passwd");
    char lbuf[PATH_MAX];
    CHECK(VIA(readlink)("/var/jb/usr/bin/sh", lbuf, sizeof lbuf) == 4, "readlink");
    CHECK(VIA(stat)("/var/jb/usr/bin/sh", &sb) == 0, "follow relative link");
    {   // a link outside /var/jb that points into it gets the real absolute path
        char out[PATH_MAX], want[PATH_MAX]; snprintf(out, sizeof out, "%s/outside", vroot);
        CHECK(VIA(symlink)("/var/jb/usr/bin/bash", out) == 0, "symlink from outside");
        snprintf(want, sizeof want, "%s", real("/usr/bin/bash"));
        linkis(out, want);
    }

    // directories, cwd, realpath
    DIR *d = VIA(opendir)("/var/jb/usr/bin"); CHECK(d != NULL, "opendir"); if (d) closedir(d);
    char *rp = VIA(realpath)("/var/jb/usr/bin/sh", NULL), *want = realpath(real("/usr/bin/bash"), NULL);
    CHECK(rp && want && strcmp(rp, want) == 0, "realpath gives the real path"); free(rp);
    CHECK(VIA(chdir)("/var/jb/usr/bin") == 0, "chdir");
    char cwd[PATH_MAX]; free(want); want = realpath(real("/usr/bin"), NULL);
    CHECK(getcwd(cwd, sizeof cwd) && want && strcmp(cwd, want) == 0, "cwd is the real directory"); free(want);
    CHECK(VIA(rmdir)("/var/jb/usr/lib") == 0 && !exists(real("/usr/lib")), "rmdir");

    // spawning: by path, and by name through a PATH that is under /var/jb
    const char *script = "#!/bin/sh\nexit 7\n";
    fd = VIA(open)("/var/jb/usr/bin/seven", O_CREAT | O_WRONLY, 0755);
    CHECK(fd >= 0 && write(fd, script, strlen(script)) == (ssize_t)strlen(script), "script"); if (fd >= 0) close(fd);
    char *const argv[] = { "seven", NULL }; extern char **environ; pid_t pid; int st;
    CHECK(VIA(posix_spawn)(&pid, "/var/jb/usr/bin/seven", NULL, NULL, argv, environ) == 0, "posix_spawn");
    CHECK(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 7, "posix_spawn status");
    setenv("PATH", "/nonexistent:/var/jb/usr/bin", 1);
    CHECK(VIA(posix_spawnp)(&pid, "seven", NULL, NULL, argv, environ) == 0, "posix_spawnp via PATH");
    CHECK(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 7, "posix_spawnp status");
    CHECK(VIA(posix_spawnp)(&pid, "no-such-program", NULL, NULL, argv, environ) != 0, "posix_spawnp missing");
    pid = fork();
    if (pid == 0) { VIA(execvp)("seven", argv); _exit(99); }
    CHECK(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 7, "execvp via PATH");
    pid = fork();
    if (pid == 0) { VIA(execve)("/var/jb/usr/bin/seven", argv, environ); _exit(99); }
    CHECK(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 7, "execve");

    pid = fork();
    if (pid == 0) { VIA(execl)("/var/jb/usr/bin/seven", "seven", (char *)NULL); _exit(99); }
    CHECK(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 7, "execl");
    pid = fork();
    if (pid == 0) { VIA(execlp)("seven", "seven", "an-argument", (char *)NULL); _exit(99); }
    CHECK(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 7, "execlp via PATH");
    // execle hands over its own environment: the script reports one variable from it
    const char *envscript = "#!/bin/sh\n[ \"$NXJB_T\" = yes ] && exit 5\nexit 6\n";
    fd = VIA(open)("/var/jb/usr/bin/envcheck", O_CREAT | O_WRONLY, 0755);
    CHECK(fd >= 0 && write(fd, envscript, strlen(envscript)) == (ssize_t)strlen(envscript), "env script");
    if (fd >= 0) close(fd);
    char *const envp[] = { "NXJB_T=yes", NULL };
    pid = fork();
    if (pid == 0) { VIA(execle)("/var/jb/usr/bin/envcheck", "envcheck", (char *)NULL, envp); _exit(99); }
    CHECK(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 5, "execle with its environment");

    // scripts: the interpreter named on the #! line is under /var/jb, where the
    // real kernel cannot find it, so these only work if the layer runs them
    CHECK(VIA(mkdir)("/var/jb/bin", 0755) == 0 && VIA(symlink)("/bin/sh", "/var/jb/bin/sh") == 0, "an sh in /var/jb");
    const char *s1 = "#!/var/jb/bin/sh\nexit 11\n";
    const char *s2 = "#! /var/jb/bin/sh -e\n[ \"$1\" = one ] && [ \"$2\" = two ] && [ $# -eq 2 ] || exit 1\nfalse\nexit 12\n";
    fd = VIA(open)("/var/jb/usr/bin/s1", O_CREAT | O_WRONLY, 0755);
    CHECK(fd >= 0 && write(fd, s1, strlen(s1)) > 0, "s1"); if (fd >= 0) close(fd);
    fd = VIA(open)("/var/jb/usr/bin/s2", O_CREAT | O_WRONLY, 0755);
    CHECK(fd >= 0 && write(fd, s2, strlen(s2)) > 0, "s2"); if (fd >= 0) close(fd);
    char *const a1[] = { "s1", NULL };
    char *const a2[] = { "s2", "one", "two", NULL };
    CHECK(VIA(posix_spawn)(&pid, "/var/jb/usr/bin/s1", NULL, NULL, a1, environ) == 0, "spawn a script");
    CHECK(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 11, "script status");
    CHECK(VIA(posix_spawnp)(&pid, "s1", NULL, NULL, a1, environ) == 0, "spawn a script via PATH");
    CHECK(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 11, "script via PATH status");
    // "-e" from the #! line reaches the shell (the `false` ends it with 1, not 12),
    // and the caller's arguments follow the script
    CHECK(VIA(posix_spawn)(&pid, "/var/jb/usr/bin/s2", NULL, NULL, a2, environ) == 0, "spawn a script with arguments");
    CHECK(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 1, "interpreter and caller arguments");
    pid = fork();
    if (pid == 0) { VIA(execv)("/var/jb/usr/bin/s1", a1); _exit(99); }
    CHECK(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 11, "execv a script");
    pid = fork();
    if (pid == 0) { VIA(execlp)("s1", "s1", (char *)NULL); _exit(99); }
    CHECK(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 11, "execlp a script");
    pid = fork();
    if (pid == 0) { VIA(execve)("/var/jb/usr/bin/s1", a1, environ); _exit(99); }
    CHECK(waitpid(pid, &st, 0) == pid && WIFEXITED(st) && WEXITSTATUS(st) == 11, "execve a script");

    if (failures) { fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    printf("ok: %d slots hooked, all checks passed\n", g_hooked);
    return 0;
}
