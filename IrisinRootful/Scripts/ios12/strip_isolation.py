#!/usr/bin/env python3
"""Mechanical part of the iOS 12 port: drop main-actor annotations.

Swift concurrency needs iOS 13, so nothing in the port may hop actors at run
time. What remains of `@MainActor` is compile-time isolation, which in Swift 5
mode turns calls from ordinary (nonisolated) code into errors. The port's rule
is "UI code runs on the main thread", as it did before Swift concurrency, so
the annotations are removed:

  * `@MainActor` (own line or inline, also `@preconcurrency @MainActor`)
  * `MainActor.assumeIsolated { body }` becomes `do { body }` as a
    statement and `{ body }()` inside an expression
  * `@MainActor in` closure headers lose the attribute

Usage: strip_isolation.py PATH...   (files or directories, *.swift)
"""

import re
import sys
from pathlib import Path


def match_brace(text, open_index):
    """Index of the brace closing the one at open_index (skips strings/comments)."""
    depth = 0
    i = open_index
    n = len(text)
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            i = text.find("\n", i)
            if i < 0:
                return -1
            continue
        if text.startswith("/*", i):
            i = text.find("*/", i) + 2
            continue
        if text.startswith('"""', i):
            i = text.find('"""', i + 3) + 3
            continue
        if c == '"':
            i += 1
            while i < n and text[i] != '"':
                if text[i] == "\\":
                    i += 1
                i += 1
            i += 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def rewrite(text):
    # MainActor.assumeIsolated { ... }  ->  { ... }()
    while True:
        m = re.search(r"MainActor\.assumeIsolated\s*\{", text)
        if not m:
            break
        open_index = m.end() - 1
        close = match_brace(text, open_index)
        if close < 0:
            break
        line_start = text.rfind("\n", 0, m.start()) + 1
        if text[line_start:m.start()].strip() == "":
            # A statement: `do { body }`, so it cannot read as a trailing
            # closure of the line above.
            text = text[:m.start()] + "do " + text[open_index:]
        else:
            text = text[:m.start()] + text[open_index:close + 1] + "()" + text[close + 1:]
    text = re.sub(r"^[ \t]*@preconcurrency @MainActor[ \t]*\n", "", text, flags=re.M)
    text = re.sub(r"^[ \t]*@MainActor[ \t]*\n", "", text, flags=re.M)
    text = re.sub(r"@preconcurrency @MainActor\s+", "", text)
    text = re.sub(r"@MainActor\s+in\b", "in", text)
    text = re.sub(r"\{\s*in\b", "{", text)  # `{ @MainActor in` became `{ in`
    text = re.sub(r"@MainActor\s+", "", text)
    text = re.sub(r"@MainActor\b", "", text)
    return text


def main(paths):
    changed = 0
    for arg in paths:
        p = Path(arg)
        files = [p] if p.is_file() else sorted(p.rglob("*.swift"))
        for f in files:
            old = f.read_text()
            new = rewrite(old)
            if new != old:
                f.write_text(new)
                changed += 1
    print(f"rewrote {changed} file(s)")


if __name__ == "__main__":
    main(sys.argv[1:])
