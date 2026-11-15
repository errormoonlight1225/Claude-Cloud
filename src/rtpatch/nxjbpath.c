// nxjbpath.c - makes every guest program use the /var/jb inside the app.
//
// Shipped in the ROM as `rtpatch`. Nyxian's guest startup dlopen()s
// $vroot/boot/rtpatch in every process before the program's own code runs
// (Shims/environment.m), which is the one place a ROM can put code into all
// guests.
//
// What it does: Nyxian routes the libc file functions of a guest through
// replaceable pointer slots (libBroadpatch exports `<function>__ptr`, e.g.
// `open__ptr`). We put a small wrapper in each path-taking slot. The wrapper
// rewrites a path at or below /var/jb to $vroot/var/jb and calls whatever was
// in the slot before, so Nyxian's own patches keep working underneath.
//
// What it cannot do: paths that never pass through those slots. That is the
// dynamic loader (dylib install names, dlopen) and anything the real kernel
// resolves on its own (a symlink whose target is an absolute /var/jb path,
// a #! line). See docs/ANALYSIS.md, "路径层".
//
// Original work for this project. It uses the slot names as an interface and
// contains no Nyxian code.

#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

#include "jbmap.h"

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

static char g_vroot[PATH_MAX];

static inline const char *mp(const char *path, char *buf)
{
    return nx_jbmap(g_vroot, path, buf, PATH_MAX);
}

// ---- wrappers ---------------------------------------------------------------
// Buffers and structs the wrappers only pass through are void *, so this file
// needs no platform types and also builds for the host tests.

#define BUF char b[PATH_MAX]
#define BUF2 char b[PATH_MAX], b2[PATH_MAX]

static int (*o_open)(const char *, int, ...);
static int w_open(const char *path, int flags, ...)
{
    BUF; int mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    return o_open(mp(path, b), flags, mode);
}

static int (*o_openat)(int, const char *, int, ...);
static int w_openat(int fd, const char *path, int flags, ...)
{
    BUF; int mode = 0;
    if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, int); va_end(ap); }
    return o_openat(fd, mp(path, b), flags, mode);
}

// __open_nocancel is what libc's own fopen()/opendir() end up in. Its callers
// may pass the mode in the third register (a plain call) or on the stack (a
// variadic call); hand both on unchanged.
static int (*o_open_nc)(const char *, int, unsigned long, ...);
static int w_open_nc(const char *path, int flags, unsigned long reg, ...)
{
    BUF; unsigned long stk;
    va_list ap; va_start(ap, reg); stk = va_arg(ap, unsigned long); va_end(ap);
    return o_open_nc(mp(path, b), flags, reg, stk);
}

