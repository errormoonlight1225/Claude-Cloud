// FilaFix: 修 Fila 在 Switzach 里一打开就闪退
//
// 闪退原因（FilaCrashLog 抓到的）：
//   NSUnknownKeyException: [<LSApplicationProxy> valueForUndefinedKey:]:
//   this class is not key value coding-compliant for the key signerIdentity.
// Fila 列出已安装 App 时，先用 respondsToSelector: 判断，再用 KVC
// valueForKey: 读取 LSApplicationProxy 的属性。Switzach 扩展过的
// LSApplicationProxy 对某些键声称"响应"，但 KVC 实际读不到，于是抛异常。
//
// 本插件只注入 Fila 和 RootHide Manager：给 LS*Proxy 加一个 valueForUndefinedKey:，
// 读不到的键返回 nil（Fila 本来就把 nil 当作"没有这项信息"）。

#import <Foundation/Foundation.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <string.h>
#include <limits.h>
#include <stdbool.h>
#include <stdio.h>
#include <mach-o/dyld.h>
#include <dlfcn.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include <unistd.h>
#include <CoreFoundation/CoreFoundation.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

static id fila_undefined_key(id self, SEL _cmd, NSString *key)
{
    return nil;
}

/* 未实现的方法：返回 nil/0，而不是 unrecognized selector 崩溃（只在本类上） */
static NSMethodSignature *fix_sig(id self, SEL _cmd, SEL sel)
{
    /* 找到真正装了 fix_sig 的那一层，再调它的父类，避免子类实例无限递归 */
    Class owner = object_getClass(self);
    while (owner && class_getMethodImplementation(class_getSuperclass(owner), _cmd) == (IMP)fix_sig)
        owner = class_getSuperclass(owner);
    struct objc_super sup = { self, class_getSuperclass(owner) };
    NSMethodSignature *sig = ((NSMethodSignature *(*)(struct objc_super *, SEL, SEL))objc_msgSendSuper)(&sup, _cmd, sel);
    if (sig) return sig;
    NSUInteger args = 0;
    for (const char *c = sel_getName(sel); *c; c++) if (*c == ':') args++;
    char types[64] = "@@:";
    for (NSUInteger i = 0; i < args && i < 16; i++) strlcat(types, "@", sizeof(types));
    return [NSMethodSignature signatureWithObjCTypes:types];
}

static void fix_forward(id self, SEL _cmd, NSInvocation *inv)
{
    id nothing = nil;
    if (inv.methodSignature.methodReturnLength == sizeof(id)) [inv setReturnValue:&nothing];
}

static void patch(const char *name)
{
    Class cls = objc_getClass(name);
    if (!cls) return;
    SEL sel = @selector(valueForUndefinedKey:);
    /* 只在这个类自己身上加（不改 NSObject），已有自己的实现就替换 */
    if (!class_addMethod(cls, sel, (IMP)fila_undefined_key, "@@:@")) {
        Method m = class_getInstanceMethod(cls, sel);
        if (m) method_setImplementation(m, (IMP)fila_undefined_key);
    }
    class_addMethod(cls, @selector(methodSignatureForSelector:), (IMP)fix_sig, "@@::");
    class_addMethod(cls, @selector(forwardInvocation:), (IMP)fix_forward, "v@:@");
}


#pragma mark - RootHide Manager: boot-manifest-hash

/* RootHide Manager 启动时读 IODeviceTree:/chosen 的 boot-manifest-hash，
   不检查 NULL 就 CFDataGetLength → Nyxian 里读不到 → 段错误。
   读不到时给它一个 48 字节的全零值（SHA-384 长度），让它走"未知 preboot"分支。 */
typedef mach_port_t io_registry_entry_t;
typedef uint32_t IOOptionBits;
typedef CFTypeRef (*create_prop_fn)(io_registry_entry_t, CFStringRef, CFAllocatorRef, IOOptionBits);
static create_prop_fn g_orig_create_prop;

