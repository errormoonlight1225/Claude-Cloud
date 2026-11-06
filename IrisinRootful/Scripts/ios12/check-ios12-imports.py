#!/usr/bin/env python3
"""Fail on anything a binary needs at launch that iOS 12 does not have.

dyld refuses a process whose strong imports the running OS lacks, and a
clean build against a current SDK says nothing about that: the linker
resolves against the current SDK's exports. This reads every non-weak
import of every Mach-O given (with `nm -m`) and checks it against the
exports an iOS 12 SDK's text stubs (.tbd) list for the same library, and
every library a binary loads strongly against what that SDK has at all.

It also fails on any reference to the Swift concurrency runtime
(libswift_Concurrency, swift_task_*): the port must not need it, weakly or
not, since iOS 12 has no such library and the back-deployed one needs 13.

Libraries the SDK does not have (the app's own embedded frameworks, @rpath
loads) are skipped. Symbols in --allow FILE (one per line, # comments) are
accepted without a stub entry.

The iOS 12 SDKs to hand (Xcode 10's) carry no stubs for the Swift runtime
in /usr/lib/swift, which iOS 12.2 ships; --swift-stubs takes them from a
later SDK (iOS 13.0's: Swift 5.1, a superset of 12.2's 5.0, so a 5.1-only
runtime symbol passes here and is the compiler's to back-deploy).

Usage: check-ios12-imports.py --sdk iPhoneOS12.4.sdk [--swift-stubs iPhoneOS13.0.sdk/usr/lib/swift]
                              [--allow FILE] PATH...
       PATH is a Mach-O or a bundle, which is walked. Needs Xcode's nm/otool.
"""

import argparse
import os
import re
import subprocess
import sys
from pathlib import Path


def tbd_exports(path):
    """(install name, exported symbols, re-exported install names)."""
    text = path.read_text(errors="replace")
    install = None
    exports = set()
    reexports = set()
    m = re.search(r"^install-name:\s*'?([^'\n]+)'?", text, re.M)
    if m:
        install = m.group(1).strip()
    # Collect every bracketed list after a known key, across documents.
    for key, items in re.findall(
        r"(symbols|weak-symbols|thread-local-symbols|weak-def-symbols|objc-classes|objc-eh-types|objc-ivars|re-exports|libraries)"
        r":\s*\[(.*?)\]",
        text,
        re.S,
    ):
        names = [n.strip().strip("'\"") for n in items.replace("\n", " ").split(",")]
        names = [n for n in names if n]
        if key == "objc-classes":
            for n in names:
                if n.startswith("_OBJC_CLASS_$_"):
                    exports.add(n)
                    continue
                # A class name may itself start with "_" (_TtCs12_SwiftObject);
                # older stubs also wrote a symbol's leading underscore. Both.
                for base in {n, n[1:] if n.startswith("_") else n}:
                    exports.add(f"_OBJC_CLASS_$_{base}")
                    exports.add(f"_OBJC_METACLASS_$_{base}")
        elif key == "objc-eh-types":
            exports.update(f"_OBJC_EHTYPE_$_{n.lstrip('_')}" for n in names)
        elif key == "objc-ivars":
            exports.update(n if n.startswith("_OBJC_IVAR_$_") else f"_OBJC_IVAR_$_{n.lstrip('_')}" for n in names)
        elif key in ("re-exports", "libraries"):
            reexports.update(names)
        else:
            exports.update(names)
    return install, exports, reexports


def load_sdk(sdk):
    libraries = {}
    for tbd in sdk.rglob("*.tbd"):
        try:
            install, exports, reexports = tbd_exports(tbd)
        except OSError:
            continue
        if install:
            entry = libraries.setdefault(install, [set(), set()])
            entry[0] |= exports
            entry[1] |= reexports
    # fold re-exported libraries into their umbrella, a few levels deep
    for _ in range(3):
        for install, (exports, reexports) in libraries.items():
            for child in list(reexports):
                if child in libraries:
                    exports |= libraries[child][0]
    return libraries


def machos(path):
    if path.is_file():
        yield path
        return
    for candidate in path.rglob("*"):
        if candidate.is_file() and not candidate.is_symlink():
            with candidate.open("rb") as f:
                magic = f.read(4)
            if magic in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xfe\xed\xfa\xcf", b"\xbe\xba\xfe\xca"):
                yield candidate


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, check=False).stdout


# Xcode's tools by default; LLVM's stand in elsewhere (OTOOL="llvm-objdump
# --macho --dylibs-used", OTOOL_ID="llvm-objdump --macho --dylib-id",
# NM="llvm-nm", OBJDUMP="llvm-objdump").
OTOOL = os.environ.get("OTOOL", "otool -L").split()
OTOOL_ID = os.environ.get("OTOOL_ID", "otool -D").split()
NM = os.environ.get("NM", "nm").split()
OBJDUMP = os.environ.get("OBJDUMP", "objdump").split()


