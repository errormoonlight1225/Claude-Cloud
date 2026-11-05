#!/usr/bin/env python3
"""Rewrite iOS 13+ API uses that have a LegacyCompat spelling.

Reads the compiler log written by typecheck.py and, for each
"'NAME' is only available in iOS X" error with a known replacement, edits
the source at the reported line and column. Files that change get
`import LegacyCompat`. Anything without a rule is left for a person.

Usage: fix_availability.py MODULE [MODULE ...]
       (reads $OUT/logs/MODULE.log, default /tmp/irisin-ios12-check)
"""

import os
import re
import sys
from collections import defaultdict
from pathlib import Path

OUT = Path(os.environ.get("OUT", "/tmp/irisin-ios12-check"))

ERROR = re.compile(r"^(/[^:]+):(\d+):(\d+): error: '([^']+)' is only available in iOS ([0-9.]+) or newer")

# Plain identifier renames at the error column.
RENAMES = {
    "label": "compatLabel",
    "secondaryLabel": "compatSecondaryLabel",
    "tertiaryLabel": "compatTertiaryLabel",
    "quaternaryLabel": "compatQuaternaryLabel",
    "placeholderText": "compatPlaceholderText",
    "separator": "compatSeparator",
    "opaqueSeparator": "compatOpaqueSeparator",
    "systemBackground": "compatSystemBackground",
    "secondarySystemBackground": "compatSecondarySystemBackground",
    "tertiarySystemBackground": "compatTertiarySystemBackground",
    "systemGroupedBackground": "compatSystemGroupedBackground",
    "secondarySystemGroupedBackground": "compatSecondarySystemGroupedBackground",
    "tertiarySystemGroupedBackground": "compatTertiarySystemGroupedBackground",
    "systemFill": "compatSystemFill",
    "secondarySystemFill": "compatSecondarySystemFill",
    "tertiarySystemFill": "compatTertiarySystemFill",
    "quaternarySystemFill": "compatQuaternarySystemFill",
    "systemGray2": "compatSystemGray2",
    "systemGray3": "compatSystemGray3",
    "systemGray4": "compatSystemGray4",
    "systemGray5": "compatSystemGray5",
    "systemGray6": "compatSystemGray6",
    "systemIndigo": "compatSystemIndigo",
    "systemTeal": "compatSystemTeal",
    "systemMint": "compatSystemMint",
    "systemCyan": "compatSystemCyan",
    "systemBrown": "compatSystemBrown",
    "systemMaterial": "compatSystemMaterial",
    "systemThinMaterial": "compatSystemThinMaterial",
    "systemUltraThinMaterial": "compatSystemUltraThinMaterial",
    "systemThickMaterial": "compatSystemThickMaterial",
    "systemChromeMaterial": "compatSystemChromeMaterial",
    "systemMaterialDark": "compatSystemMaterialDark",
    "systemThinMaterialDark": "compatSystemThinMaterialDark",
    "systemUltraThinMaterialDark": "compatSystemUltraThinMaterialDark",
    "systemChromeMaterialDark": "compatSystemChromeMaterialDark",
    "systemThickMaterialDark": "compatSystemThickMaterialDark",
    "systemMaterialLight": "compatSystemMaterial",
    "systemThinMaterialLight": "compatSystemThinMaterial",
    "monospacedSystemFont(ofSize:weight:)": "compatMonospacedSystemFont",
    "resolvedColor(with:)": "compatResolvedColor",
    "withTintColor(_:renderingMode:)": "compatWithTintColor",
    "withTintColor(_:)": "compatWithTintColor",
    "withConfiguration(_:)": "compatWithConfiguration",
    "preferredSymbolConfiguration": "compatPreferredSymbolConfiguration",
    "setPreferredSymbolConfiguration(_:forImageIn:)": "compatSetPreferredSymbolConfiguration",
    "write(contentsOf:)": "compatWrite",
    "read(upToCount:)": "compatRead",
    "readToEnd()": "compatReadToEnd",
    "seekToEnd()": "compatSeekToEnd",
    "seek(toOffset:)": "compatSeek",
    "offset()": "compatOffset",
    "synchronize()": "compatSynchronize",
    "truncate(atOffset:)": "compatTruncate",
    "close()": "compatClose",
}

