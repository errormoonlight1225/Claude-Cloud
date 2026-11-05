#!/usr/bin/env python3
"""Take `awaitBackground` off calls the compiler says are the main thread's.

deasync_ui.py wraps every former await in `awaitBackground { ... }`; where
the awaited function was the main actor's own (an async method of a view
controller), the wrapper must come off: the call runs on the main thread,
as it did. The compiler reports those as calls to a main actor-isolated
method in a nonisolated context; for each one that starts the wrapper's
body, this removes the wrapper.

Usage: unwrap_main_calls.py MODULE   (reads $OUT/logs/MODULE.log)
"""
import os
import re
import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from strip_isolation import match_brace  # noqa: E402

OUT = Path(os.environ.get("OUT", "/tmp/irisin-ios12-check"))
CALL = re.compile(r"^(/[^:]+):(\d+):(\d+): (?:warning|error): call to main actor-isolated "
                  r"(?:instance method|static method|function|initializer|global function)")

module = sys.argv[1]
sites = defaultdict(set)
for line in (OUT / "logs" / f"{module}.log").read_text().splitlines():
    m = CALL.match(line)
    if m:
        sites[m.group(1)].add((int(m.group(2)), int(m.group(3))))

changed = 0
for path, positions in sites.items():
    text = Path(path).read_text()
    data = text.encode()
    byte_lines = data.split(b"\n")
    offsets = [0]
    for l in byte_lines:
        offsets.append(offsets[-1] + len(l) + 1)
    # columns are bytes; positions in the text are characters
    targets = sorted({len(data[:offsets[ln - 1] + col - 1].decode(errors="ignore"))
                      for ln, col in positions}, reverse=True)
    for pos in targets:
        # the nearest wrapper opening before the call, whose body starts at it
        head = text.rfind("awaitBackground", 0, pos)
        if head < 0:
            continue
        m = re.match(r"awaitBackground\s*(\(\s*)?\{\s*(try[?!]?\s+)?", text[head:])
        if not m or head + m.end() > pos:
            continue
        # the call must start the body: only an expression's own prefix
        # (a receiver like `self.` or `Type.`) may come between
        between = text[head + m.end():pos]
        if not re.fullmatch(r"[\w.?!]*", between):
            continue
        brace = head + text[head:].index("{")
        close = match_brace(text, brace)
        if close < 0:
            continue
        body = text[brace + 1:close].strip()
        end = close + 1
        parenthesized = m.group(1) is not None
        if parenthesized:
            rest = re.match(r"\s*\)", text[end:])
            if not rest:
                continue
            end += rest.end()
        prefix = text[:head]
        # `try awaitBackground { try x }` -> `try x`
        if m.group(2) and re.search(r"try[?!]?\s*$", prefix):
            body = re.sub(r"^try\s+", "", body)
        replacement = f"({body})" if parenthesized else body
        text = prefix + replacement + text[end:]
        changed += 1
    Path(path).write_text(text)
print(f"unwrapped {changed} call(s)")
