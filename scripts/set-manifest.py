#!/usr/bin/env python3
"""Set the release fields of a generated ROM manifest and add the rootless
bootstrap wiring.

    set-manifest.py MANIFEST VERSION SECURITY_VERSION

Besides NXRomVersion / NXRomSecurityVersion this adds, idempotently:
  - NXRomDataPartitionPath: the writable area that survives flashes, which a
    guest sees as /var/jb (Documents/rootfs is the guest vroot).
  - NXRomInstaller: the Mach-O run once at flash time to lay down /var/jb.
  - an NXRomPaths entry for that installer so it is code-signed.
  - an NXRomPaths entry for `rtpatch`, the /var/jb path layer the ROM's kernel
    installs for every guest process (src/rtpatch), so it is code-signed too.
  - an NXRomPaths entry for nxlaunchd with its Nyxian entitlements.
"""
import plistlib
import sys

# Must match kDataPartitionSuffix in rom-overlay/installer/nxrom_install.m.
DATA_PARTITION = '$(BOOTROOT)/Documents/rootfs/var/jb'
INSTALLER_PATH = 'installer'
RTPATCH_PATH = 'rtpatch'
LAUNCHD_PATH = 'Application/libexec/nxlaunchd'

path, version, security = sys.argv[1], sys.argv[2], int(sys.argv[3])
if security < 1:
    sys.exit('ROM_SECURITY_VERSION must be a positive integer')

with open(path, 'rb') as file:
    manifest = plistlib.load(file)

manifest['NXRomVersion'] = version
manifest['NXRomSecurityVersion'] = security
manifest['NXRomDataPartitionPath'] = DATA_PARTITION
manifest['NXRomInstaller'] = INSTALLER_PATH

paths = manifest.setdefault('NXRomPaths', [])
for signed in (INSTALLER_PATH, RTPATCH_PATH):
    if not any(entry.get('NXPath') == signed for entry in paths):
        paths.append({
            'NXPath': signed,
            'NXPermission': 0o555,
            'NXRequiresCodeSigning': True,
        })

# The service supervisor, started by the ROM's kernel as a launch service. It is
# the first process of everything in /var/jb, so it carries what its children
# need: Nyxian hands a child the parent's entitlements when the parent has
# inherite-entitlements (minus platform, root and sugid, which stay here).
#   platform + platform-root   run as uid 0 (children copy the credentials)
#   process.spawn              start programs, and have Nyxian sign them
#   process.kill / enumeration stop and list services
#   sugid                      UserName / GroupName in a job
if not any(entry.get('NXPath') == LAUNCHD_PATH for entry in paths):
    paths.append({
        'NXPath': LAUNCHD_PATH,
        'NXPermission': 0o555,
        'NXRequiresCodeSigning': True,
        'NXT2Entitlements': {
            'org.emexlabs.nyxian.platform': True,
            'org.emexlabs.nyxian.platform-root': True,
            'org.emexlabs.nyxian.process.spawn': True,
            'org.emexlabs.nyxian.process.spawn.inherite-entitlements': True,
            'org.emexlabs.nyxian.process.kill': True,
            'org.emexlabs.nyxian.process.enumeration': True,
            'org.emexlabs.nyxian.sugid': True,
            'org.emexlabs.nyxian.get-task-allow': False,
        },
    })

with open(path, 'wb') as file:
    plistlib.dump(manifest, file, sort_keys=False)
