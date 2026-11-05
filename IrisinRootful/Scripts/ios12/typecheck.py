#!/usr/bin/env python3
"""Type-check every Swift module of the iOS 12 rootful port on Linux.

This is a development aid, not the build: the shipping binaries are built by
Xcode on macOS (see .github/workflows). It runs the open-source Swift
compiler with `-target arm64-apple-ios12.0` against an iPhoneOS SDK, module
by module in dependency order, so every use of an API iOS 12 does not have is
reported without a Mac.

Environment:
  SWIFTC      swiftc wrapper that already passes -target/-sdk/-resource-dir
              (the wrapper used here: Swift 6.3.3 for Linux, iPhoneOS26.5.sdk,
              -target arm64e-apple-ios12.0)
              (default /opt/ios/swiftc-ios)
  IOS_DEPS    checkouts of the unmodified third-party packages
              (default /opt/ios/deps)
  IOS_BIN     unpacked binary xcframeworks (default /opt/ios/bin)
  OUT         build directory (default /tmp/irisin-ios12-check)

Each module is also linted for Swift concurrency left in its sources
(MODULE.lint beside the log): iOS 12 cannot run any of it.

Usage: typecheck.py [MODULE ...]   (no argument: every module)
       typecheck.py --list
       typecheck.py --from MODULE  (MODULE and everything after it)
"""

import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SWIFTC = os.environ.get("SWIFTC", "/opt/ios/swiftc-ios")
DEPS = Path(os.environ.get("IOS_DEPS", "/opt/ios/deps"))
BIN = Path(os.environ.get("IOS_BIN", "/opt/ios/bin"))
OUT = Path(os.environ.get("OUT", "/tmp/irisin-ios12-check"))
V = ROOT / "Vendor"
P = ROOT / "Packages"

# Clang modules: name -> module map file (generated when given as a dir).
CLANG = {
    "cmark_gfm": DEPS / "swift-cmark/src/include/module.modulemap",
    "cmark_gfm_extensions": DEPS / "swift-cmark/extensions/include/module.modulemap",
    "SDWebImage": ("umbrella-header", DEPS / "SDWebImage/SDWebImage/include/SDWebImage/SDWebImage.h",
                   DEPS / "SDWebImage/SDWebImage/include"),
    "CIrisinXPC": P / "IrisinKit/Sources/CIrisinXPC/module.modulemap",
    "CIrisinSpawn": P / "IrisinKit/Sources/CIrisinSpawn/module.modulemap",
    "CIrisinDB": P / "IrisinKit/Sources/CIrisinDB/module.modulemap",
    "IcliSystemPrivate": ("umbrella-header", V / "icli/Sources/IcliSystemPrivate/include/IcliSystemPrivate.h"),
    "IcliLaunchPrivate": ("umbrella-header", V / "icli/Sources/IcliLaunchPrivate/include/IcliLaunchPrivate.h"),
    "IcliPrivate": ("umbrella-header", V / "icli/Sources/IcliPrivate/include/IcliPrivate.h"),
    "IcliProbe": ("umbrella-header", V / "icli/Sources/IcliProbe/include/IcliProbe.h"),
    "COpenCombineHelpers": ("umbrella-header", V / "OpenCombine/Sources/COpenCombineHelpers/include/COpenCombineHelpers.h"),
}

FRAMEWORK_DIRS = [
    BIN / "CLibSolv.xcframework/ios-arm64_arm64e",
    BIN / "libarchive.xcframework/ios-arm64_arm64e",
    BIN / "WCDBSwift.xcframework/ios-arm64",
    BIN / "WCDBObjc.xcframework/ios-arm64",
]


def M(name, sources, deps=(), resources=False, executable=False, flags=(), exclude=()):
    return dict(name=name, sources=sources, deps=list(deps), resources=resources,
                executable=executable, flags=list(flags), exclude=list(exclude))


