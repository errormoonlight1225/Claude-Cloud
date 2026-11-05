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
 *   3. run 时直接启动原版 irisin-install（以 501 运行），把它的输出管道
 *      交还给 Irisin，和 irisind 的做法完全一样。
 *
 * Switzach 里一切都以 mobile(501) 运行，bootstrap 全部 501 可写，
 * irisin-install 本身检测到非 root 会自动跳过 chown，所以不需要提权。
 *
 * 只要 irisin-install 不存在或不可执行，就什么都不做。
 * 纯 C，不包含 <xpc/xpc.h>（iOS SDK 把这些函数标成不可用），自己声明。
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dirent.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <time.h>
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

/* ObjC 下 Foundation 已带入系统的 xpc 类型定义，直接用它们；
   函数本身仍用 __asm__ 别名声明（iOS SDK 把部分函数标为不可用）。 */
#include <xpc/xpc.h>
typedef xpc_object_t ek_xpc_endpoint_t;
#define EK_XPC_TYPE_DICTIONARY XPC_TYPE_DICTIONARY
#define EK_XPC_TYPE_CONNECTION XPC_TYPE_CONNECTION

extern xpc_connection_t ek_xpc_connection_create(const char *, dispatch_queue_t) __asm__("_xpc_connection_create");
extern xpc_connection_t ek_xpc_connection_create_mach_service(const char *, dispatch_queue_t, uint64_t) __asm__("_xpc_connection_create_mach_service");
extern xpc_connection_t ek_xpc_connection_create_from_endpoint(ek_xpc_endpoint_t) __asm__("_xpc_connection_create_from_endpoint");
extern ek_xpc_endpoint_t ek_xpc_endpoint_create(xpc_connection_t) __asm__("_xpc_endpoint_create");
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
static char g_helper[PATH_MAX];   /* <root>/usr/libexec/irisin-install */
static dispatch_queue_t g_queue;
static xpc_connection_t g_listener;
static ek_xpc_endpoint_t g_endpoint;
static uint64_t g_next_job = 1;

/*
 * 诊断日志：缓存在内存里，并写进 Irisin 当前的 Dog 日志
 * (<Documents>/wiki.qaq.irisin/Journal/Dog_*.log)，这样用户用
 * "Export App Log" 就能把这些行一起导出。构造函数跑得比 Dog 早，
 * 所以启动后再延迟把缓存刷进当前日志。
 *
 * Switzach 里 Irisin 带容器，真实 Documents 在容器内，不是
 * /var/mobile/Documents。所以日志目录从 CFFIXED_USER_HOME / HOME
 * 推出来，并尝试多个候选路径。
 */
static char g_logbuf[8192];
static size_t g_logused;
static pthread_mutex_t g_loglock = PTHREAD_MUTEX_INITIALIZER;

/* 把当前缓存写进 <base>/Journal/ 下最新的 Dog_*.log，成功返回 true */
static bool ek_flush_dir(const char *journal)
{
    DIR *d = opendir(journal);
    if (d == NULL) return false;
    char newest[PATH_MAX] = {0};
    time_t newest_mtime = 0;
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strncmp(e->d_name, "Dog_", 4) != 0) continue;
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/%s", journal, e->d_name);
        struct stat st;
        if (stat(path, &st) == 0 && st.st_mtime >= newest_mtime) {
            newest_mtime = st.st_mtime;
            strncpy(newest, path, sizeof(newest) - 1);
        }
    }
    closedir(d);
    if (newest[0] == '\0') return false;
    int fd = open(newest, O_WRONLY | O_APPEND);
    if (fd < 0) return false;
    (void)write(fd, g_logbuf, g_logused);
    close(fd);
    return true;
}

