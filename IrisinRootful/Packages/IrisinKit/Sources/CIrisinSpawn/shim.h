#pragma once

// libSystem's spawn calls, without the SDK's availability attributes. See
// module.modulemap for why. Each prototype is the SDK's own (spawn.h), and
// `<spawn.h>` is included only for its types and `POSIX_SPAWN_*` flags.

#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

int irisin_posix_spawn(pid_t *__restrict pid, const char *__restrict path,
                       const posix_spawn_file_actions_t *actions,
                       const posix_spawnattr_t *__restrict attributes,
                       char *const argv[__restrict], char *const envp[__restrict])
    __asm("_posix_spawn");

int irisin_posix_spawn_file_actions_init(posix_spawn_file_actions_t *actions)
    __asm("_posix_spawn_file_actions_init");
int irisin_posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *actions)
    __asm("_posix_spawn_file_actions_destroy");
int irisin_posix_spawn_file_actions_adddup2(posix_spawn_file_actions_t *actions, int descriptor,
                                            int target)
    __asm("_posix_spawn_file_actions_adddup2");
int irisin_posix_spawn_file_actions_addopen(posix_spawn_file_actions_t *__restrict actions,
                                            int target, const char *__restrict path, int flags,
                                            mode_t mode)
    __asm("_posix_spawn_file_actions_addopen");
// iOS 12 port: libSystem has posix_spawn_file_actions_addchdir_np from iOS 13
// on, so it is looked up at run time rather than imported, which dyld would
// refuse on iOS 12. Where it is missing, the spawning thread moves into the
// directory itself for the spawn (__pthread_chdir, what Foundation's own
// fallback does), and the child starts there.
typedef int (*irisin_addchdir_function)(posix_spawn_file_actions_t *, const char *);

static inline irisin_addchdir_function irisin_spawn_addchdir(void) {
    return (irisin_addchdir_function)dlsym(RTLD_DEFAULT, "posix_spawn_file_actions_addchdir_np");
}

static inline int irisin_posix_spawn_file_actions_addchdir(irisin_addchdir_function addchdir,
                                                           posix_spawn_file_actions_t *actions,
                                                           const char *path) {
    return addchdir(actions, path);
}

/// The calling thread's own working directory; 0 or an errno.
static inline int irisin_thread_chdir(const char *path) {
    return syscall(SYS___pthread_chdir, path) == 0 ? 0 : errno;
}

/// Back to the process's working directory.
static inline void irisin_thread_chdir_reset(void) {
    (void)syscall(SYS___pthread_fchdir, -1);
}

int irisin_posix_spawnattr_init(posix_spawnattr_t *attributes)
    __asm("_posix_spawnattr_init");
int irisin_posix_spawnattr_destroy(posix_spawnattr_t *attributes)
    __asm("_posix_spawnattr_destroy");
int irisin_posix_spawnattr_setflags(posix_spawnattr_t *attributes, short flags)
    __asm("_posix_spawnattr_setflags");
int irisin_posix_spawnattr_setsigdefault(posix_spawnattr_t *__restrict attributes,
                                         const sigset_t *__restrict signals)
    __asm("_posix_spawnattr_setsigdefault");
int irisin_posix_spawnattr_setsigmask(posix_spawnattr_t *__restrict attributes,
                                      const sigset_t *__restrict signals)
    __asm("_posix_spawnattr_setsigmask");
