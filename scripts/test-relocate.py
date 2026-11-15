#!/usr/bin/env python3
"""Test for relocate-macho.py on Mach-O files made up here (runs on any OS).

    test-relocate.py                       tests scripts/relocate-macho.py
    test-relocate.py --tool "CMD ARGS"     the same checks against another tool
                                           that takes ROOT [--check] [--verbose]
    test-relocate.py --signing-tool CMD    also tests nxfixup's signing and
                                           stamps (CMD is built with the fake
                                           signer, src/fixup/test)
"""
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
LC_SEGMENT_64, LC_LOAD_DYLIB, LC_ID_DYLIB, LC_RPATH = 0x19, 0xc, 0xd, 0x8000001c


def dylib_cmd(cmd, name):
    size = (24 + len(name) + 1 + 7) // 8 * 8
    return (struct.pack('<IIIIII', cmd, size, 24, 2, 0x10000, 0x10000) + name).ljust(size, b'\0')


def rpath_cmd(path):
    size = (12 + len(path) + 1 + 7) // 8 * 8
    return (struct.pack('<III', LC_RPATH, size, 12) + path).ljust(size, b'\0')


def macho(cmds, text_offset=0x1000):
    section = struct.pack('<16s16sQQIIIIIIII', b'__text', b'__TEXT', 0x100001000, 16,
                          text_offset, 2, 0, 0, 0x80000400, 0, 0, 0)
    segment = struct.pack('<II16sQQQQIIII', LC_SEGMENT_64, 72 + 80, b'__TEXT', 0x100000000,
                          0x4000, 0, 0x4000, 5, 5, 1, 0) + section
    cmds = [segment] + cmds
    blob = b''.join(cmds)
    header = struct.pack('<IIIIIIII', 0xfeedfacf, 0x0100000c, 0, 2, len(cmds), len(blob), 0, 0)
    return (header + blob).ljust(text_offset, b'\0') + b'\xc0\x03\x5f\xd6' * 4


def load_names(data, base=0):
    names, off = [], base + 32
    ncmds = struct.unpack_from('<I', data, base + 16)[0]
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, off)
        if cmd in (LC_LOAD_DYLIB, LC_ID_DYLIB, LC_RPATH):
            at = struct.unpack_from('<I', data, off + 8)[0]
            names.append(data[off + at:off + size].split(b'\0', 1)[0].decode())
        off += size
    assert off == base + 32 + struct.unpack_from('<I', data, base + 20)[0], 'sizeofcmds'
    return names


def option(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None


TOOL = (option('--tool') or '').split() or [sys.executable, '-I', os.path.join(HERE, 'relocate-macho.py')]
SIGNING_TOOL = (option('--signing-tool') or '').split()


def run(root, *flags, tool=None, env=None, after=()):
    return subprocess.run([*(tool or TOOL), *flags, root, *after], capture_output=True, text=True,
                          env={**os.environ, **(env or {})})


def write(root, rel, data):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)
    return path


