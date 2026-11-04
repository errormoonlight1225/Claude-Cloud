/*
 * IrisinSwitzach — 让 Irisin 在 Switzach（Nyxian）里能安装软件包。
 *
 * Irisin 安装时通过 launchd 注册的 Mach 服务 "wiki.qaq.irisin.service"
 * 联系 root 守护进程 irisind。Switzach 是 Nyxian 里的模拟环境，真正的
 * iOS launchd 不认识这个服务，于是连接永远被重置（ECONNRESET）。
 *
 * 这个 dylib 只注入 Irisin：
 *   1. 在 Irisin 进程里建一个匿名 XPC 服务，按 irisind 的协议（v3）应答
 *      hello / run / goodbye；
 *   2. 拦截 xpc_connection_create_mach_service("wiki.qaq.irisin.service")，
 *      返回连到这个匿名服务的连接；
 *   3. run 时启动 setuid 包装程序 irisin-root（同 Sileo 的 giveMeRoot），
 *      它切换到 root 后 exec 原版 irisin-install；把 irisin-install 的输出
 *      管道交还给 Irisin，和 irisind 的做法完全一样。
 *
 * 只要 irisin-root 不存在或不是 setuid root，就什么都不做。
 * 纯 C，不包含 <xpc/xpc.h>（iOS SDK 把这些函数标成不可用），自己声明。
 */

#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <signal.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#pragma mark - libxpc 声明

typedef void *xpc_object_t;
typedef xpc_object_t xpc_connection_t;
typedef xpc_object_t xpc_endpoint_t;
typedef const void *xpc_type_t;
typedef void (^xpc_handler_t)(xpc_object_t);

extern const char _xpc_type_dictionary;
extern const char _xpc_type_connection;
#define EK_XPC_TYPE_DICTIONARY ((xpc_type_t)&_xpc_type_dictionary)
#define EK_XPC_TYPE_CONNECTION ((xpc_type_t)&_xpc_type_connection)

extern xpc_connection_t ek_xpc_connection_create(const char *, dispatch_queue_t) __asm__("_xpc_connection_create");
extern xpc_connection_t ek_xpc_connection_create_mach_service(const char *, dispatch_queue_t, uint64_t) __asm__("_xpc_connection_create_mach_service");
extern xpc_connection_t ek_xpc_connection_create_from_endpoint(xpc_endpoint_t) __asm__("_xpc_connection_create_from_endpoint");
extern xpc_endpoint_t ek_xpc_endpoint_create(xpc_connection_t) __asm__("_xpc_endpoint_create");
extern void ek_xpc_connection_set_event_handler(xpc_connection_t, xpc_handler_t) __asm__("_xpc_connection_set_event_handler");
extern void ek_xpc_connection_set_target_queue(xpc_connection_t, dispatch_queue_t) __asm__("_xpc_connection_set_target_queue");
extern void ek_xpc_connection_resume(xpc_connection_t) __asm__("_xpc_connection_resume");
extern void ek_xpc_connection_send_message(xpc_connection_t, xpc_object_t) __asm__("_xpc_connection_send_message");
extern xpc_type_t ek_xpc_get_type(xpc_object_t) __asm__("_xpc_get_type");
extern xpc_object_t ek_xpc_dictionary_create_reply(xpc_object_t) __asm__("_xpc_dictionary_create_reply");
extern uint64_t ek_xpc_dictionary_get_uint64(xpc_object_t, const char *) __asm__("_xpc_dictionary_get_uint64");
extern void ek_xpc_dictionary_set_uint64(xpc_object_t, const char *, uint64_t) __asm__("_xpc_dictionary_set_uint64");
extern void ek_xpc_dictionary_set_int64(xpc_object_t, const char *, int64_t) __asm__("_xpc_dictionary_set_int64");
extern void ek_xpc_dictionary_set_string(xpc_object_t, const char *, const char *) __asm__("_xpc_dictionary_set_string");
extern const void *ek_xpc_dictionary_get_data(xpc_object_t, const char *, size_t *) __asm__("_xpc_dictionary_get_data");
extern void ek_xpc_dictionary_set_fd(xpc_object_t, const char *, int) __asm__("_xpc_dictionary_set_fd");
extern void ek_xpc_release(xpc_object_t) __asm__("_xpc_release");

