#!/usr/bin/env python3
"""Make the Mach-O files of a /var/jb tree loadable from wherever the tree is.

    relocate-macho.py ROOT            rewrite every Mach-O under ROOT in place
    relocate-macho.py ROOT --check    only report what would change
    relocate-macho.py ROOT --verbose  print every rewritten path
    relocate-macho.py ROOT --changed=FILE
                                      write the rewritten files' paths (relative
                                      to ROOT, one per line) to FILE, for signing

ROOT is a directory whose contents are /var/jb (so ROOT/usr/bin/apt is
/var/jb/usr/bin/apt).

Rootless binaries name their libraries by absolute path, for example
/var/jb/usr/lib/libapt-pkg.dylib. The dynamic loader opens those paths itself,
so the path layer (src/rtpatch) never sees them, and inside Nyxian the real
/var/jb does not exist. This rewrites each such load command (and LC_RPATH) to
a path relative to the file that carries it:

    /var/jb/usr/lib/libapt-pkg.dylib  ->  @loader_path/../lib/libapt-pkg.dylib

which the loader resolves on its own, wherever the tree lives. A library's own
install name (LC_ID_DYLIB) is left alone.

Symbolic links get the same treatment: one whose target is an absolute /var/jb
path (usr/bin/sh -> /var/jb/usr/bin/dash) is followed by the real kernel to a
/var/jb that is not there, so it is replaced by a relative link (sh -> dash).

A rewritten file's code signature no longer matches: sign it again afterwards
(ldid -S, then Nyxian signs with your certificate on the device). The exit
status is 0 unless a file could not be rewritten for lack of header space.
"""
import os
import struct
import sys

JB = b'/var/jb'

MH_MAGIC_64 = 0xfeedfacf
MH_MAGIC_32 = 0xfeedface
FAT_MAGIC = 0xcafebabe
FAT_MAGIC_64 = 0xcafebabf

LC_REQ_DYLD = 0x80000000
LC_SEGMENT = 0x1
LC_SEGMENT_64 = 0x19
LC_LOAD_DYLIB = 0xc
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1f | LC_REQ_DYLD
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x23 | LC_REQ_DYLD
LC_RPATH = 0x1c | LC_REQ_DYLD
DYLIB_CMDS = {LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB,
              LC_LAZY_LOAD_DYLIB, LC_LOAD_UPWARD_DYLIB}


def jb_rest(path):
    """The part of an absolute path after /var/jb ('' or b'/...'), else None."""
    if path.startswith(b'/private/var/jb'):
        path = path[len(b'/private'):]
    if not path.startswith(JB):
        return None
    rest = path[len(JB):]
    return rest if rest == b'' or rest.startswith(b'/') else None


def loader_relative(file_rel, target_rest):
    """@loader_path form of /var/jb<target_rest> for the file at ROOT/<file_rel>."""
    here = [c for c in os.path.dirname(file_rel).split(b'/') if c]
    there = [c for c in target_rest.split(b'/') if c]
    common = 0
    while common < len(here) and common < len(there) and here[common] == there[common]:
        common += 1
    parts = [b'..'] * (len(here) - common) + there[common:]
    return b'/'.join([b'@loader_path'] + parts)


def relocate_slice(data, base, file_rel):
    """Rewrite one thin Mach-O at data[base:]. Returns (changes, error)."""
    magic = struct.unpack_from('<I', data, base)[0]
    if magic == MH_MAGIC_64:
        header_size, align = 32, 8
    elif magic == MH_MAGIC_32:
        header_size, align = 28, 4
    else:
        return [], None                      # big-endian or not Mach-O: leave it
    ncmds, sizeofcmds = struct.unpack_from('<II', data, base + 16)

    commands = []                            # (cmd, bytes)
    limit = None                             # file offset of the first section's data
    off = base + header_size
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, off)
        if size < 8 or off + size > base + header_size + sizeofcmds:
            return [], 'malformed load commands'
        body = bytes(data[off:off + size])
        if cmd in (LC_SEGMENT_64, LC_SEGMENT):
            if cmd == LC_SEGMENT_64:
                nsects = struct.unpack_from('<I', body, 64)[0]
                sect0, sect_size, off_at, size_at, size_fmt = 72, 80, 48, 40, '<Q'
            else:
                nsects = struct.unpack_from('<I', body, 48)[0]
                sect0, sect_size, off_at, size_at, size_fmt = 56, 68, 40, 36, '<I'
            for i in range(nsects):
                s = sect0 + i * sect_size
                sec_size = struct.unpack_from(size_fmt, body, s + size_at)[0]
                sec_off = struct.unpack_from('<I', body, s + off_at)[0]
                if sec_off and sec_size and (limit is None or sec_off < limit):
                    limit = sec_off
        commands.append((cmd, body))
        off += size

    changes, out = [], []
    for cmd, body in commands:
        if cmd in DYLIB_CMDS or cmd == LC_RPATH:
            name_at = struct.unpack_from('<I', body, 8)[0]
            old = body[name_at:].split(b'\0', 1)[0]
            rest = jb_rest(old)
            if rest is not None:
                new = loader_relative(file_rel, rest)
                size = (name_at + len(new) + 1 + align - 1) // align * align
                body = (body[:4] + struct.pack('<I', size) + body[8:name_at] + new).ljust(size, b'\0')
                changes.append((old.decode('utf-8', 'replace'), new.decode()))
        out.append(body)
    if not changes:
        return [], None

    blob = b''.join(out)
    if limit is None or header_size + len(blob) > limit:
        return [], 'not enough header space for the longer paths'
    pad = max(sizeofcmds, len(blob))         # also clears what a shorter path leaves behind
    start = base + header_size
    data[start:start + pad] = blob.ljust(pad, b'\0')
    struct.pack_into('<I', data, base + 20, len(blob))
    return changes, None


