#!/usr/bin/env python3
"""Remove objects from a hand-written project.pbxproj by ID, with every
list entry and dictionary key that names them.

Usage: pbxproj_remove.py PROJECT.pbxproj ID [ID ...]
"""
import re
import sys


def remove(text, ids):
    lines = text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        m = re.match(r"^(\t+)([0-9A-F]{24})\b.*= \{\s*(.*)$", line)
        if m and m.group(2) in ids:
            if line.rstrip().endswith("};"):
                i += 1
                continue
            # skip to the line closing this block at the same indentation
            indent = m.group(1)
            i += 1
            while i < len(lines) and not lines[i].startswith(indent + "};"):
                i += 1
            i += 1
            continue
        stripped = line.strip()
        ref = re.match(r"^([0-9A-F]{24})\b[^=]*,$", stripped)
        if ref and ref.group(1) in ids:
            i += 1
            continue
        out.append(line)
        i += 1
    return "\n".join(out)


if __name__ == "__main__":
    path, ids = sys.argv[1], set(sys.argv[2:])
    text = open(path).read()
    new = remove(text, ids)
    open(path, "w").write(new)
    left = [i for i in ids if i in new]
    print(f"removed; still mentioned: {left}")