#pragma mark - Irisin 协议（IrisinWire.swift，version 3）

#define IW_SERVICE "wiki.qaq.irisin.service"
#define IW_VERSION 3
#define IW_MAX_JOB (256 * 1024)
enum { OP_HELLO = 1, OP_RUN = 2, OP_GOODBYE = 3 };
enum { RC_SUCCESS = 0, RC_INVALID = 1, RC_NOT_PERMITTED = 2, RC_NOT_FOUND = 3, RC_FAILED = 4 };

#ifndef POSIX_SPAWN_SETSID
#define POSIX_SPAWN_SETSID 0x0400
#endif
#ifndef POSIX_SPAWN_CLOEXEC_DEFAULT
#define POSIX_SPAWN_CLOEXEC_DEFAULT 0x4000
#endif

static char g_root[PATH_MAX];     /* bootstrap 根目录（irisind hello 回复的 installRoot） */
static char g_wrapper[PATH_MAX];  /* <root>/usr/libexec/irisin-root */
static dispatch_queue_t g_queue;
static xpc_connection_t g_listener;
static xpc_endpoint_t g_endpoint;
static uint64_t g_next_job = 1;

static void ek_log(const char *fmt, const char *arg)
{
    fprintf(stderr, "[IrisinSwitzach] ");
    fprintf(stderr, fmt, arg ? arg : "");
    fprintf(stderr, "\n");
}

static int64_t code_for_errno(int err)
{
    switch (err) {
    case ENOENT: case ENOTDIR: return RC_NOT_FOUND;
    case EACCES: case EPERM: return RC_NOT_PERMITTED;
    default: return RC_FAILED;
    }
}

#pragma mark - 启动 irisin-root → irisin-install

static int start_helper(const void *job, size_t length, int *err_out)
{
    int in[2] = { -1, -1 }, out[2] = { -1, -1 };
    if (pipe(in) != 0 || pipe(out) != 0) {
        *err_out = errno;
        if (in[0] >= 0) { close(in[0]); close(in[1]); }
        return -1;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, in[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, out[1], STDERR_FILENO);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    /* 自己的会话（和 irisind 一样），并且只继承 0/1/2 */
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT);

    char *argv[] = { g_wrapper, NULL };
    char *envp[] = { NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, g_wrapper, &actions, &attr, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
    close(in[0]);
    close(out[1]);
    if (rc != 0) {
        *err_out = rc;
        close(in[1]);
        close(out[0]);
        return -1;
    }

    /* 写入任务后关闭（helper 读到 EOF 才开始），并回收子进程 */
    void *copy = malloc(length);
    if (copy) memcpy(copy, job, length);
    int writeEnd = in[1];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (copy) {
            size_t offset = 0;
            while (offset < length) {
                ssize_t n = write(writeEnd, (const char *)copy + offset, length - offset);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) break;
                offset += (size_t)n;
            }
            free(copy);
        }
        close(writeEnd);
        int status = 0;
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    });
    return out[0];
}

#pragma mark - 进程内的 "irisind"

static void handle_message(xpc_connection_t peer, xpc_object_t message)
{
    if (ek_xpc_get_type(message) != EK_XPC_TYPE_DICTIONARY) return;
    xpc_object_t reply = ek_xpc_dictionary_create_reply(message);
    if (reply == NULL) return;

    ek_xpc_dictionary_set_uint64(reply, "v", IW_VERSION);
    int64_t code = RC_SUCCESS;
    int err = 0;
    uint64_t op = ek_xpc_dictionary_get_uint64(message, "op");

    if (ek_xpc_dictionary_get_uint64(message, "v") != IW_VERSION) {
        code = RC_INVALID;
    } else if (op == OP_HELLO) {
        ek_xpc_dictionary_set_string(reply, "root", g_root);
    } else if (op == OP_RUN) {
        size_t length = 0;
        const void *job = ek_xpc_dictionary_get_data(message, "job", &length);
        if (job == NULL || length == 0 || length > IW_MAX_JOB) {
            code = RC_INVALID;
        } else {
            int fd = start_helper(job, length, &err);
            if (fd < 0) {
                code = code_for_errno(err);
            } else {
                ek_xpc_dictionary_set_fd(reply, "fd", fd);
                close(fd);
                ek_xpc_dictionary_set_uint64(reply, "jobid", g_next_job++);
            }
        }
    } else if (op == OP_GOODBYE) {
        /* nothing */
    } else {
        /* 外部客户端接口（submitInstall 等）不支持 */
        code = RC_INVALID;
    }

    ek_xpc_dictionary_set_int64(reply, "code", code);
    if (code != RC_SUCCESS) ek_xpc_dictionary_set_int64(reply, "errno", err);
    ek_xpc_connection_send_message(peer, reply);
    ek_xpc_release(reply);
}

