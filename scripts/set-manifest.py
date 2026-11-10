#!/usr/bin/env python3
"""Sets the release fields of a generated ROM manifest: set-manifest.py MANIFEST VERSION SECURITY_VERSION"""
import plistlib
import sys

path, version, security = sys.argv[1], sys.argv[2], int(sys.argv[3])
if security < 1:
    sys.exit('ROM_SECURITY_VERSION must be a positive integer')
with open(path, 'rb') as file:
    manifest = plistlib.load(file)
manifest['NXRomVersion'] = version
manifest['NXRomSecurityVersion'] = security
with open(path, 'wb') as file:
    plistlib.dump(manifest, file, sort_keys=False)