with tempfile.TemporaryDirectory() as root:
    apt = write(root, 'usr/bin/apt', macho([
        dylib_cmd(LC_LOAD_DYLIB, b'/var/jb/usr/lib/libapt-pkg.6.0.dylib'),
        dylib_cmd(LC_LOAD_DYLIB, b'/usr/lib/libSystem.B.dylib'),
        dylib_cmd(LC_LOAD_DYLIB, b'/private/var/jb/usr/lib/libiosexec.1.dylib'),
        rpath_cmd(b'/var/jb/usr/lib'),
        dylib_cmd(LC_LOAD_DYLIB, b'/var/jbfoo/not-ours.dylib'),
    ]))
    lib = write(root, 'usr/lib/libapt-pkg.6.0.dylib', macho([
        dylib_cmd(LC_ID_DYLIB, b'/var/jb/usr/lib/libapt-pkg.6.0.dylib'),
        dylib_cmd(LC_LOAD_DYLIB, b'/var/jb/usr/lib/libz.dylib'),
        dylib_cmd(LC_LOAD_DYLIB, b'/var/jb/usr/libexec/deep/dir/libx.dylib'),
    ]))
    thin = macho([dylib_cmd(LC_LOAD_DYLIB, b'/var/jb/usr/lib/liba.dylib')])
    fat = (struct.pack('>IIIIIII', 0xcafebabe, 1, 0x0100000c, 0, 0x4000, len(thin), 14)
           .ljust(0x4000, b'\0') + thin)
    fatpath = write(root, 'Applications/X.app/X', fat)
    tight = write(root, 'usr/bin/tight', macho(
        [dylib_cmd(LC_LOAD_DYLIB, b'/var/jb/usr/lib/libz.dylib')], text_offset=32 + 152 + 48))
    text = write(root, 'etc/readme', b'/var/jb/usr/lib/libz.dylib is only text here\n')
    before_tight = open(tight, 'rb').read()
    links = {'usr/bin/sh': '/var/jb/usr/bin/dash', 'bin/cat': '/var/jb/usr/bin/cat',
             'var/lib/dpkg': '/var/jb/Library/dpkg', 'usr/bin/rel': 'apt', 'usr/bin/out': '/etc/passwd'}
    if not option('--tool'):                   # the packing tool also makes links relative
        os.makedirs(os.path.join(root, 'bin')), os.makedirs(os.path.join(root, 'var/lib')), os.makedirs(os.path.join(root, 'Library/dpkg'))
        for link, target in links.items():
            os.symlink(target, os.path.join(root, link))

    r = run(root, '--check')
    assert 'would rewrite 6 path(s) in 3 file(s), 1 failed' in r.stdout, r.stdout + r.stderr
    assert load_names(open(apt, 'rb').read())[0].startswith('/var/jb'), '--check must not write'

    r = run(root, '--verbose')
    assert r.returncode == 1 and 'rewrote 6 path(s) in 3 file(s), 1 failed' in r.stdout, r.stdout + r.stderr
    assert 'usr/bin/tight: not enough header space' in r.stderr, r.stderr

    data = open(apt, 'rb').read()
    assert load_names(data) == [
        '@loader_path/../lib/libapt-pkg.6.0.dylib', '/usr/lib/libSystem.B.dylib',
        '@loader_path/../lib/libiosexec.1.dylib', '@loader_path/../lib',
        '/var/jbfoo/not-ours.dylib'], load_names(data)
    assert data[0x1000:] == b'\xc0\x03\x5f\xd6' * 4 and len(data) == 0x1010, 'code moved'
    assert load_names(open(lib, 'rb').read()) == [
        '/var/jb/usr/lib/libapt-pkg.6.0.dylib', '@loader_path/libz.dylib',
        '@loader_path/../libexec/deep/dir/libx.dylib']
    assert load_names(open(fatpath, 'rb').read(), 0x4000) == ['@loader_path/../../usr/lib/liba.dylib']
    assert open(tight, 'rb').read() == before_tight, 'a file that does not fit is left alone'
    assert open(text, 'rb').read().startswith(b'/var/jb'), 'only Mach-O files are touched'
    if not option('--tool'):
        assert 'made 3 symlink(s) relative' in r.stdout, r.stdout
        got = {link: os.readlink(os.path.join(root, link)) for link in links}
        assert got == {'usr/bin/sh': 'dash', 'bin/cat': '../usr/bin/cat', 'var/lib/dpkg': '../../Library/dpkg',
                       'usr/bin/rel': 'apt', 'usr/bin/out': '/etc/passwd'}, got
        assert os.path.isdir(os.path.join(root, 'var/lib/dpkg')), 'the relative link resolves'

    r = run(root)
    assert 'rewrote 0 path(s) in 0 file(s), 1 failed' in r.stdout, 'second run changes nothing'

    if SIGNING_TOOL:
        log = os.path.join(root, 'sign.log')
        env = {'NXFIXUP_SIGN_LOG': log}

        def signed(result):
            assert 'failed' in result.stdout, result.stdout + result.stderr
            line = [l for l in result.stdout.splitlines() if l.startswith('sign: ')]
            assert line, result.stdout + result.stderr
            return line[0]

        # everything above ran without signing, so no stamp exists yet: all three
        # good files are signed now; the one that cannot be relocated is not
        r = run(root, tool=SIGNING_TOOL, env=env)
        assert signed(r) == 'sign: signed 3 file(s), 0 failed', r.stdout + r.stderr
        assert len(open(log).read().splitlines()) == 3 and open(log).read().startswith('761 ')
        assert os.path.exists(os.path.join(root, 'var/lib/nxfixup/stamps'))
        r = run(root, tool=SIGNING_TOOL, env=env)
        assert signed(r) == 'sign: signed 0 file(s), 0 failed', 'stamped files are skipped'
        os.utime(apt, ns=(1, 1))
        r = run(root, tool=SIGNING_TOOL, env=env)
        assert signed(r) == 'sign: signed 1 file(s), 0 failed', 'a changed file is done again'
        r = run(root, '--all', tool=SIGNING_TOOL, env=env)
        assert signed(r) == 'sign: signed 3 file(s), 0 failed', '--all ignores the stamps'
        r = run(root, '--all', tool=SIGNING_TOOL, env={**env, 'NXFIXUP_SIGN_FAIL': '1'})
        assert signed(r) == 'sign: signed 0 file(s), 3 failed' and r.returncode == 1
        r = run(root, tool=SIGNING_TOOL, env=env)
        assert signed(r) == 'sign: signed 3 file(s), 0 failed', 'a failed signing is tried again'
        # --then: the named program takes over afterwards, if it exists
        marker = os.path.join(root, 'then-ran')
        then = write(root, 'then.sh', b'#!/bin/sh\necho "$1" > "$2"\nexit 3\n')
        os.chmod(then, 0o755)
        r = run(root, tool=SIGNING_TOOL, env=env, after=['--then', then, 'hello', marker])
        assert r.returncode == 3 and open(marker).read() == 'hello\n', r.stdout + r.stderr
        r = run(root, tool=SIGNING_TOOL, env=env, after=['--then', os.path.join(root, 'missing')])
        # (1 is nxfixup's own status here: one file of this tree cannot be relocated)
        assert r.returncode == 1 and 'missing' not in r.stderr, 'a --then program that does not exist is skipped'
        os.remove(then), os.remove(marker)
        # outside Nyxian (no signer) the tool says so and does not stamp anything
        os.remove(os.path.join(root, 'var/lib/nxfixup/stamps'))
        r = run(root, tool=[SIGNING_TOOL[0].replace('-signer', '')])
        assert r.returncode == 1 and 'not running inside Nyxian' in r.stderr, r.stderr
        assert open(os.path.join(root, 'var/lib/nxfixup/stamps')).read() == ''

print('ok: ' + ' '.join(os.path.basename(t) for t in TOOL[-2:]) + (' + signing' if SIGNING_TOOL else ''))
