#!/usr/bin/env python3
"""Mechanical de-async for code that may block: engines, the helper, the CLI.

An `async` function becomes a synchronous one that blocks its caller (which
the port keeps off the main thread), so its signature loses `async` and its
calls lose `await`:

  func f() async throws    -> nonisolated func f() throws
      (nonisolated: the compiler then reports every main-actor state the
      body touches, each a hop to wrap in DispatchQueue.main.sync)
  (T) async -> U  (a type) -> @Sendable (T) -> U
      (@Sendable: a closure literal passed there is checked the same way)
  get async throws         -> get throws      async let x = e -> let x = e
  try await / await        -> try / (nothing) for await x in  -> for x in
  Task { } / Task.detached(priority: .p) { } -> LegacyTask.detached(qos:) { }
  Task<T, E> (a type)      -> LegacyTask
  for await x in       -> for x in
  URLSession...data(for:) / data(from:) / download(for:) -> compat* (LegacyCompat)
  Task.sleep(nanoseconds: n) -> LegacyTask.sleep(seconds: Double(n) / 1e9)
  Task.isCancelled / Task.checkCancellation() -> LegacyTask.*
  CancellationError() -> LegacyCancellationError()

What needs judgement (Task { }, continuations, actors, streams) is left for
a person, and typecheck.py's lint lists it.

Usage: deasync.py PATH...
"""

import re
import sys
from pathlib import Path

RULES = [
    (r"\bget\s+async\s+throws\b", "get throws"),
    (r"\bget\s+async\b", "get"),
    (r"\basync\s+let\b", "let"),
    (r"\btry\?\s+await\s+", "try? "),
    (r"\btry!\s+await\s+", "try! "),
    (r"\btry\s+await\s+", "try "),
    (r"\bfor\s+try\s+await\s+", "for "),
    (r"\bfor\s+await\s+", "for "),
    (r"\bawait\s+", ""),
    (r"(\bURLSession(?:\.shared)?|\bsession|\b[a-zA-Z_]+Session)\.data\(for:", r"\1.compatData(for:"),
    (r"(\bURLSession(?:\.shared)?|\bsession|\b[a-zA-Z_]+Session)\.data\(from:", r"\1.compatData(from:"),
    (r"(\bURLSession(?:\.shared)?|\bsession|\b[a-zA-Z_]+Session)\.download\(for:", r"\1.compatDownload(for:"),
    (r"\bTask\.sleep\(for:\s*\.seconds\(([^)]+)\)\)", r"LegacyTask.sleep(seconds: TimeInterval(\1))"),
    (r"\bTask\.sleep\(for:\s*\.milliseconds\(([^)]+)\)\)", r"LegacyTask.sleep(seconds: TimeInterval(\1) / 1000)"),
    (r"\bTask\.detached\(priority:\s*\.(\w+)\)\s*\{", lambda m: f"LegacyTask.detached(qos: .{QOS.get(m.group(1), m.group(1))}) {{"),
    (r"\bTask\.detached\s*\{", "LegacyTask.detached {"),
    (r"\bTask\(priority:\s*\.(\w+)\)\s*\{", lambda m: f"LegacyTask.detached(qos: .{QOS.get(m.group(1), m.group(1))}) {{"),
    (r"(?<![\w.])Task\s*\{(\s*@MainActor\s+in\b)?", "LegacyTask.detached {"),
    (r"(?<![\w.])Task<[^<>]*(<[^<>]*>[^<>]*)?>", "LegacyTask"),
    (r"\bTask\.isCancelled\b", "LegacyTask.isCancelled"),
    (r"\bTask\.checkCancellation\(\)", "LegacyTask.checkCancellation()"),
    (r"\bCancellationError\(\)", "LegacyCancellationError()"),
    (r"\bis\s+CancellationError\b", "is LegacyCancellationError"),
    (r"\bas(\??)\s+CancellationError\b", r"as\1 LegacyCancellationError"),
]

QOS = {"high": "userInitiated", "medium": "default", "low": "utility", "userInitiated": "userInitiated",
       "utility": "utility", "background": "background", "userInteractive": "userInteractive"}

