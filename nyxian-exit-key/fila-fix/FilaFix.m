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
    fprintf(stderr, "[SwitzachAppFix] loaded, %zu LS classes, NSObject hook %s\n",
            g_ls_count, g_orig_undefined ? "ok" : "FAILED");
}