# Renames that only apply when the line also matches a pattern.
CONDITIONAL = {
    "medium": (r"ActivityIndicator|style:\s*\.medium|\.style\s*=\s*\.medium", "compatMedium"),
    "large": (r"ActivityIndicator|style:\s*\.large|\.style\s*=\s*\.large", "compatLarge"),
}

# Whole-line regex rewrites, keyed by the reported name.
LINE_RULES = {
    "init(localized:table:bundle:locale:comment:)": [
        (r"\bString\(localized:", "String(legacyLocalized:"),
        (r"(?<![A-Za-z0-9_])\.init\(localized:", ".init(legacyLocalized:"),
        (r"^(\s*)localized:", r"\1legacyLocalized:"),
    ],
    "init(localized:defaultValue:table:bundle:locale:comment:)": [
        (r"\bString\(localized:", "String(legacyLocalized:"),
    ],
    "LocalizationValue": [(r"\bString\.LocalizationValue\b", "LegacyLocalizationValue")],
    "init(systemName:)": [
        (r"\bUIImage\(systemName:\s*", "UIImage.compatSystemImage("),
        (r"(?<![A-Za-z0-9_])\.init\(systemName:\s*", "UIImage.compatSystemImage("),
    ],
    "init(systemName:withConfiguration:)": [
        (r"\bUIImage\(systemName:\s*", "UIImage.compatSystemImage("),
        (r"(?<![A-Za-z0-9_])\.init\(systemName:\s*", "UIImage.compatSystemImage("),
    ],
    "init(dynamicProvider:)": [
        (r"\bUIColor\(dynamicProvider:\s*", "UIColor.compatDynamic("),
        (r"\bUIColor\s*\{", "UIColor.compatDynamic {"),
        (r"(?<![A-Za-z0-9_])\.init\(dynamicProvider:\s*", "UIColor.compatDynamic("),
        (r"(?<![A-Za-z0-9_])\.init\s*\{", "UIColor.compatDynamic {"),
    ],
    "SymbolConfiguration": [(r"\bUIImage\.SymbolConfiguration\b", "LegacySymbolConfiguration")],
    "cornerCurve": [(r"(\S+)\.cornerCurve\s*=\s*\.continuous", r"\1.compatContinuousCorners()"),
                    (r"^(\s*)cornerCurve\s*=\s*\.continuous", r"\1compatContinuousCorners()")],
    "continuous": [(r"(\S+)\.cornerCurve\s*=\s*\.continuous", r"\1.compatContinuousCorners()"),
                   (r"^(\s*)cornerCurve\s*=\s*\.continuous", r"\1compatContinuousCorners()")],
}

# Statements kept only where the OS has them: `if #available(...) { line }`.
GUARD_LINE = {
    "isModalInPresentation": "13.0",
    "overrideUserInterfaceStyle": "13.0",
    "automaticallyShowsCancelButton": "13.0",
    "showsLargeContentViewer": "13.0",
    "scalesLargeContentImage": "13.0",
    "wantsPriorityOverSystemBehavior": "15.0",
    "keyboardLayoutGuide": None,
}


def add_import(text):
    """`import LegacyCompat` after the file's header comment, at top level, so
    it never lands inside a platform `#if` branch."""
    if re.search(r"^\s*(@_exported |public |internal |package )?import LegacyCompat\s*$", text, re.M):
        return text
    lines = text.split("\n")
    i = 0
    while i < len(lines) and (lines[i].startswith("//") or lines[i].strip() == ""):
        i += 1
    lines.insert(i, "import LegacyCompat")
    if i + 1 < len(lines) and not lines[i + 1].startswith("import ") and lines[i + 1].strip():
        lines.insert(i + 1, "")
    return "\n".join(lines)