# Swift modules in dependency order.
MODULES = [
    # Third party, unmodified.
    M("Then", [DEPS / "Then/Sources/Then"]),
    M("SPIndicator", [V / "SPIndicator/Sources/SPIndicator"], flags=["-DSPINDICATOR_SPM"]),
    M("InternalCollectionsUtilities", [DEPS / "swift-collections/Sources/InternalCollectionsUtilities"]),
    M("OrderedCollections", [DEPS / "swift-collections/Sources/OrderedCollections"], ["InternalCollectionsUtilities"]),
    M("DequeModule", [DEPS / "swift-collections/Sources/DequeModule"], ["InternalCollectionsUtilities"]),
    M("ArgumentParserToolInfo", [DEPS / "swift-argument-parser/Sources/ArgumentParserToolInfo"]),
    M("ArgumentParser", [DEPS / "swift-argument-parser/Sources/ArgumentParser"], ["ArgumentParserToolInfo"]),
    M("LibSolv", [DEPS / "libsolv.xcframework/Sources/LibSolv"]),
    M("ArchiveKit", [DEPS / "libarchive.xcframework/Sources/ArchiveKit"]),
    # Third party, vendored and ported.
    M("LegacyCompat", [V / "LegacyCompat/Sources/LegacyCompat"]),
    M("LegacyCrypto", [V / "LegacyCompat/Sources/LegacyCrypto"]),
    M("SnapKit", [V / "SnapKit/Sources"]),
    M("OpenCombine", [V / "OpenCombine/Sources/OpenCombine"], ["COpenCombineHelpers"]),
    M("OpenCombineDispatch", [V / "OpenCombine/Sources/OpenCombineDispatch"], ["OpenCombine"]),
    M("OpenCombineFoundation", [V / "OpenCombine/Sources/OpenCombineFoundation"], ["OpenCombine", "COpenCombineHelpers"]),
    M("LRUCache", [V / "LRUCache/Sources"]),
    M("Dog", [V / "Dog/Sources/Dog"]),
    M("DisplayLink", [V / "DisplayLink/Sources/DisplayLink"]),
    M("AlertController", [V / "AlertController/Sources/AlertController"], ["SnapKit", "LegacyCompat"], resources=True),
    M("Litext", [V / "Litext/Sources/Litext"], resources=True),
    M("LitextAnimation", [V / "Litext/Sources/LitextAnimation"], ["Litext", "DisplayLink"]),
    M("IcliSystem", [V / "icli/Sources/IcliSystem"], ["IcliSystemPrivate"]),
    M("IcliLaunch", [V / "icli/Sources/IcliLaunch"], ["IcliLaunchPrivate", "IcliSystem"]),
    M("IcliKit", [V / "icli/Sources/IcliKit"],
      ["IcliPrivate", "IcliSystem", "IcliLaunch", "IcliProbe", "ArchiveKit", "LegacyCompat"]),
    # First party packages.
    M("IrisinProtocol", [P / "IrisinKit/Sources/IrisinProtocol"], ["CIrisinXPC", "CIrisinSpawn", "LegacyCompat", "LegacyCrypto"]),
    M("IrisinPreparation", [P / "IrisinKit/Sources/IrisinPreparation"], ["IrisinProtocol", "ArchiveKit", "LegacyCompat", "LegacyCrypto"]),
    M("IrisinInstaller", [P / "IrisinKit/Sources/IrisinInstaller"],
      ["CIrisinDB", "IrisinProtocol", "IrisinPreparation", "IcliKit", "LegacyCompat", "LegacyCrypto"]),
    M("IrisinClient", [P / "IrisinKit/Sources/IrisinClient"], ["IrisinProtocol", "IrisinInstaller", "LegacyCompat", "LegacyCrypto"]),
    M("IrisinVendor", [P / "IrisinKit/Sources/IrisinVendor"], ["LegacyCompat", "LegacyCrypto"]),
    M("AptRepository", [P / "AptRepository/Sources/AptRepository"],
      ["ArchiveKit", "IrisinProtocol", "IrisinPreparation", "WCDBSwift", "LRUCache", "OpenCombine", "OpenCombineDispatch", "LegacyCompat", "LegacyCrypto"]),
    M("AptResolver", [P / "AptRepository/Sources/AptResolver"], ["AptRepository", "LibSolv", "IrisinProtocol", "OpenCombine", "LegacyCompat", "LegacyCrypto"]),
    M("MarkdownParser", [P / "MarkdownView/Sources/MarkdownParser"], ["cmark_gfm", "cmark_gfm_extensions", "LegacyCompat", "LegacyCrypto"]),
    M("MarkdownView", [P / "MarkdownView/Sources/MarkdownView"], ["Litext", "MarkdownParser", "LRUCache", "DequeModule", "OpenCombine", "OpenCombineDispatch", "LegacyCompat"]),
    M("PackageDepiction", [P / "PackageDepiction/Sources/PackageDepiction"],
      ["SDWebImage", "MarkdownView", "SnapKit", "Then", "LegacyCompat", "LegacyCrypto"], resources=True),
    # Products.
    M("irisind", [ROOT / "IrisinDaemon"], ["IrisinProtocol"], executable=True),
    M("irisin_install", [ROOT / "IrisinInstall"], ["IrisinProtocol", "IrisinInstaller", "LegacyCompat", "LegacyCrypto"], executable=True),
    M("irisin_cli", [ROOT / "IrisinCLI"],
      ["IrisinProtocol", "IrisinClient", "IrisinVendor", "AptRepository", "AptResolver", "ArgumentParser", "LegacyCompat", "LegacyCrypto"],
      executable=True),
    M("Irisin", [ROOT / "Irisin", ROOT / "IrisinShared"],
      ["IrisinProtocol", "IrisinClient", "IrisinVendor", "AptRepository", "AptResolver", "Dog",
       "PackageDepiction", "SnapKit", "SDWebImage", "SPIndicator", "LitextAnimation", "AlertController",
       "Then", "OrderedCollections", "OpenCombine", "OpenCombineDispatch", "OpenCombineFoundation",
       "LegacyCompat", "LegacyCrypto"],
      executable=True),
]

