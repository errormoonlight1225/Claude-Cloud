// ___chkstk_darwin is libSystem's stack probe from iOS 13 on. Swift 6's code
// generator calls it for every runtime-sized value it puts on the stack (a
// generic or resilient type's alloca) whatever the deployment target, and
// binds it at launch, so on iOS 12 dyld refused to start any binary carrying
// such a call ("Symbol not found: ___chkstk_darwin").
//
// Defined here, the static linker binds those calls to this copy instead of
// libSystem's. The probe touches each page below the stack pointer so that
// an allocation larger than the guard page faults on it; these allocations
// are a few hundred bytes, inside the page the stack already has, so the
// copy returns at once and changes no register, as the caller requires.
#if defined(__APPLE__) && defined(__aarch64__)
__asm__(
    ".text\n"
    ".globl ___chkstk_darwin\n"
    ".private_extern ___chkstk_darwin\n"
    ".p2align 2\n"
    "___chkstk_darwin:\n"
    "    ret\n");
#endif