static void ek_flush_to_dog(void)
{
    const char *suffix = "/Documents/wiki.qaq.irisin/Journal";
    char journal[PATH_MAX];
    const char *home;

    /* Nyxian 把整个 Switzach 根目录放在 <容器>/Library/Data 下，
       bootstrap 在 .../opt/procursus，Documents 在 .../var/mobile/Documents */
    if (g_root[0] != '\0') {
        char base[PATH_MAX];
        strncpy(base, g_root, sizeof(base) - 1);
        base[sizeof(base) - 1] = '\0';
        size_t bl = strlen(base);
        const char *proc = "/opt/procursus";
        size_t pl = strlen(proc);
        if (bl >= pl && strcmp(base + bl - pl, proc) == 0) base[bl - pl] = '\0';
        snprintf(journal, sizeof(journal), "%s/var/mobile%s", base, suffix);
        if (ek_flush_dir(journal)) return;
    }

    if ((home = getenv("CFFIXED_USER_HOME")) != NULL) {
        snprintf(journal, sizeof(journal), "%s%s", home, suffix);
        if (ek_flush_dir(journal)) return;
    }
    if ((home = getenv("HOME")) != NULL) {
        snprintf(journal, sizeof(journal), "%s%s", home, suffix);
        if (ek_flush_dir(journal)) return;
    }
    ek_flush_dir("/var/mobile/Documents/wiki.qaq.irisin/Journal");
}

static void ek_log(const char *fmt, const char *arg)
{
    char line[512];
    int n = snprintf(line, sizeof(line), "[IrisinSwitzach] ");
    n += snprintf(line + n, sizeof(line) - n, fmt, arg ? arg : "");
    n += snprintf(line + n, sizeof(line) - n, "\n");
    if (n < 0) return;

    fputs(line, stderr);
    pthread_mutex_lock(&g_loglock);
    if (g_logused + (size_t)n < sizeof(g_logbuf)) {
        memcpy(g_logbuf + g_logused, line, (size_t)n);
        g_logused += (size_t)n;
    }
    ek_flush_to_dog();
    pthread_mutex_unlock(&g_loglock);
}

static int64_t code_for_errno(int err)
{
    switch (err) {
    case ENOENT: case ENOTDIR: return RC_NOT_FOUND;
    case EACCES: case EPERM: return RC_NOT_PERMITTED;
    default: return RC_FAILED;
    }
}