static bool start_server(void)
{
    g_queue = dispatch_queue_create("com.exitkey.irisinswitzach", DISPATCH_QUEUE_SERIAL);
    g_listener = ek_xpc_connection_create(NULL, g_queue); /* 匿名监听 */
    if (g_listener == NULL) return false;
    ek_xpc_connection_set_event_handler(g_listener, ^(xpc_object_t peer) {
        if (ek_xpc_get_type(peer) != EK_XPC_TYPE_CONNECTION) return;
        ek_xpc_connection_set_target_queue(peer, g_queue);
        ek_xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
            handle_message(peer, message);
        });
        ek_xpc_connection_resume(peer);
    });
    ek_xpc_connection_resume(g_listener);
    g_endpoint = ek_xpc_endpoint_create(g_listener);
    return g_endpoint != NULL;
}

#pragma mark - Hook

static xpc_connection_t (*orig_create_mach_service)(const char *, dispatch_queue_t, uint64_t);

static xpc_connection_t hook_create_mach_service(const char *name, dispatch_queue_t queue, uint64_t flags)
{
    if (name != NULL && flags == 0 && g_endpoint != NULL && strcmp(name, IW_SERVICE) == 0) {
        xpc_connection_t connection = ek_xpc_connection_create_from_endpoint(g_endpoint);
        if (connection != NULL) {
            if (queue != NULL) ek_xpc_connection_set_target_queue(connection, queue);
            return connection;
        }
    }
    return orig_create_mach_service(name, queue, flags);
}

typedef void (*MSHookFunction_t)(void *, void *, void **);

static MSHookFunction_t find_hooker(void)
{
    MSHookFunction_t hook = (MSHookFunction_t)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (hook) return hook;
    const char *libs[] = {
        "/usr/lib/libellekit.dylib",
        "/usr/lib/libsubstrate.dylib",
        "/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
        "/var/jb/usr/lib/libellekit.dylib",
    };
    for (size_t i = 0; i < sizeof(libs) / sizeof(libs[0]); i++) {
        void *handle = dlopen(libs[i], RTLD_NOW);
        if (handle && (hook = (MSHookFunction_t)dlsym(handle, "MSHookFunction"))) return hook;
    }
    return NULL;
}

#pragma mark - 入口

static bool strip_suffix(char *path, const char *suffix)
{
    size_t p = strlen(path), s = strlen(suffix);
    if (p < s || strcmp(path + p - s, suffix) != 0) return false;
    path[p - s] = '\0';
    return true;
}

__attribute__((constructor))
static void irisin_switzach_init(void)
{
    char exe[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0) return;
    if (realpath(exe, g_root) == NULL) return;
    /* 只在 <root>/Applications/irisin.app/irisin 里工作 */
    if (!strip_suffix(g_root, "/Applications/irisin.app/irisin")) return;

    snprintf(g_wrapper, sizeof(g_wrapper), "%s/usr/libexec/irisin-root", g_root);
    struct stat info;
    if (stat(g_wrapper, &info) != 0 || info.st_uid != 0 || (info.st_mode & S_ISUID) == 0) {
        ek_log("irisin-root missing or not setuid root: %s", g_wrapper);
        return;
    }

    MSHookFunction_t hook = find_hooker();
    if (hook == NULL) {
        ek_log("MSHookFunction not found%s", NULL);
        return;
    }
    if (!start_server()) {
        ek_log("could not start in-process service%s", NULL);
        return;
    }
    void *target = dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
    if (target == NULL) target = (void *)ek_xpc_connection_create_mach_service;
    hook(target, (void *)hook_create_mach_service, (void **)&orig_create_mach_service);
    ek_log("active, root=%s", g_root[0] ? g_root : "/");
}
