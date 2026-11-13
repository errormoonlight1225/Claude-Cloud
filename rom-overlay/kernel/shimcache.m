// shimcache.m - this ROM's replacement for the kernel's shim cache step.
//
// On stock Nyxian, ksurface_shimcache_build() compiles the guest runtime patch
// on the device and writes it to $mnt/bootfs/rtpatch; every guest process then
// loads it at startup as $vroot/boot/rtpatch. A ROM host has no compiler, and
// RomGen's template leaves this step empty. This ROM ships the patch prebuilt
// (the slot's `rtpatch`, built from src/rtpatch) and puts it in place here, on
// every boot: bootfs is cleared when it is mounted, and the copy in the slot is
// the one the bootloader keeps signed.
//
// scripts/build.sh copies this file over the generated
// rom/src/LindChain/ProcEnvironment/Surface/cache/shimcache.m.
//
// Boot argument `nxjb_off` (Nyxian > Settings > General > Boot Arguments), or
// `-x`, boots without the patch: the way out if it ever stops guests starting.

#include <LindChain/ProcEnvironment/Surface/cache/shimcache.h>
#include <LindChain/ProcEnvironment/Surface/libkern/patch.h>
#include <LindChain/ProcEnvironment/Surface/libkern/klog.h>
#import <Foundation/Foundation.h>
#include <NXBootArgs.h>
#include <dlfcn.h>
#include <sys/stat.h>

#define NX_BOOT_ARG_JB_OFF "nxjb_off"

static void NXJBAnchor(void) {}

// The ROM slot: the directory this image (the ROM's `main`) was loaded from.
static NSString *NXJBSlotPath(void)
{
    Dl_info info = {0};
    if(dladdr((const void *)&NXJBAnchor, &info) == 0 || info.dli_fname == NULL)
    {
        return nil;
    }
    return [[NSString stringWithUTF8String:info.dli_fname] stringByDeletingLastPathComponent];
}

LIBKERN_DEFINE_PATCHABLE(kern_return_t, ksurface_shimcache_append_code,
                         (CCFileType fileType, const char *code))
{
    (void)fileType;
    (void)code;
    klog_log("shimcache", "guest shim source ignored by ROM host");
    return KERN_SUCCESS;
}

// Never fails: a failure here stops the boot, and a ROM without the patch still
// boots (only /var/jb paths stop resolving).
LIBKERN_DEFINE_PATCHABLE(kern_return_t, ksurface_shimcache_build, (void))
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *installed = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/mntfs/bootfs/rtpatch"];
    [fm removeItemAtPath:installed error:nil];

    char bootArguments[NX_BOOT_ARGS_MAX];
    NXBootArgsCopy(bootArguments, sizeof(bootArguments));
    if(NXBootArgsHasFlag(bootArguments, NX_BOOT_ARG_JB_OFF) ||
       NXBootArgsHasFlag(bootArguments, NX_BOOT_ARG_NO_KEXTS))
    {
        klog_log("shimcache", "rtpatch disabled by boot argument");
        return KERN_SUCCESS;
    }

    NSString *shipped = [NXJBSlotPath() stringByAppendingPathComponent:@"rtpatch"];
    if(shipped == nil || ![fm fileExistsAtPath:shipped])
    {
        klog_log("shimcache", "no rtpatch in the ROM slot; /var/jb paths will not resolve");
        return KERN_SUCCESS;
    }

    NSError *error = nil;
    if(![fm copyItemAtPath:shipped toPath:installed error:&error])
    {
        klog_log("shimcache", "could not install rtpatch: %s",
                 error.localizedDescription.UTF8String ?: "unknown error");
        return KERN_SUCCESS;
    }
    chmod(installed.fileSystemRepresentation, 0555);
    klog_log("shimcache", "rtpatch installed");
    return KERN_SUCCESS;
}
