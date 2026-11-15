#!/usr/bin/env python3
"""Adapt the generated ROM kernel sources to this ROM.

    patch-rom.py ROM_SRC      (the generated rom/src directory)

The template's home screen (NXMainSlot.m) lists and starts the apps in the
ROM's own Application/ directory. This makes it also list the apps dpkg
installs into /var/jb/Applications, and start every app with a PATH. The
functions it calls are in rom-overlay/kernel/rootless.m.

Every edit must match exactly once: if the template changes upstream, the build
stops here instead of producing a ROM that silently lacks the change.
"""
import sys
from pathlib import Path

EDITS = [
    # declarations
    ('extern NSString *NXROMApplicationSourcePath(void);\n',
     'extern NSString *NXROMApplicationSourcePath(void);\n'
     'extern NSArray<NSString *> *NXJBApplicationRoots(NSString *romApplications);\n'
     'extern NSDictionary<NSString *, NSString *> *NXJBApplicationEnvironment(void);\n'),
    # list the apps of every root, not only the ROM's
    ('    for(NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:applications error:nil])\n',
     '    NSString *romApplications = applications;\n'
     '    for(NSString *applications in NXJBApplicationRoots(romApplications))\n'
     '    for(NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:applications error:nil])\n'),
    # start apps with a search path
    ('        @"PEEnvironment": @{},\n',
     '        @"PEEnvironment": NXJBApplicationEnvironment(),\n'),
]

path = Path(sys.argv[1]) / 'NXMainSlot.m'
text = path.read_text()
for old, new in EDITS:
    if new in text:
        continue                      # already applied
    if text.count(old) != 1:
        sys.exit(f'patch-rom: {path.name}: expected exactly one match for:\n{old}')
    text = text.replace(old, new)
path.write_text(text)
print(f'patch-rom: {path.name} lists and starts the apps in /var/jb/Applications')
