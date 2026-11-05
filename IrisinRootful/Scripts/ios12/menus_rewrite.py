#!/usr/bin/env python3
"""UIMenu/UIAction to LegacyCompat's menus, whole files.

  UIAction / UIMenu / UIMenuElement / UIDeferredMenuElement -> Legacy*
  UIMenuElement.Attributes / .State -> LegacyAction.Attributes / .State
  preferredElementSize: .x (iOS 16)  -> dropped
  control.addAction(UIAction { ... }, for: e) -> control.legacyAddAction(for: e) { ... }

Attaching a menu to a button or bar item (`menu =`, `primaryAction:`) is
left to a person: typecheck.py reports each.

Usage: menus_rewrite.py PATH...
"""
import re
import sys
from importlib import import_module
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
add_import = import_module("fix_availability").add_import
match_brace = import_module("strip_isolation").match_brace

RENAMES = [
    (re.compile(r"\bUIMenuElement\.Attributes\b"), "LegacyAction.Attributes"),
    (re.compile(r"\bUIMenuElement\.State\b"), "LegacyAction.State"),
    (re.compile(r"\bUIMenu\.Options\b"), "LegacyMenu.Options"),
    (re.compile(r"\bUIDeferredMenuElement\b"), "LegacyDeferredMenuElement"),
    (re.compile(r"\bUIMenuElement\b"), "LegacyMenuElement"),
    (re.compile(r"\bUIMenu\b(?!Controller|Item|Builder|System)"), "LegacyMenu"),
    (re.compile(r"\bUIAction\b(?!Sheet)"), "LegacyAction"),
    (re.compile(r",\s*preferredElementSize:\s*\.\w+"), ""),
]


def rewrite_add_action(text):
    out, i = [], 0
    pattern = re.compile(r"\.addAction\(\s*LegacyAction\s*(\{)")
    while True:
        m = pattern.search(text, i)
        if not m:
            out.append(text[i:])
            return "".join(out)
        close = match_brace(text, m.start(1))
        tail = re.match(r"\s*,\s*for:\s*([^()]*?(?:\([^()]*\))?[^()]*?)\)", text[close + 1:])
        if close < 0 or not tail:
            out.append(text[i:m.end()])
            i = m.end()
            continue
        closure = text[m.start(1):close + 1]
        event = tail.group(1).strip()
        out.append(text[i:m.start()] + f".legacyAddAction(for: {event}) {closure}")
        i = close + 1 + tail.end()


changed = 0
for arg in sys.argv[1:]:
    p = Path(arg)
    for f in [p] if p.is_file() else sorted(p.rglob("*.swift")):
        old = f.read_text()
        new = old
        for pattern, repl in RENAMES:
            new = pattern.sub(repl, new)
        new = rewrite_add_action(new)
        if new != old:
            f.write_text(add_import(new))
            changed += 1
print(f"rewrote {changed} file(s)")