static CFTypeRef rh_create_property(io_registry_entry_t entry, CFStringRef key,
                                    CFAllocatorRef allocator, IOOptionBits options)
{
    if (!g_orig_create_prop) g_orig_create_prop = (create_prop_fn)dlsym(RTLD_DEFAULT, "IORegistryEntryCreateCFProperty");
    CFTypeRef value = g_orig_create_prop ? g_orig_create_prop(entry, key, allocator, options) : NULL;
    if (value == NULL && key != NULL && CFStringCompare(key, CFSTR("boot-manifest-hash"), 0) == kCFCompareEqualTo) {
        static const UInt8 zeros[48] = {0};
        value = CFDataCreate(kCFAllocatorDefault, zeros, sizeof(zeros));
        fprintf(stderr, "[SwitzachAppFix] boot-manifest-hash unavailable, using placeholder\n");
    }
    return value;
}

static const struct { const char *name; void *replacement; } k_rh_hooks[] = {
    { "_IORegistryEntryCreateCFProperty", (void *)rh_create_property },
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
        for (size_t h = 0; h < sizeof(k_rh_hooks) / sizeof(k_rh_hooks[0]); h++) {
            if (strcmp(name, k_rh_hooks[h].name) != 0) continue;
            void **slot = &slots[i];
            void *replacement = k_rh_hooks[h].replacement;
#if __has_feature(ptrauth_calls)
            replacement = ptrauth_strip(replacement, ptrauth_key_asia);
            replacement = ptrauth_sign_unauthenticated(replacement, ptrauth_key_asia, auth ? (void *)slot : 0);
#else
            (void)auth;
#endif
            uintptr_t page = (uintptr_t)slot & ~(uintptr_t)(getpagesize() - 1);
            if (mprotect((void *)page, (size_t)getpagesize() * 2, PROT_READ | PROT_WRITE) != 0) break;
            *slot = replacement;
            
            break;
        }
    }
}

static void rebind_image(const struct mach_header *header, intptr_t slide)
{
    if (header->magic != MH_MAGIC_64) return;
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


/* NSObject 的 valueForUndefinedKey: 换成：LS*Proxy/Record 返回 nil，其它照旧抛异常。
   这样不管 Switzach 给的是哪个子类都能覆盖到。 */
static IMP g_orig_undefined;
static Class g_ls_classes[8];
static size_t g_ls_count;

static id nsobject_undefined_key(id self, SEL _cmd, NSString *key)
{
    for (size_t i = 0; i < g_ls_count; i++)
        if ([self isKindOfClass:g_ls_classes[i]]) return nil;
    return ((id (*)(id, SEL, NSString *))g_orig_undefined)(self, _cmd, key);
}

static bool exe_is(const char *suffix)
{
    char exe[PATH_MAX];
    uint32_t size = sizeof(exe);
    if (_NSGetExecutablePath(exe, &size) != 0) return false;
    size_t n = strlen(exe), m = strlen(suffix);
    return n >= m && strcmp(exe + n - m, suffix) == 0;
}

__attribute__((constructor))
static void fila_fix_init(void)
{
    /* 不用 NSBundle（Nyxian 里此时可能还是宿主进程的 bundle），看可执行文件路径 */
    if (!exe_is("/Fila.app/Fila") && !exe_is("/RootHide.app/RootHide")) return;

    const char *classes[] = { "LSApplicationProxy", "LSBundleProxy", "LSResourceProxy",
                              "LSPlugInKitProxy", "LSApplicationRecord", "LSBundleRecord" };
    for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) {
        Class cls = objc_getClass(classes[i]);
        if (cls && g_ls_count < 8) g_ls_classes[g_ls_count++] = cls;
        patch(classes[i]);
    }
    Method m = class_getInstanceMethod([NSObject class], @selector(valueForUndefinedKey:));
    if (m) g_orig_undefined = method_setImplementation(m, (IMP)nsobject_undefined_key);
    if (exe_is("/RootHide.app/RootHide")) _dyld_register_func_for_add_image(rebind_image);
    fprintf(stderr, "[SwitzachAppFix] loaded, %zu LS classes, NSObject hook %s\n",
            g_ls_count, g_orig_undefined ? "ok" : "FAILED");
}