#define WRAP_P1(name, ret, decl, call)                 \
    static ret (*o_##name) decl;                       \
    static ret w_##name decl { BUF; return o_##name call; }

WRAP_P1(stat,      int, (const char *p, void *sb),                         (mp(p, b), sb))
WRAP_P1(stat64,    int, (const char *p, void *sb),                         (mp(p, b), sb))
WRAP_P1(lstat,     int, (const char *p, void *sb),                         (mp(p, b), sb))
WRAP_P1(fstatat,   int, (int fd, const char *p, void *sb, int fl),         (fd, mp(p, b), sb, fl))
WRAP_P1(access,    int, (const char *p, int m),                            (mp(p, b), m))
WRAP_P1(faccessat, int, (int fd, const char *p, int m, int fl),            (fd, mp(p, b), m, fl))
WRAP_P1(unlink,    int, (const char *p),                                   (mp(p, b)))
WRAP_P1(unlinkat,  int, (int fd, const char *p, int fl),                   (fd, mp(p, b), fl))
WRAP_P1(mkdir,     int, (const char *p, mode_t m),                         (mp(p, b), m))
WRAP_P1(mkdirat,   int, (int fd, const char *p, mode_t m),                 (fd, mp(p, b), m))
WRAP_P1(rmdir,     int, (const char *p),                                   (mp(p, b)))
WRAP_P1(chdir,     int, (const char *p),                                   (mp(p, b)))
WRAP_P1(opendir,   void *, (const char *p),                                (mp(p, b)))
WRAP_P1(chmod,     int, (const char *p, mode_t m),                         (mp(p, b), m))
WRAP_P1(chown,     int, (const char *p, uid_t u, gid_t g),                 (mp(p, b), u, g))
WRAP_P1(lchown,    int, (const char *p, uid_t u, gid_t g),                 (mp(p, b), u, g))
WRAP_P1(fchownat,  int, (int fd, const char *p, uid_t u, gid_t g, int fl), (fd, mp(p, b), u, g, fl))
WRAP_P1(chflags,   int, (const char *p, unsigned int f),                   (mp(p, b), f))
WRAP_P1(truncate,  int, (const char *p, off_t n),                          (mp(p, b), n))
WRAP_P1(readlink,  ssize_t, (const char *p, char *o, size_t n),            (mp(p, b), o, n))
WRAP_P1(readlinkat, ssize_t, (int fd, const char *p, char *o, size_t n),   (fd, mp(p, b), o, n))
WRAP_P1(realpath,  char *, (const char *p, char *o),                       (mp(p, b), o))
WRAP_P1(getattrlist, int, (const char *p, void *al, void *ab, size_t n, unsigned long op),
                                                                           (mp(p, b), al, ab, n, op))
WRAP_P1(execv,     int, (const char *p, char *const a[]),                  (mp(p, b), a))
WRAP_P1(execve,    int, (const char *p, char *const a[], char *const e[]), (mp(p, b), a, e))
WRAP_P1(posix_spawn, int, (pid_t *pid, const char *p, const void *fa, const void *at,
                           char *const a[], char *const e[]),              (pid, mp(p, b), fa, at, a, e))

static int (*o_rename)(const char *, const char *);
static int w_rename(const char *a, const char *c) { BUF2; return o_rename(mp(a, b), mp(c, b2)); }

static int (*o_renameat)(int, const char *, int, const char *);
static int w_renameat(int fa, const char *a, int fc, const char *c)
{ BUF2; return o_renameat(fa, mp(a, b), fc, mp(c, b2)); }

static int (*o_link)(const char *, const char *);
static int w_link(const char *a, const char *c) { BUF2; return o_link(mp(a, b), mp(c, b2)); }

// symlink(target, link): the link's own path is mapped like any other. The
// target is data the real kernel follows later, so an absolute /var/jb target
// is stored relative to the link when both are under /var/jb, and as the real
// absolute path otherwise.
static const char *map_target(const char *target, const char *link, char *buf)
{
    const char *trest = nx_jb_rest(target);
    if (trest == NULL) return target;
    const char *lrest = nx_jb_rest(link);
    if (lrest != NULL && lrest[0] == '/' && lrest[1] != '\0') {
        if (trest[0] == '/' && trest[1] != '\0') {
            const char *rel = nx_relative_target(lrest + 1, trest + 1, buf, PATH_MAX);
            if (rel != NULL) return rel;
        }
    }
    return mp(target, buf);
}

static int (*o_symlink)(const char *, const char *);
static int w_symlink(const char *target, const char *linkp)
{ BUF2; return o_symlink(map_target(target, linkp, b), mp(linkp, b2)); }

static int (*o_symlinkat)(const char *, int, const char *);
static int w_symlinkat(const char *target, int fd, const char *linkp)
{ BUF2; return o_symlinkat(map_target(target, linkp, b), fd, mp(linkp, b2)); }

// The *p variants search $PATH when the name has no '/'. Do that search here,
// so that PATH entries under /var/jb are found whoever implements the rest.
static const char *find_in_path(const char *file, char *out)
{
    if (file == NULL || file[0] == '\0' || strchr(file, '/') != NULL) return NULL;
    const char *path = getenv("PATH");
    if (path == NULL || o_access == NULL) return NULL;
    size_t lf = strlen(file);
    while (*path) {
        const char *e = strchr(path, ':');
        size_t ld = e ? (size_t)(e - path) : strlen(path);
        char cand[PATH_MAX], mapped[PATH_MAX];
        if (ld == 0) { cand[0] = '.'; ld = 1; } else if (ld < PATH_MAX) memcpy(cand, path, ld);
        if (ld + 1 + lf + 1 <= PATH_MAX) {
            cand[ld] = '/';
            memcpy(cand + ld + 1, file, lf + 1);
            const char *real = mp(cand, mapped);
            if (o_access(real, X_OK) == 0) {
                memcpy(out, real, strlen(real) + 1);
                return out;
            }
        }
        if (e == NULL) break;
        path = e + 1;
    }
    return NULL;
}

static int (*o_posix_spawnp)(pid_t *, const char *, const void *, const void *,
                             char *const [], char *const []);
static int w_posix_spawnp(pid_t *pid, const char *file, const void *fa, const void *at,
                          char *const a[], char *const e[])
{
    BUF; const char *found = find_in_path(file, b);
    if (found != NULL && o_posix_spawn != NULL) return o_posix_spawn(pid, found, fa, at, a, e);
    return o_posix_spawnp(pid, mp(file, b), fa, at, a, e);
}

static int (*o_execvp)(const char *, char *const []);
static int w_execvp(const char *file, char *const a[])
{
    BUF; const char *found = find_in_path(file, b);
    if (found != NULL && o_execv != NULL) return o_execv(found, a);
    return o_execvp(mp(file, b), a);
}

// execl(path, arg0, ..., NULL) and friends: gather the arguments and go through
// the array forms above.
#define GATHER_ARGS(last)                                                     \
    size_t n = 0; va_list ap;                                                 \
    va_start(ap, arg0);                                                       \
    if (arg0 != NULL) { n = 1; while (va_arg(ap, char *) != NULL) n++; }      \
    last;                                                                     \
    va_end(ap);                                                               \
    char *argv[n + 1];                                                        \
    va_start(ap, arg0);                                                       \
    argv[0] = (char *)arg0;                                                   \
    for (size_t i = 1; i < n; i++) argv[i] = va_arg(ap, char *);              \
    va_end(ap);                                                               \
    argv[n] = NULL

static int (*o_execl)(const char *, const char *, ...);
static int w_execl(const char *path, const char *arg0, ...)
{ GATHER_ARGS((void)0); return w_execv(path, argv); }

static int (*o_execlp)(const char *, const char *, ...);
static int w_execlp(const char *file, const char *arg0, ...)
{ GATHER_ARGS((void)0); return w_execvp(file, argv); }

static int (*o_execle)(const char *, const char *, ...);
static int w_execle(const char *path, const char *arg0, ...)
{
    char *const *envp = NULL;
    GATHER_ARGS(envp = va_arg(ap, char *const *));      // the environment follows the NULL
    return w_execve(path, argv, envp);
}

// ---- installation -----------------------------------------------------------

static int g_hooked, g_missing;

// Put `repl` in the slot `<name>__ptr`, remembering what was there. A slot that
// does not exist (another Nyxian version, the host tests) is skipped.
static void hook(const char *slot, void *repl, void *origp)
{
    void **ptr = (void **)dlsym(RTLD_DEFAULT, slot);
    if (ptr == NULL || *ptr == NULL) { g_missing++; return; }
    *(void **)origp = *ptr;
    *ptr = repl;
    g_hooked++;
}
#define HOOK(name)          hook(#name "__ptr", (void *)w_##name, (void *)&o_##name)
#define HOOK_AS(slot, name) hook(slot "__ptr", (void *)w_##name, (void *)&o_##name)

static int ends_with(const char *s, const char *suffix, size_t *at)
{
    size_t ls = strlen(s), lx = strlen(suffix);
    if (ls < lx || strcmp(s + ls - lx, suffix) != 0) return 0;
    *at = ls - lx;
    return 1;
}

// $vroot: ask Nyxian's guest runtime; failing that, work it out from where
// this library was loaded from.
static void find_vroot(void)
{
    const char *env = getenv("NXJB_VROOT");                 // tests only
    if (env != NULL && env[0] == '/' && strlen(env) < PATH_MAX) { strcpy(g_vroot, env); return; }

    const char *(*vroot_fn)(void) = (const char *(*)(void))dlsym(RTLD_DEFAULT, "liveshim_vroot");
    const char *v = vroot_fn ? vroot_fn() : NULL;
    if (v != NULL && v[0] == '/' && strlen(v) < PATH_MAX) { strcpy(g_vroot, v); return; }

    Dl_info info;
    if (dladdr((void *)&find_vroot, &info) != 0 && info.dli_fname != NULL) {
        size_t at, n = strlen(info.dli_fname);
        if (n < PATH_MAX - 32) {
            if (ends_with(info.dli_fname, "/mntfs/bootfs/rtpatch", &at)) {
                memcpy(g_vroot, info.dli_fname, at);
                strcpy(g_vroot + at, "/rootfs");
            } else if (ends_with(info.dli_fname, "/boot/rtpatch", &at)) {
                memcpy(g_vroot, info.dli_fname, at);
                g_vroot[at] = '\0';
            }
        }
    }
}

__attribute__((constructor))
static void nxjbpath_init(void)
{
    const char *off = getenv("NXJB_DISABLE");
    if (off != NULL && off[0] == '1') return;

    find_vroot();
    if (g_vroot[0] == '\0') {
        if (getenv("NXJB_DEBUG")) fprintf(stderr, "nxjbpath: no vroot, not installed\n");
        return;
    }
    { size_t n = strlen(g_vroot); while (n > 1 && g_vroot[n - 1] == '/') g_vroot[--n] = '\0'; }

    HOOK(open);      HOOK(openat);    HOOK_AS("__open_nocancel", open_nc);
    HOOK(stat);      HOOK(stat64);    HOOK(lstat);       HOOK(fstatat);
    HOOK(access);    HOOK(faccessat);
    HOOK(unlink);    HOOK(unlinkat);  HOOK(rename);      HOOK(renameat);
    HOOK(link);      HOOK(symlink);   HOOK(symlinkat);
    HOOK(readlink);  HOOK(readlinkat);
    HOOK(mkdir);     HOOK(mkdirat);   HOOK(rmdir);
    HOOK(chdir);     HOOK(opendir);   HOOK(getattrlist);
    HOOK(chmod);     HOOK(chown);     HOOK(lchown);      HOOK(fchownat);
    HOOK(chflags);   HOOK(truncate);  HOOK(realpath);
    HOOK(posix_spawn); HOOK(posix_spawnp);
    HOOK(execv);     HOOK(execve);    HOOK(execvp);
    if (o_execv != NULL)  HOOK(execl);        // these three end in the array forms
    if (o_execvp != NULL) HOOK(execlp);
    if (o_execve != NULL) HOOK(execle);

    if (getenv("NXJB_DEBUG"))
        fprintf(stderr, "nxjbpath: /var/jb -> %s/var/jb (%d slots, %d missing)\n",
                g_vroot, g_hooked, g_missing);
}
