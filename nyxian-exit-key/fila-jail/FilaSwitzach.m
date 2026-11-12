// FilaSwitzach: Fila 只显示 Switzach 容器里的文件系统
//
// Fila 自带"沙盒模式"（SandboxedLocalFileBackend）：把某个目录当成 "/"，
// 侧边栏、路径栏、导航都限制在这个目录里，不会走到外面。
// Fila 判断是否进入沙盒模式的方法是：opendir(dirname(NSHomeDirectory()))
// 打不开 → 沙盒。沙盒模式的根目录是 NSSearchPathForDirectoriesInDomains
// 返回的 Documents。
//
// 本插件：
//   1. 让启动时那一次探测 opendir 失败 → Fila 进入沙盒模式；
//   2. 让 Documents 指向 Switzach 根目录（<容器>/Library/Data）。
// 结果：Fila 里的 "/" 就是 Switzach 的 "/"。
//
// Switzach 里没有 Substrate/ElleKit，所以用改写导入表（fishhook 方式）。

#import <Foundation/Foundation.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

static char g_jail[PATH_MAX];        /* Switzach 根目录 */
static char g_probe[PATH_MAX];       /* dirname(NSHomeDirectory())，Fila 的沙盒探测路径 */
static volatile int g_probe_done;
static const struct mach_header *g_self_header;
static int g_rebind_count;

#pragma mark - 替换函数

static void trim_slash(char *p)
{
    size_t n = strlen(p);
    while (n > 1 && p[n - 1] == '/') p[--n] = '\0';
}

static bool same_path(const char *a, const char *b)
{
    char x[PATH_MAX], y[PATH_MAX];
    strlcpy(x, a, sizeof(x)); trim_slash(x);
    strlcpy(y, b, sizeof(y)); trim_slash(y);
    if (strcmp(x, y) == 0) return true;
    /* /private/var 与 /var 视为同一处 */
    const char *px = strncmp(x, "/private/", 9) == 0 ? x + 8 : x;
    const char *py = strncmp(y, "/private/", 9) == 0 ? y + 8 : y;
    return strcmp(px, py) == 0;
}

static DIR *fs_opendir(const char *path)
{
    if (!g_probe_done && path != NULL && g_probe[0] && same_path(path, g_probe)) {
        g_probe_done = 1;           /* 只拦截启动时那一次探测 */
        errno = EPERM;
        return NULL;
    }
    return opendir(path);
}

static NSArray<NSString *> *fs_search_path(NSSearchPathDirectory dir, NSSearchPathDomainMask mask, BOOL expand)
{
    if (dir == NSDocumentDirectory && (mask & NSUserDomainMask) && g_jail[0]) {
        return @[ [NSString stringWithUTF8String:g_jail] ];
    }
    return NSSearchPathForDirectoriesInDomains(dir, mask, expand);
}

#pragma mark - 改写导入表

static const struct { const char *name; void *replacement; } k_hooks[] = {
    { "_opendir", (void *)fs_opendir },
    { "_NSSearchPathForDirectoriesInDomains", (void *)fs_search_path },
};

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
        for (size_t h = 0; h < sizeof(k_hooks) / sizeof(k_hooks[0]); h++) {
            if (strcmp(name, k_hooks[h].name) != 0) continue;
            void **slot = &slots[i];
            void *replacement = k_hooks[h].replacement;
#if __has_feature(ptrauth_calls)
            replacement = ptrauth_strip(replacement, ptrauth_key_asia);
            replacement = ptrauth_sign_unauthenticated(replacement, ptrauth_key_asia, auth ? (void *)slot : 0);
#else
            (void)auth;
#endif
            uintptr_t page = (uintptr_t)slot & ~(uintptr_t)(getpagesize() - 1);
            if (mprotect((void *)page, (size_t)getpagesize() * 2, PROT_READ | PROT_WRITE) != 0) break;
            *slot = replacement;
            g_rebind_count++;
            break;
        }
    }
}

static void rebind_image(const struct mach_header *header, intptr_t slide)
{
    if (header == g_self_header || header->magic != MH_MAGIC_64) return;
    const struct mach_header_64 *mh = (const struct mach_header_64 *)header;
    if (mh->flags & 0x80000000 /* MH_DYLIB_IN_CACHE */) return;   /* 系统库不碰 */

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
                for (uint32_t j = 0; j < seg->nsects; j++) rebind_section(&sect[j], slide, symtab, strtab, indirect);
            }
        }
        cursor += lc->cmdsize;
    }
}

#pragma mark - 入口

static bool strip_suffix(char *path, const char *suffix)
{
    size_t p = strlen(path), s = strlen(suffix);
    if (p < s || strcmp(path + p - s, suffix) != 0) return false;
    path[p - s] = '\0';
    return true;
}

static bool is_dir(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}

__attribute__((constructor))
static void fila_switzach_init(void)
{
    char exe[PATH_MAX], real[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0) return;
    if (realpath(exe, real) == NULL) strlcpy(real, exe, sizeof(real));

    /* 只在 <bootstrap>/Applications/Fila.app/Fila 主程序里工作 */
    if (!strip_suffix(real, "/Applications/Fila.app/Fila")) return;
    /* Switzach: bootstrap 在 <容器>/Library/Data/opt/procursus，系统根是 <容器>/Library/Data */
    strip_suffix(real, "/opt/procursus");
    if (real[0] == '\0' || !is_dir(real)) return;   /* 真正越狱的根 "/" 就不改 */
    strlcpy(g_jail, real, sizeof(g_jail));

    @autoreleasepool {
        NSString *home = NSHomeDirectory();
        if (home.length > 0) {
            NSString *parent = [[home stringByStandardizingPath] stringByDeletingLastPathComponent];
            strlcpy(g_probe, parent.fileSystemRepresentation, sizeof(g_probe));
        }
    }

    Dl_info info;
    if (dladdr((const void *)fila_switzach_init, &info)) g_self_header = (const struct mach_header *)info.dli_fbase;
    _dyld_register_func_for_add_image(rebind_image);   /* 已加载的立即回调，后加载的框架也会回调 */
}