BY_NAME = {m["name"]: m for m in MODULES}


def modulemap_flags():
    gen = OUT / "modulemaps"
    gen.mkdir(parents=True, exist_ok=True)
    flags = []
    for name, spec in CLANG.items():
        if isinstance(spec, tuple):
            kind, path = spec[0], spec[1]
            if len(spec) > 2:
                flags += ["-Xcc", f"-I{spec[2]}"]
            body = (f'umbrella header "{path}"' if kind == "umbrella-header" else f'umbrella "{path}"')
            mm = gen / f"{name}.modulemap"
            mm.write_text(f"module {name} {{\n  {body}\n  export *\n}}\n")
            flags += ["-Xcc", f"-fmodule-map-file={mm}", "-Xcc", f"-I{path.parent if kind == 'umbrella-header' else path}"]
        else:
            flags += ["-Xcc", f"-fmodule-map-file={spec}", "-Xcc", f"-I{spec.parent}"]
    return flags


def swift_files(module):
    files = []
    for src in module["sources"]:
        if src.is_file():
            files.append(src)
        else:
            files += sorted(p for p in src.rglob("*.swift") if not any(x in str(p) for x in module["exclude"]))
    return files


def check(module, common):
    files = swift_files(module)
    extra = []
    if module["resources"]:
        stub = OUT / "stubs" / f"{module['name']}_bundle.swift"
        stub.parent.mkdir(parents=True, exist_ok=True)
        stub.write_text("import Foundation\nextension Foundation.Bundle {\n"
                        "    static let module: Bundle = .main\n}\n")
        extra.append(stub)
    cmd = [SWIFTC, "-wmo", "-swift-version", "5", "-emit-module",
           "-emit-module-path", str(OUT / "modules" / f"{module['name']}.swiftmodule"),
           "-module-name", module["name"], "-I", str(OUT / "modules"),
           "-Xfrontend", "-enable-upcoming-feature", "-Xfrontend", "ConciseMagicFile",
           *common, *module["flags"]]
    if not (module["executable"] and any(f.name == "main.swift" for f in files)):
        cmd.append("-parse-as-library")
    cmd += [str(f) for f in files + extra]
    (OUT / "modules").mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(cmd, capture_output=True, text=True)
    log = OUT / "logs" / f"{module['name']}.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    log.write_text(proc.stdout + proc.stderr)
    errors = [l for l in (proc.stdout + proc.stderr).splitlines() if ": error: " in l]
    return proc.returncode, errors, log


