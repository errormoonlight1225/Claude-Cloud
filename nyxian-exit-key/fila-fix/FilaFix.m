// FilaFix: 修 Fila 在 Switzach 里一打开就闪退
//
// 闪退原因（FilaCrashLog 抓到的）：
//   NSUnknownKeyException: [<LSApplicationProxy> valueForUndefinedKey:]:
//   this class is not key value coding-compliant for the key signerIdentity.
// Fila 列出已安装 App 时，先用 respondsToSelector: 判断，再用 KVC
// valueForKey: 读取 LSApplicationProxy 的属性。Switzach 扩展过的
// LSApplicationProxy 对某些键声称"响应"，但 KVC 实际读不到，于是抛异常。
//
// 本插件只注入 Fila：给 LS*Proxy 加一个 valueForUndefinedKey:，
// 读不到的键返回 nil（Fila 本来就把 nil 当作"没有这项信息"）。

#import <Foundation/Foundation.h>
#include <objc/runtime.h>

static id fila_undefined_key(id self, SEL _cmd, NSString *key)
{
    return nil;
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
}

__attribute__((constructor))
static void fila_fix_init(void)
{
    if (![[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"wiki.qaq.fila"]) return;
    const char *classes[] = { "LSApplicationProxy", "LSBundleProxy", "LSResourceProxy",
                              "LSPlugInKitProxy", "LSApplicationRecord", "LSBundleRecord" };
    for (size_t i = 0; i < sizeof(classes) / sizeof(classes[0]); i++) patch(classes[i]);
}