def own_install_name(binary):
    """A dylib's LC_ID_DYLIB, which otool -L lists first among its loads."""
    lines = run([*OTOOL_ID, str(binary)]).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def bind_weak_imports(binary):
    """Symbols the dyld bind information imports weakly. dyld binds by this,
    not by the symbol table, and a binary whose header says
    NLIST_OUTOFSYNC_WITH_DYLDINFO (WCDBSwift, built for 12.0) has weak
    imports the symbol table still lists as strong."""
    weak = set()
    for line in run([*OBJDUMP, "--macho", "--bind", str(binary)]).splitlines():
        if "(weak_import)" in line:
            fields = line.replace("(weak_import)", "").split()
            if fields:
                weak.add(fields[-1])
    return weak


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", required=True, type=Path)
    parser.add_argument("--swift-stubs", type=Path,
                        help="usr/lib/swift of an SDK that has the Swift runtime's stubs, for an --sdk without them")
    parser.add_argument("--allow", type=Path)
    parser.add_argument("--weak-concurrency-ok", action="append", default=[], metavar="NAME",
                        help="a binary (by file name) allowed to load libswift_Concurrency weakly and import "
                             "from it, for a dependency's async code the binary never runs")
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()

    allowed = set()
    if args.allow and args.allow.exists():
        for line in args.allow.read_text().splitlines():
            line = line.split("#", 1)[0].strip()
            if line:
                allowed.add(line)

    libraries = load_sdk(args.sdk)
    if args.swift_stubs:
        for install, entry in load_sdk(args.swift_stubs).items():
            if install.startswith("/usr/lib/swift/") and install not in libraries:
                libraries[install] = entry
    if not libraries:
        print(f"error: no .tbd stubs under {args.sdk}", file=sys.stderr)
        return 66
    by_short = {}
    for install in libraries:
        name = Path(install).name
        short = re.sub(r"\.dylib$", "", name)
        by_short.setdefault(short, install)
        # nm names a versioned library without its version: libSystem for
        # libSystem.B.dylib, libc++ for libc++.1.dylib, libobjc for libobjc.A
        by_short.setdefault(short.split(".")[0], install)

    failures = 0
    checked = 0
    for path in args.paths:
        for binary in machos(path):
            checked += 1
            loads = []
            own = own_install_name(binary)
            for line in run([*OTOOL, str(binary)]).splitlines()[1:]:
                m = re.match(r"\s*(.+?)\s+\(compatibility", line)
                if m and m.group(1) != own:
                    loads.append((m.group(1), "weak)" in line or ", weak" in line))
            bound_weak = bind_weak_imports(binary)
            weak_loads = set()
            concurrency_ok = binary.name in args.weak_concurrency_ok
            for install, weak in loads:
                if "libswift_Concurrency" in install and weak and concurrency_ok:
                    print(f"note: {binary} loads {install} weakly (allowed): missing on iOS 12, its imports bind to NULL")
                    weak_loads.add(install)
                    continue
                if "libswift_Concurrency" in install:
                    print(f"error: {binary} loads {install}{' (weak)' if weak else ''}: Swift concurrency cannot run on iOS 12")
                    failures += 1
                if weak:
                    weak_loads.add(install)
                    continue
                if install.startswith(("@rpath", "@executable_path", "@loader_path")):
                    continue
                if install not in libraries:
                    print(f"error: {binary} loads {install} strongly; the iOS 12 SDK has no such library")
                    failures += 1
            # A lazily bound import is resolved on its first call rather
            # than at launch, and aborts the process there all the same.
            for line in run([*NM, "-m", str(binary)]).splitlines():
                m = re.match(r"\s*\(undefined(?: \[lazy bound\])?\)\s+(weak\s+)?external\s+(\S+)\s+\(from\s+([^)]+)\)", line)
                if not m:
                    continue
                weak, symbol, short = m.groups()
                if symbol.startswith(("_swift_task_", "_swift_job_", "_swift_continuation_", "_swift_asyncLet", "_swift_taskGroup")) \
                        and not (concurrency_ok and short == "libswift_Concurrency"):
                    print(f"error: {binary} imports {symbol}: Swift concurrency cannot run on iOS 12")
                    failures += 1
                    continue
                if weak or symbol in allowed or symbol in bound_weak:
                    continue
                install = by_short.get(short)
                if install is None or install in weak_loads:
                    continue  # an embedded library, or one loaded weakly
                if symbol not in libraries[install][0]:
                    print(f"error: {binary} imports {symbol} from {short}; iOS 12 does not export it")
                    failures += 1
    if checked == 0:
        print("error: no Mach-O binaries found", file=sys.stderr)
        return 66
    if failures:
        print(f"error: {failures} import(s) iOS 12 cannot satisfy", file=sys.stderr)
        return 65
    print(f"ok: {checked} binaries import only what iOS 12 exports")
    return 0


if __name__ == "__main__":
    sys.exit(main())