DECL_OPENER = re.compile(r"(\b(func\s+[^\s(<]+|init[?!]?|subscript)\s*(<[^()]*>)?\s*)$")


def mask(text):
    """The text with comments and string contents blanked, same length."""
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                out[k] = " "
            i = j
        elif text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            for k in range(i, j):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif text.startswith('"""', i):
            j = text.find('"""', i + 3)
            j = n if j < 0 else j + 3
            for k in range(i + 3, j - 3):
                if out[k] != "\n":
                    out[k] = " "
            i = j
        elif text[i] == '"':
            j = i + 1
            while j < n and text[j] not in '"\n':
                j += 2 if text[j] == "\\" else 1
            for k in range(i + 1, min(j, n)):
                out[k] = " "
            i = j + 1
        else:
            i += 1
    return "".join(out)


def drop_async(text):
    """Removes `async` after a parameter list: a declaration gains
    `nonisolated`, a function type gains `@Sendable`."""
    edits = []  # (position, delete_length, insert_text)
    masked = mask(text)
    stack = []
    i, n = 0, len(masked)
    while i < n:
        c = masked[i]
        if c == "(":
            stack.append(i)
        elif c == ")" and stack:
            opener = stack.pop()
            m = re.match(r"(\s*)async\b(?!\s*\()", masked[i + 1:])
            if m and not re.match(r"\s*async\s*(let|var)\b", masked[i + 1:]):
                kw_start = i + 1 + len(m.group(1))
                edits.append((i + 1, len(m.group(0)), ""))
                before = masked[:opener]
                d = DECL_OPENER.search(before)
                if d:
                    line_start = before.rfind("\n") + 1
                    decl_text = before[line_start:]
                    if "nonisolated" not in decl_text:
                        edits.append((d.start(1), 0, "nonisolated "))
                else:
                    prefix = before.rstrip()
                    if not prefix.endswith("@Sendable") and not re.search(r"@Sendable\s*$", before):
                        edits.append((opener, 0, "@Sendable "))
        i += 1
    for pos, length, insert in sorted(edits, key=lambda e: e[0], reverse=True):
        text = text[:pos] + insert + text[pos + length:]
    return text


NEEDS_IMPORT = re.compile(r"\bcompat(Data|Download)\(|\bLegacyTask\b|\bLegacyCancellationError\b")


def add_import(text):
    if re.search(r"^\s*import LegacyCompat\s*$", text, re.M):
        return text
    lines = text.split("\n")
    i = 0
    while i < len(lines) and (lines[i].startswith("//") or lines[i].strip() == ""):
        i += 1
    lines.insert(i, "import LegacyCompat")
    return "\n".join(lines)


def rewrite_sleeps(text):
    """`Task.sleep(nanoseconds: e)` with `e` read to its balanced paren."""
    out, i = [], 0
    pattern = re.compile(r"\bTask\.sleep\(nanoseconds:\s*")
    while True:
        m = pattern.search(text, i)
        if not m:
            out.append(text[i:])
            return "".join(out)
        depth, j = 1, m.end()
        while j < len(text) and depth:
            depth += {"(": 1, ")": -1}.get(text[j], 0)
            j += 1
        expr = text[m.end():j - 1].strip()
        out.append(text[i:m.start()] + f"LegacyTask.sleep(seconds: Double({expr}) / 1_000_000_000)")
        i = j


def rewrite(text):
    text = drop_async(text)
    text = rewrite_sleeps(text)
    out = []
    for line in text.split("\n"):
        stripped = line.lstrip()
        if stripped.startswith("//") or stripped.startswith("///"):
            out.append(line)
            continue
        for pattern, repl in RULES:
            line = re.sub(pattern, repl, line)
        out.append(line)
    text = "\n".join(out)
    if NEEDS_IMPORT.search(text):
        text = add_import(text)
    return text


def main(paths):
    changed = 0
    for arg in paths:
        p = Path(arg)
        for f in [p] if p.is_file() else sorted(p.rglob("*.swift")):
            old = f.read_text()
            new = rewrite(old)
            if new != old:
                f.write_text(new)
                changed += 1
    print(f"rewrote {changed} file(s)")


if __name__ == "__main__":
    main(sys.argv[1:])
