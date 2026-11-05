#!/usr/bin/env python3
"""De-async for interface code, which runs on the main thread.

The engines (deasync.py) block their background caller. Interface code
cannot block: an `await` there becomes `awaitBackground { ... }`, which runs
the awaited work on a global queue while the main run loop turns, and a
`Task { }` started from the main actor becomes `LegacyMainTask { }`, whose
body runs on the main thread (LegacyCompat/Concurrency.swift).

  func f() async throws          -> func f() throws   (stays main-thread)
  (T) async -> U   (a type)      -> (T) -> U
  try await expr / await expr    -> try awaitBackground { try expr } /
                                    awaitBackground { expr }
  Task { } / Task { @MainActor in } -> LegacyMainTask { }
  Task.detached { }              -> LegacyTask.detached { }
  Task<...> (a type)             -> LegacyMainTask
  Task.sleep / isCancelled / checkCancellation, CancellationError -> Legacy*

`awaitBackground`'s closure is @Sendable: where the awaited call is the
main thread's own (an async method of a view controller), the compiler
reports it, and the wrapper comes off. `for await`, `async let`, task groups
and continuations are left for a person.

Usage: deasync_ui.py PATH...
"""

import re
import sys
from importlib import import_module
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
engines = import_module("deasync")
mask = engines.mask
add_import = engines.add_import


def drop_async_ui(text):
    """`async` after a parameter list goes, with nothing added."""
    masked = mask(text)
    edits = []
    stack = []
    for i, c in enumerate(masked):
        if c == "(":
            stack.append(i)
        elif c == ")" and stack:
            stack.pop()
            m = re.match(r"(\s*)async\b(?!\s*\()", masked[i + 1:])
            if m and not re.match(r"\s*async\s*(let|var)\b", masked[i + 1:]):
                edits.append((i + 1, len(m.group(0))))
    for pos, length in sorted(edits, reverse=True):
        text = text[:pos] + text[pos + length:]
    return text


TERMINATORS_AT_DEPTH0 = (",",)


def wrap_awaits(text):
    """`[try] await expr` -> `[try] awaitBackground { [try] expr }`."""
    masked = mask(text)
    out = []
    i = 0
    pattern = re.compile(r"(?<![\w.])(try[?!]?\s+)?await\s+")
    while True:
        m = pattern.search(masked, i)
        if not m:
            out.append(text[i:])
            break
        # skip `for await` / `for try await` (left for a person)
        before = masked[max(0, m.start() - 8):m.start()]
        if re.search(r"\bfor\s+$", before):
            out.append(text[i:m.end()])
            i = m.end()
            continue
        start_expr = m.end()
        depth = 0
        j = start_expr
        n = len(masked)
        statement_start = masked.rfind("\n", 0, m.start()) + 1
        head = masked[statement_start:m.start()].strip()
        opens_block = re.match(r"^(if|guard|while|switch|else if|\}\s*else if)\b", head) is not None
        end = n
        # the expression runs to the end of its line, or past it while a
        # parenthesis or bracket is open
        while j < n:
            c = masked[j]
            if c in "([":
                depth += 1
            elif c in ")]":
                if depth == 0:
                    end = j
                    break
                depth -= 1
            elif depth == 0 and (c == "\n" or c in TERMINATORS_AT_DEPTH0):
                end = j
                break
            elif depth == 0 and masked.startswith(" else", j) and head.startswith("guard"):
                end = j
                break
            elif depth == 0 and c == "{" and opens_block:
                end = j
                break
            j += 1
        # up to the last code character: a trailing comment stays outside
        stop = end
        while stop > start_expr and masked[stop - 1] in " \t":
            stop -= 1
        expr = text[start_expr:stop]
        trailing = text[stop:end]
        if not expr:
            out.append(text[i:m.end()])
            i = m.end()
            continue
        in_condition = re.match(r"^(if|guard|while|else if|\}\s*else if)\b", head) is not None
        prefix = m.group(1) or ""
        inner = f"try {expr}" if prefix else expr
        if in_condition:
            # a trailing closure in a condition needs parentheses
            wrapped = f"{prefix}awaitBackground({{ {inner} }})"
        else:
            wrapped = f"{prefix}awaitBackground {{ {inner} }}"
        out.append(text[i:m.start()] + wrapped + trailing)
        i = end
    return "".join(out)


RULES = [
    (r"\bget\s+async\s+throws\b", "get throws"),
    (r"\bget\s+async\b", "get"),
    (r"\bTask\.detached\(priority:\s*\.(\w+)\)\s*\{",
     lambda m: f"LegacyTask.detached(qos: .{engines.QOS.get(m.group(1), m.group(1))}) {{"),
    (r"\bTask\.detached\s*\{", "LegacyTask.detached {"),
    (r"(?<![\w.])Task\(priority:\s*\.\w+\)\s*\{\s*@MainActor\s+in\b", "LegacyMainTask {"),
    (r"(?<![\w.])Task\(priority:\s*\.\w+\)\s*\{(\s*@MainActor\b)?", "LegacyMainTask {"),
    (r"(?<![\w.])Task\s*\{\s*@MainActor\s+in\b", "LegacyMainTask {"),
    (r"(?<![\w.])Task\s*\{(\s*@MainActor\b)?", "LegacyMainTask {"),
    (r"(?<![\w.])Task<[^<>]*(<[^<>]*>[^<>]*)?>", "LegacyMainTask"),
    (r"\bTask\.isCancelled\b", "LegacyTask.isCancelled"),
    (r"\bTask\.checkCancellation\(\)", "LegacyTask.checkCancellation()"),
    (r"\bTask\.sleep\(for:\s*\.seconds\(([^)]+)\)\)", r"LegacyTask.sleep(seconds: TimeInterval(\1))"),
    (r"\bTask\.sleep\(for:\s*\.milliseconds\(([^)]+)\)\)", r"LegacyTask.sleep(seconds: TimeInterval(\1) / 1000)"),
    (r"\bTask\.sleep\((seconds|continuousSeconds):", r"LegacyTask.sleep(\1:"),
    (r"\bCancellationError\(\)", "LegacyCancellationError()"),
    (r"\bis\s+CancellationError\b", "is LegacyCancellationError"),
    (r"\bas(\??)\s+CancellationError\b", r"as\1 LegacyCancellationError"),
    (r"(\bURLSession(?:\.shared)?|\bsession)\.data\(for:", r"\1.compatData(for:"),
    (r"(\bURLSession(?:\.shared)?|\bsession)\.data\(from:", r"\1.compatData(from:"),
    (r"(\bURLSession(?:\.shared)?|\bsession)\.download\(for:", r"\1.compatDownload(for:"),
]


def rewrite(text):
    text = drop_async_ui(text)
    text = engines.rewrite_sleeps(text)
    text = wrap_awaits(text)
    out = []
    for line in text.split("\n"):
        if line.lstrip().startswith("//"):
            out.append(line)
            continue
        for pattern, repl in RULES:
            line = re.sub(pattern, repl, line)
        out.append(line)
    text = "\n".join(out)
    if re.search(r"\b(awaitBackground|LegacyMainTask|LegacyTask|Legacy\w+Error|compatData|compatDownload)\b", text):
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