#pragma mark - 启动 irisin-install

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

    char *argv[] = { g_helper, NULL };
    char *envp[] = { NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, g_helper, &actions, &attr, argv, envp);
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

    char opbuf[32]; snprintf(opbuf, sizeof(opbuf), "%llu", (unsigned long long)op);
    ek_log("message received, op=%s", opbuf);

    if (ek_xpc_dictionary_get_uint64(message, "v") != IW_VERSION) {
        code = RC_INVALID;
    } else if (op == OP_HELLO) {
        ek_xpc_dictionary_set_string(reply, "root", g_root);
        ek_log("hello -> root=%s", g_root[0] ? g_root : "/");
    } else if (op == OP_RUN) {
        size_t length = 0;
        const void *job = ek_xpc_dictionary_get_data(message, "job", &length);
        if (job == NULL || length == 0 || length > IW_MAX_JOB) {
            code = RC_INVALID;
            ek_log("run: invalid job data%s", NULL);
        } else {
            int fd = start_helper(job, length, &err);
            if (fd < 0) {
                code = code_for_errno(err);
                char eb[32]; snprintf(eb, sizeof(eb), "%d", err);
                ek_log("run: start_helper failed errno=%s", eb);
            } else {
                ek_log("run: helper started ok%s", NULL);
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

static int g_hook_hits;

static xpc_connection_t hook_create_mach_service(const char *name, dispatch_queue_t queue, uint64_t flags)
{
    if (name != NULL && strcmp(name, IW_SERVICE) == 0 && g_hook_hits < 3) {
        g_hook_hits++;
        ek_log("hook hit: lookup %s", name);
    }
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


#pragma mark - 无 Substrate 时：改写导入表（fishhook 方式）

#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <sys/mman.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

static const char *k_rebind_symbol = "_xpc_connection_create_mach_service";
static const struct mach_header *g_self_header;
static int g_rebind_count;

static void rebind_section(const struct section_64 *sect, intptr_t slide,
                           const struct nlist_64 *symtab, const char *strtab,
                           const uint32_t *indirect)
{
    uint32_t type = sect->flags & SECTION_TYPE;
    if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) return;
    bool auth = strncmp(sect->sectname, "__auth_got", 16) == 0;
    const uint32_t *indices = indirect + sect->reserved1;
    void **slots = (void **)((uintptr_t)slide + sect->addr);
    size_t count = sect->size / sizeof(void *);

    for (size_t i = 0; i < count; i++) {
        uint32_t index = indices[i];
        if (index == INDIRECT_SYMBOL_ABS || index == INDIRECT_SYMBOL_LOCAL ||
            index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
        const char *name = strtab + symtab[index].n_un.n_strx;
        if (strcmp(name, k_rebind_symbol) != 0) continue;

        void **slot = &slots[i];
        void *replacement = (void *)hook_create_mach_service;
#if __has_feature(ptrauth_calls)
        replacement = ptrauth_strip(replacement, ptrauth_key_asia);
        if (auth) replacement = ptrauth_sign_unauthenticated(replacement, ptrauth_key_asia, slot);
        else replacement = ptrauth_sign_unauthenticated(replacement, ptrauth_key_asia, 0);
#else
        (void)auth;
#endif
        uintptr_t page = (uintptr_t)slot & ~(uintptr_t)(getpagesize() - 1);
        if (mprotect((void *)page, (size_t)getpagesize() * 2, PROT_READ | PROT_WRITE) != 0) {
            char eb[32]; snprintf(eb, sizeof(eb), "%d", errno);
            ek_log("rebind: mprotect failed errno=%s", eb);
            continue;
        }
        *slot = replacement;
        g_rebind_count++;
    }
}

static void rebind_image(const struct mach_header *header, intptr_t slide)
{
    if (header == g_self_header || header->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
    /* 系统共享缓存里的库不碰：只改 Irisin 自己和它带的框架 */
    if (mh->flags & 0x80000000 /* MH_DYLIB_IN_CACHE */) return;
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab_cmd = NULL;
    const struct dysymtab_command *dysymtab_cmd = NULL;

    uintptr_t cursor = (uintptr_t)mh + sizeof(*mh);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit = seg;
        } else if (lc->cmd == LC_SYMTAB) {
            symtab_cmd = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (const struct dysymtab_command *)lc;
        }
        cursor += lc->cmdsize;
    }
    if (!linkedit || !symtab_cmd || !dysymtab_cmd || dysymtab_cmd->nindirectsyms == 0) return;

    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symtab = (const struct nlist_64 *)(base + symtab_cmd->symoff);
    const char *strtab = (const char *)(base + symtab_cmd->stroff);
    const uint32_t *indirect = (const uint32_t *)(base + dysymtab_cmd->indirectsymoff);

    cursor = (uintptr_t)mh + sizeof(*mh);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_DATA) == 0 || strcmp(seg->segname, "__DATA_CONST") == 0 ||
                strcmp(seg->segname, "__AUTH_CONST") == 0 || strcmp(seg->segname, "__AUTH") == 0) {
                const struct section_64 *sect = (const struct section_64 *)(seg + 1);
                for (uint32_t j = 0; j < seg->nsects; j++) {
                    rebind_section(&sect[j], slide, symtab, strtab, indirect);
                }
            }
        }
        cursor += lc->cmdsize;
    }
}

static void rebind_added_image(const struct mach_header *header, intptr_t slide)
{
    rebind_image(header, slide);
}

static void rebind_all_images(void)
{
    Dl_info info;
    if (dladdr((const void *)rebind_all_images, &info)) g_self_header = (const struct mach_header *)info.dli_fbase;
    /* 注册时会对已加载的所有镜像回调一次，之后加载的也会回调 */
    _dyld_register_func_for_add_image(rebind_added_image);
}