# Swift 6.3 accepts `async` declarations for an iOS 12 target and reports
# only concurrency library uses, but nothing of Swift concurrency can run on
# iOS 12 (it would link libswift_Concurrency). Every remaining spelling of it
# is reported here so the port can reach zero.
CONCURRENCY = re.compile(
    r"(?<![.\w])async(?=\s*(throws|->|\{|let\b|\)|$|\s*rethrows|\s*where))"
    r"|\bawait\b|^\s*(?:(?:public|private|fileprivate|internal|package|final|nonisolated|distributed)\s+)*actor\s+\w"
    r"|@concurrent\b|\bisolated\s+deinit\b|\bTask\s*[{(.<]|\bTask\.\w|\bAsync(Throwing)?Stream\b"
    r"|\bwithTaskGroup\b|\bwithThrowingTaskGroup\b|\bwithChecked(Throwing)?Continuation\b|\bCheckedContinuation\b"
    r"|\bMainActor\.|\bAsyncSequence\b|\bTaskGroup\b|\bCancellationError\b|@globalActor\b",
    re.M,
)
# Compile-time-only spellings (nonisolated, sending, @MainActor on a
# declaration) are not reported: in Swift 5 mode they emit nothing at run
# time. Files only another platform compiles are skipped.
OTHER_PLATFORM_FILE = re.compile(r"[@+](AppKit|macOS|watchOS|visionOS)\.swift$")


def strip_comments_and_strings(text):
    text = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
    text = re.sub(r'"""(.*?)"""', lambda m: '""' + "\n" * m.group(0).count("\n"), text, flags=re.S)
    text = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', text)
    text = re.sub(r"//[^\n]*", "", text)
    return text


def lint(module):
    hits = []
    for f in swift_files(module):
        if OTHER_PLATFORM_FILE.search(f.name):
            continue
        code = strip_comments_and_strings(f.read_text())
        for i, line in enumerate(code.split("\n"), 1):
            m = CONCURRENCY.search(line)
            if m:
                hits.append(f"{f}:{i}: {m.group(0).strip()}: {line.strip()}")
    return hits


def main(argv):
    if "--list" in argv:
        print("\n".join(m["name"] for m in MODULES))
        return 0
    names = [a for a in argv if not a.startswith("--")]
    if "--from" in argv:
        start = [m["name"] for m in MODULES].index(names[0])
        names = [m["name"] for m in MODULES[start:]]
    selected = [BY_NAME[n] for n in names] if names else MODULES
    common = modulemap_flags()
    for d in FRAMEWORK_DIRS:
        common += ["-F", str(d)]
    failed = 0
    for module in selected:
        code, errors, log = check(module, common)
        unique = sorted(set(errors))
        hits = lint(module)
        (OUT / "logs" / f"{module['name']}.lint").write_text("\n".join(hits) + ("\n" if hits else ""))
        status = "ok" if code == 0 else f"FAIL ({len(unique)} errors)"
        if hits:
            status += f", {len(hits)} concurrency uses"
        print(f"{module['name']:28} {status}  {log if code or hits else ''}", flush=True)
        if code or hits:
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
