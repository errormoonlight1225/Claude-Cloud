// rootless.m - this ROM's kernel policy for what lives in /var/jb.
//
// scripts/build.sh copies this file into the generated ROM kernel sources
// (rom/src/Rootless), and scripts/patch-rom.py makes the template's home screen
// (NXMainSlot.m) use the two NXJBApplication* functions below.
//
// 1. Apps. A package manager is an app that dpkg installs into
//    /var/jb/Applications. The home screen lists that directory next to the
//    ROM's own Application/, and starts those apps the same way.
//
// 2. Entitlements. Nyxian gives a binary without an entitlement blob an empty
//    identity: it may not start other programs. That is right for a stranger's
//    binary and useless for a package manager, which exists to run dpkg and
//    apt. Files in /var/jb are the user's own installed software, so:
//      - an app in /var/jb/Applications may start, stop and list processes,
//        and what it starts inherits that (process.spawn, inherite-entitlements,
//        process.kill, process.enumeration);
//      - a file with the set-user-ID bit, anywhere in /var/jb, may change its
//        user id (sugid). That is what the bit means on a real system, and how
//        Sileo's giveMeRoot helper and sudo become root. Apps get it too, since
//        Nyxian drops from a child whatever its parent does not hold.
//    Root here is Nyxian's virtual uid 0: it reaches nothing outside the app's
//    container.
//
// The policy is added through the kernel's own patch point for identities (the
// same mechanism Nyxian's kernel extensions use), after the stock rules ran.

#import <Foundation/Foundation.h>
#include <LindChain/ProcEnvironment/Surface/trust/trust.h>
#include <LindChain/ProcEnvironment/Surface/trust/entitlement.h>
#include <LindChain/ProcEnvironment/Surface/libkern/patch.h>
#include <LindChain/ProcEnvironment/Surface/libkern/klog.h>
#include <sys/stat.h>
#include <limits.h>
#include <stdlib.h>

static NSString *NXJBVRoot(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/rootfs"];
}

// The real, resolved location of /var/jb, or nil while it does not exist.
static NSString *NXJBRoot(void)
{
    char real[PATH_MAX];
    NSString *jb = [NXJBVRoot() stringByAppendingPathComponent:@"var/jb"];
    return realpath(jb.fileSystemRepresentation, real) != NULL ? @(real) : nil;
}

#pragma mark - Apps

// The search path of everything this ROM starts. Guests see the real
// filesystem, so Nyxian's own directories are named by their real location;
// the /var/jb entries go through the path layer.
NSString *NXJBSearchPath(void)
{
    NSString *vroot = NXJBVRoot();
    return [NSString stringWithFormat:
        @"/var/jb/usr/local/sbin:/var/jb/usr/local/bin:/var/jb/usr/sbin:/var/jb/usr/bin:/var/jb/sbin:/var/jb/bin:"
        @"%@/usr/bin:%@/usr/sbin:%@/bin:%@/sbin", vroot, vroot, vroot, vroot];
}

// The directories the home screen lists apps from: the ROM's own, then /var/jb's.
NSArray<NSString *> *NXJBApplicationRoots(NSString *romApplications)
{
    NSMutableArray<NSString *> *roots = [NSMutableArray array];
    if(romApplications.length > 0)
    {
        [roots addObject:romApplications];
    }
    NSString *jb = NXJBRoot();
    if(jb != nil)
    {
        [roots addObject:[jb stringByAppendingPathComponent:@"Applications"]];
    }
    return roots;
}

// The environment an app is started with.
NSDictionary<NSString *, NSString *> *NXJBApplicationEnvironment(void)
{
    return @{ @"PATH": NXJBSearchPath() };
}

#pragma mark - Entitlements

static void NXJBGrant(ksurface_trust_identity_t *identity, const char *path)
{
    // Only binaries the stock rules know nothing about: no blob, not a system daemon.
    if(identity->trustLevel != kPETrustLevelFallback || identity->entitlements == NULL)
    {
        return;
    }
    char real[PATH_MAX];
    NSString *root = NXJBRoot();
    if(root == nil || realpath(path, real) == NULL)
    {
        return;
    }
    NSString *file = @(real);
    if(![file hasPrefix:[root stringByAppendingString:@"/"]])
    {
        return;
    }
    NSString *relative = [file substringFromIndex:root.length + 1];

    struct stat sb;
    BOOL setUserID = stat(real, &sb) == 0 && (sb.st_mode & S_ISUID) != 0;
    BOOL app = [relative hasPrefix:@"Applications/"] && [relative containsString:@".app/"];
    if(!app && !setUserID)
    {
        return;
    }

    CFMutableDictionaryRef entitlements = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, identity->entitlements);
    if(entitlements == NULL)
    {
        return;
    }
    CFDictionarySetValue(entitlements, kNXT2EntitlementSUGID, kCFBooleanTrue);
    if(app)
    {
        CFDictionarySetValue(entitlements, kNXT2EntitlementProcessSpawn, kCFBooleanTrue);
        CFDictionarySetValue(entitlements, kNXT2EntitlementProcessSpawnInheriteEntitlements, kCFBooleanTrue);
        CFDictionarySetValue(entitlements, kNXT2EntitlementProcessKill, kCFBooleanTrue);
        CFDictionarySetValue(entitlements, kNXT2EntitlementProcessEnumeration, kCFBooleanTrue);
    }
    CFRelease(identity->entitlements);
    identity->entitlements = entitlements;
}

LIBKERN_PATCH(ksurface_trust_identity_t *, trust_identity_create_from_path_with_parent_identity,
              (const char *path, ksurface_trust_identity_t *parentIdentity),
{
    ksurface_trust_identity_t *identity =
        LIBKERN_ORIG(trust_identity_create_from_path_with_parent_identity)(path, parentIdentity);
    if(identity != NULL && path != NULL)
    {
        NXJBGrant(identity, path);
    }
    return identity;
});

__attribute__((constructor))
static void NXJBInstallPolicy(void)
{
    LIBKERN_INSTALL_PATCH(trust_identity_create_from_path_with_parent_identity);
}
