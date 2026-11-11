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

__attribute__((constructor))
static void fila_fix_init(void)
{
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (![bid isEqualToString:@"wiki.qaq.fila"] && ![bid isEqualToString:@"com.roothide.manager"]) return;
    const char *classes[] = { "LSApplicationProxy", "LSBundleProxy", "LSResourceProxy",
                              "LSPlugInKitProxy", "LSApplicationRecord", "LSBundleRecord" };
    for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) patch(classes[i]);
}
