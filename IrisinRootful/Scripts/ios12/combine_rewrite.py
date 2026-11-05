#!/usr/bin/env python3
"""Foundation's Combine publishers and schedulers to OpenCombine's spelling.

  NotificationCenter.default.publisher(for:)  -> .ocombine.publisher(for:)
  notificationCenter.publisher(for:)          -> .ocombine.publisher(for:)
  receive(on: DispatchQueue.main) / scheduler: DispatchQueue.main
                                              -> DispatchQueue.main.ocombine
  RunLoop.main as a scheduler                 -> RunLoop.main.ocombine

Usage: combine_rewrite.py PATH...
"""
import re
import sys
from pathlib import Path

RULES = [
    (re.compile(r"\b(NotificationCenter\.default|notificationCenter|center)\.publisher\(for:"), r"\1.ocombine.publisher(for:"),
    (re.compile(r"\b(receive\(on:|scheduler:)\s*(DispatchQueue\.main|RunLoop\.main|DispatchQueue\.global\([^)]*\))(?!\.ocombine)"), r"\1 \2.ocombine"),
    (re.compile(r"\bsubscribe\(on:\s*(DispatchQueue\.main|DispatchQueue\.global\([^)]*\))(?!\.ocombine)"), r"subscribe(on: \1.ocombine"),
]

changed = 0
for arg in sys.argv[1:]:
    p = Path(arg)
    for f in [p] if p.is_file() else sorted(p.rglob("*.swift")):
        old = f.read_text()
        new = old
        for pattern, repl in RULES:
            new = pattern.sub(repl, new)
        if new != old:
            f.write_text(new)
            changed += 1
print(f"rewrote {changed} file(s)")
