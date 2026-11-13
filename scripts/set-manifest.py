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
"""
import plistlib
import sys

# Must match kDataPartitionSuffix in rom-overlay/installer/nxrom_install.m.
DATA_PARTITION = '$(BOOTROOT)/Documents/rootfs/var/jb'
INSTALLER_PATH = 'installer'
RTPATCH_PATH = 'rtpatch'

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

with open(path, 'wb') as file:
    plistlib.dump(manifest, file, sort_keys=False)