def relink(path, file_rel, check):
    """Make the symlink at path relative if it points to an absolute /var/jb path."""
    rest = jb_rest(os.readlink(path))
    if rest is None:
        return False
    here = [c for c in os.path.dirname(file_rel).split(b'/') if c]
    there = [c for c in rest.split(b'/') if c]
    common = 0
    while common < len(here) and common < len(there) and here[common] == there[common]:
        common += 1
    target = b'/'.join([b'..'] * (len(here) - common) + there[common:]) or b'.'
    if not check:
        os.unlink(path)
        os.symlink(target, path)
    return True


def slices(data):
    """File offsets of the thin Mach-O images in data."""
    if len(data) < 8:
        return []
    be = struct.unpack_from('>I', data, 0)[0]
    if be in (FAT_MAGIC, FAT_MAGIC_64):
        count = struct.unpack_from('>I', data, 4)[0]
        if count > 64:                       # a Java class file has the same magic
            return []
        entry, fmt = (32, '>Q') if be == FAT_MAGIC_64 else (20, '>I')
        return [struct.unpack_from(fmt, data, 8 + i * entry + 8)[0] for i in range(count)]
    if struct.unpack_from('<I', data, 0)[0] in (MH_MAGIC_64, MH_MAGIC_32):
        return [0]
    return []


def relocate_file(path, file_rel, check):
    with open(path, 'rb') as f:
        head = f.read(4)
        if len(head) < 4:
            return [], None
        little, big = struct.unpack('<I', head)[0], struct.unpack('>I', head)[0]
        if little not in (MH_MAGIC_64, MH_MAGIC_32) and big not in (FAT_MAGIC, FAT_MAGIC_64):
            return [], None
        data = bytearray(head + f.read())
    changes, error = [], None
    for base in slices(data):
        if base + 32 > len(data):
            continue
        c, e = relocate_slice(data, base, file_rel)
        changes += c
        error = error or e
    if changes and not error and not check:
        with open(path, 'r+b') as f:         # in place: hard links stay links
            f.write(data)
    return changes, error


def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    check = '--check' in argv
    verbose = '--verbose' in argv
    changed_list = next((a.split('=', 1)[1] for a in argv[1:] if a.startswith('--changed=')), None)
    rewritten = []
    if len(args) != 1:
        sys.exit(__doc__)
    root = os.fsencode(os.path.abspath(args[0]))
    files = changed = failed = links = 0
    for directory, subdirs, names in os.walk(root):
        for name in names + subdirs:           # a link to a directory is listed with the directories
            path = os.path.join(directory, name)
            rel = os.path.relpath(path, root)
            if os.path.islink(path):
                links += relink(path, rel, check)
                continue
            if not os.path.isfile(path):
                continue
            try:
                changes, error = relocate_file(path, rel, check)
            except (OSError, struct.error) as exc:
                changes, error = [], str(exc)
            if error:
                failed += 1
                print(f'relocate: {os.fsdecode(rel)}: {error}', file=sys.stderr)
            elif changes:
                files += 1
                changed += len(changes)
                rewritten.append(rel)
                if verbose:
                    for old, new in changes:
                        print(f'{os.fsdecode(rel)}: {old} -> {new}')
    if changed_list:
        with open(changed_list, 'wb') as f:
            f.write(b''.join(rel + b'\n' for rel in sorted(rewritten)))
    verb = 'would rewrite' if check else 'rewrote'
    print(f'relocate: {verb} {changed} path(s) in {files} file(s), {failed} failed')
    if links:
        print(f'relocate: {"would make" if check else "made"} {links} symlink(s) relative')
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