def fix_file(path, edits):
    raw = Path(path).read_bytes().split(b"\n")
    changed = False
    guarded_lines = set()
    # Per line, apply column edits right to left.
    by_line = defaultdict(list)
    for line, col, name in edits:
        by_line[line].append((col, name))
    unhandled = []
    for line_no, items in by_line.items():
        idx = line_no - 1
        line = raw[idx].decode()
        for col, name in sorted(set(items), reverse=True):
            new = None
            if name in RENAMES or name in CONDITIONAL:
                token = re.match(r"[A-Za-z_][A-Za-z0-9_]*", name).group(0)
                replacement = RENAMES.get(name)
                if name in CONDITIONAL:
                    pattern, replacement = CONDITIONAL[name]
                    if not re.search(pattern, line):
                        unhandled.append((line_no, col, name))
                        continue
                b = line.encode()
                start = col - 1
                if b[start:start + len(token)].decode(errors="ignore") == token:
                    new = (b[:start] + replacement.encode() + b[start + len(token):]).decode()
                elif replacement in line:
                    continue  # done by an earlier error on this line
            elif name in LINE_RULES:
                candidate = line
                for pattern, repl in LINE_RULES[name]:
                    candidate = re.sub(pattern, repl, candidate)
                if candidate != line:
                    new = candidate
                elif line.rstrip().endswith(("String(", ".init(")) and idx + 1 < len(raw):
                    # The labels start on the next line.
                    following = raw[idx + 1].decode()
                    rewritten = re.sub(r"^(\s*)localized:", r"\1legacyLocalized:", following)
                    rewritten = re.sub(r"^(\s*)systemName:\s*", r"\1", rewritten) if name.startswith("init(systemName:") else rewritten
                    if rewritten != following:
                        raw[idx + 1] = rewritten.encode()
                        if name.startswith("init(systemName:"):
                            new = re.sub(r"\bUIImage\($", "UIImage.compatSystemImage(", line.rstrip())
                        changed = True
                    continue
                else:
                    continue  # already rewritten by another error on this line
            elif name in GUARD_LINE and idx not in guarded_lines:
                version = GUARD_LINE[name]
                stripped = line.strip()
                if version and re.match(r"^[\w.\[\]()?!]+\s*=\s*[^{}]+$", stripped) and not stripped.endswith(","):
                    indent = line[: len(line) - len(line.lstrip())]
                    new = f"{indent}if #available(iOS {version}, *) {{ {stripped} }}"
                    guarded_lines.add(idx)
            if new is None:
                unhandled.append((line_no, col, name))
                continue
            line = new
            changed = True
        raw[idx] = line.encode()
    if changed:
        text = b"\n".join(raw).decode()
        text = add_import(text)
        Path(path).write_text(text)
    return changed, unhandled


def main(modules):
    total_files = 0
    leftovers = []
    for module in modules:
        log = OUT / "logs" / f"{module}.log"
        edits = defaultdict(list)
        for line in log.read_text().splitlines():
            m = ERROR.match(line)
            if m:
                path, ln, col, name, _ = m.groups()
                if "/sdks/" in path or "/xsdks/" in path:
                    continue
                edits[path].append((int(ln), int(col), name))
        for path, items in sorted(edits.items()):
            changed, unhandled = fix_file(path, items)
            total_files += changed
            leftovers += [(path, *u) for u in unhandled]
    print(f"rewrote {total_files} file(s); {len(leftovers)} error(s) without a rule")
    for path, ln, col, name in sorted(set(leftovers)):
        print(f"  {path}:{ln}:{col}: {name}")


if __name__ == "__main__":
    main(sys.argv[1:])
