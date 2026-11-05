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
                else:
                    base = n.lstrip("_") if not n.startswith("_OBJC") else n
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sdk", required=True, type=Path)
    parser.add_argument("--swift-stubs", type=Path,
                        help="usr/lib/swift of an SDK that has the Swift runtime's stubs, for an --sdk without them")
    parser.add_argument("--allow", type=Path)
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

    failures = 0
    checked = 0
    for path in args.paths:
        for binary in machos(path):
            checked += 1
            loads = []
            for line in run(["otool", "-L", str(binary)]).splitlines()[1:]:
                m = re.match(r"\s*(\S+)\s+\(", line)
                if m:
                    loads.append((m.group(1), "weak)" in line or ", weak" in line))
            weak_loads = set()
            for install, weak in loads:
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
            for line in run(["nm", "-m", str(binary)]).splitlines():
                m = re.match(r"\s*\(undefined\)\s+(weak\s+)?external\s+(\S+)\s+\(from\s+([^)]+)\)", line)
                if not m:
                    continue
                weak, symbol, short = m.groups()
                if symbol.startswith(("_swift_task_", "_swift_job_", "_swift_continuation_", "_swift_asyncLet", "_swift_taskGroup")):
                    print(f"error: {binary} imports {symbol}: Swift concurrency cannot run on iOS 12")
                    failures += 1
                    continue
                if weak or symbol in allowed:
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