static bool strip_suffix(char *path, const char *suffix)
{
    size_t p = strlen(path), s = strlen(suffix);
    if (p < s || strcmp(path + p - s, suffix) != 0) return false;
    path[p - s] = '\0';
    return true;
}

/* 启动后把诊断缓存再刷一次：构造函数早于 Dog 建日志，这里补上 */
static void schedule_delayed_flush(void)
{
    for (int delay = 4; delay <= 12; delay += 4) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)delay * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            pthread_mutex_lock(&g_loglock);
            ek_flush_to_dog();
            pthread_mutex_unlock(&g_loglock);
        });
    }
}

/* 启动 6 秒后在 Irisin 里弹窗显示诊断，不依赖任何文件路径 */
static void ek_show_alert(void)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSString *text = nil;
        pthread_mutex_lock(&g_loglock);
        text = [[NSString alloc] initWithBytes:g_logbuf length:g_logused encoding:NSUTF8StringEncoding];
        pthread_mutex_unlock(&g_loglock);
        if (text.length == 0) text = @"(no log)";

        UIViewController *vc = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (w.isKeyWindow || vc == nil) vc = w.rootViewController;
            }
        }
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (vc == nil) return;

        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"IrisinSwitzach"
                                                                       message:text
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

__attribute__((constructor))
static void irisin_switzach_init(void)
{
    schedule_delayed_flush();
    ek_log("constructor entered%s", NULL);

    char exe[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0) { ek_log("NSGetExecutablePath failed%s", NULL); return; }
    ek_log("exe=%s", exe);
    if (realpath(exe, g_root) == NULL) {
        /* realpath 失败（符号链接解析不了）就用原始路径兜底 */
        strncpy(g_root, exe, sizeof(g_root) - 1);
        ek_log("realpath failed, using raw path%s", NULL);
    }
    ek_log("realpath=%s", g_root);
    /* 只在 <root>/Applications/irisin.app/irisin 里工作 */
    if (!strip_suffix(g_root, "/Applications/irisin.app/irisin")) {
        ek_log("suffix mismatch, not Irisin main binary%s", NULL);
        return;
    }
    ek_log("root=%s", g_root[0] ? g_root : "(empty=/)");

    snprintf(g_helper, sizeof(g_helper), "%s/usr/libexec/irisin-install", g_root);
    struct stat info;
    if (stat(g_helper, &info) != 0 || (info.st_mode & S_IFMT) != S_IFREG) {
        ek_log("irisin-install not found: %s", g_helper);
        ek_show_alert();
        /* 不直接返回：改用 PATH 兜底再记录，仍然安装 hook，便于诊断 */
    } else {
        ek_log("irisin-install ok: %s", g_helper);
    }

    if (!start_server()) {
        ek_log("could not start in-process service%s", NULL);
        ek_show_alert();
        return;
    }
    ek_log("in-process service started%s", NULL);

    /* 原函数：用本 dylib 自己的导入（不会被改写，因为跳过自身镜像） */
    orig_create_mach_service = ek_xpc_connection_create_mach_service;

    MSHookFunction_t hook = find_hooker();
    if (hook != NULL) {
        void *target = dlsym(RTLD_DEFAULT, "xpc_connection_create_mach_service");
        if (target == NULL) target = (void *)ek_xpc_connection_create_mach_service;
        hook(target, (void *)hook_create_mach_service, (void **)&orig_create_mach_service);
        ek_log("hook installed via MSHookFunction, ACTIVE%s", NULL);
    } else {
        ek_log("MSHookFunction not found, rebinding import tables%s", NULL);
        rebind_all_images();
        char nb[32]; snprintf(nb, sizeof(nb), "%d", g_rebind_count);
        ek_log("rebound import slots: %s", nb);
        if (g_rebind_count == 0) ek_show_alert();
    }
}
