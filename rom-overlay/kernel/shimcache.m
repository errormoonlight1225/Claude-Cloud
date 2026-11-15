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
// The same step also registers this ROM's service supervisor (nxlaunchd, in the
// slot at Application/libexec) as a Nyxian launch service: the kernel reads
// $mnt/lsfs/*.plist right after this function returns and starts what it finds.
// nxlaunchd then starts everything in /var/jb/Library/LaunchDaemons.
//
// Boot argument `nxjb_off` (Nyxian > Settings > General > Boot Arguments), or
// `-x`, boots without the patch and without nxlaunchd: the way out if either
// ever stops the ROM starting.

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

// The slot's Application directory as guests may read it (defined in the ROM's
// fs.m by RomGen; it is the only part of the slot guests get a read token for).
extern NSString *NXROMApplicationSourcePath(void);

#define NX_LAUNCHD_SERVICE @"rootless.nxlaunchd"

// Writes (or, when off, removes) the launch service entry for nxlaunchd.
static void NXJBInstallLaunchService(BOOL enabled)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *entry = [NSHomeDirectory() stringByAppendingPathComponent:
                       @"Documents/mntfs/lsfs/" NX_LAUNCHD_SERVICE @".plist"];
    [fm removeItemAtPath:entry error:nil];
    if(!enabled)
    {
        return;
    }

    NSString *executable = [NXROMApplicationSourcePath() stringByAppendingPathComponent:@"libexec/nxlaunchd"];
    if(executable == nil || ![fm fileExistsAtPath:executable])
    {
        klog_log("shimcache", "no nxlaunchd in the ROM slot; /var/jb services will not start");
        return;
    }

    // Guests see the real filesystem, so the search path names the real vroot
    // for Nyxian's own directories; the /var/jb entries go through the path layer.
    NSString *vroot = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/rootfs"];
    NSString *path = [NSString stringWithFormat:
        @"/var/jb/usr/local/sbin:/var/jb/usr/local/bin:/var/jb/usr/sbin:/var/jb/usr/bin:/var/jb/sbin:/var/jb/bin:"
        @"%@/usr/bin:%@/usr/sbin:%@/bin:%@/sbin", vroot, vroot, vroot, vroot];
    NSDictionary *service = @{
        @"PEServiceIdentifier": NX_LAUNCHD_SERVICE,
        @"PEExecutablePath": executable,
        @"PEArguments": @[ executable ],
        @"PEWorkingDirectory": vroot,
        @"PEEnvironment": @{ @"PATH": path },
        @"PEShouldAutorestart": @YES,
        @"PEEnabled": @YES,
    };
    if(![service writeToFile:entry atomically:YES])
    {
        klog_log("shimcache", "could not register nxlaunchd as a launch service");
        return;
    }
    klog_log("shimcache", "nxlaunchd registered as a launch service");
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
        klog_log("shimcache", "rtpatch and nxlaunchd disabled by boot argument");
        NXJBInstallLaunchService(NO);
        return KERN_SUCCESS;
    }
    NXJBInstallLaunchService(YES);

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
