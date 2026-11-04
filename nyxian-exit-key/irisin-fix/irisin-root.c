/*
 * irisin-root — setuid root 包装程序（同 Sileo 的 giveMeRoot）。
 *
 * 只允许 Irisin 本体（<root>/Applications/irisin.app/irisin）调用：
 * 校验父进程后切换到 root，再 exec 同目录下原版的 irisin-install。
 * 不接受任何参数，清空环境变量，标准输入输出原样交给 irisin-install。
 */

#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

#define SELF_SUFFIX "/usr/libexec/irisin-root"

static int fail(const char *message)
{
    fprintf(stderr, "irisin-root: %s\n", message);
    return 77; /* EX_NOPERM */
}

int main(int argc, char *argv[])
{
    (void)argv;
    if (argc != 1) return fail("takes no arguments");

    char exe[PATH_MAX], root[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0 || realpath(exe, root) == NULL) {
        return fail("cannot resolve own path");
    }
    size_t length = strlen(root), suffix = strlen(SELF_SUFFIX);
    if (length < suffix || strcmp(root + length - suffix, SELF_SUFFIX) != 0) {
        return fail("not installed at /usr/libexec/irisin-root");
    }
    root[length - suffix] = '\0';

    /* 父进程必须是 Irisin：用 dev/inode 比较，不受路径写法影响 */
    char parent[4 * PATH_MAX], app[PATH_MAX];
    if (proc_pidpath(getppid(), parent, sizeof(parent)) <= 0) {
        return fail("cannot read parent process path");
    }
    snprintf(app, sizeof(app), "%s/Applications/irisin.app/irisin", root);
    struct stat a, b;
    if (stat(parent, &a) != 0 || stat(app, &b) != 0 || a.st_dev != b.st_dev || a.st_ino != b.st_ino) {
        return fail("permission denied, parent process is not Irisin");
    }

    if (setgid(0) != 0 || setuid(0) != 0) {
        return fail("failed to obtain root");
    }

    char helper[PATH_MAX];
    snprintf(helper, sizeof(helper), "%s/usr/libexec/irisin-install", root);
    char *helper_argv[] = { helper, NULL };
    char *helper_envp[] = { NULL };
    execve(helper, helper_argv, helper_envp);
    fprintf(stderr, "irisin-root: exec %s failed: %s\n", helper, strerror(errno));
    return 71; /* EX_OSERR */
}
