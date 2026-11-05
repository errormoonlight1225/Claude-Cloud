#!/usr/bin/env python3
"""Whole-file renames of UIKit API to its LegacyCompat stand-in, across
line breaks; `import LegacyCompat` is added where anything changed.

  UIImage(systemName:[withConfiguration:])  -> UIImage.compatSystemImage(...)
  UIImage.SymbolConfiguration               -> LegacySymbolConfiguration
  UITableViewDiffableDataSource             -> LegacyTableViewDiffableDataSource
  UICollectionViewDiffableDataSource        -> LegacyCollectionViewDiffableDataSource
  NSDiffableDataSourceSnapshot              -> LegacyDiffableSnapshot
  UICollectionView.CellRegistration         -> LegacyCellRegistration
  UICollectionView.SupplementaryRegistration -> LegacySupplementaryRegistration
  .dequeueConfiguredReusableCell(using:     -> .legacyDequeueConfiguredReusableCell(using:
  .dequeueConfiguredReusableSupplementary(  -> .legacyDequeueConfiguredReusableSupplementary(
  UIListContentConfiguration, contentConfiguration, defaultContentConfiguration(),
  UIBackgroundConfiguration, backgroundConfiguration -> their Legacy* forms

Usage: symbols_rewrite.py PATH...
"""
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from importlib import import_module

add_import = import_module("fix_availability").add_import

RULES = [
    (re.compile(r"\bUIImage\(\s*systemName:\s*"), "UIImage.compatSystemImage("),
    (re.compile(r"(?<![\w.])\.init\(\s*systemName:\s*"), "UIImage.compatSystemImage("),
    (re.compile(r"\bUIImage\.SymbolConfiguration\b"), "LegacySymbolConfiguration"),
    (re.compile(r"\bUITableViewDiffableDataSource\b"), "LegacyTableViewDiffableDataSource"),
    (re.compile(r"\bUICollectionViewDiffableDataSource\b"), "LegacyCollectionViewDiffableDataSource"),
    (re.compile(r"\bNSDiffableDataSourceSnapshot\b"), "LegacyDiffableSnapshot"),
    (re.compile(r"\bUICollectionView\.CellRegistration\b"), "LegacyCellRegistration"),
    (re.compile(r"\bUICollectionView\.SupplementaryRegistration\b"), "LegacySupplementaryRegistration"),
    (re.compile(r"\.dequeueConfiguredReusableCell\(using:"), ".legacyDequeueConfiguredReusableCell(using:"),
    (re.compile(r"\.dequeueConfiguredReusableSupplementary\("), ".legacyDequeueConfiguredReusableSupplementary("),
    (re.compile(r"\bUIListContentConfiguration\b"), "LegacyListContentConfiguration"),
    (re.compile(r"\bUICollectionViewListCell\b"), "LegacyListCell"),
    (re.compile(r"\bUIBackgroundConfiguration\b"), "LegacyBackgroundConfiguration"),
    (re.compile(r"(?<![\w])defaultContentConfiguration\(\)"), "legacyDefaultContentConfiguration()"),
    (re.compile(r"(?<![\w])contentConfiguration\b"), "legacyContentConfiguration"),
    (re.compile(r"(?<![\w])backgroundConfiguration\b"), "legacyBackgroundConfiguration"),
    (re.compile(r"^[ \t]*[\w.$]*automaticallyUpdates(?:Background|Content)Configuration\s*=\s*\w+[ \t]*\n", re.M), ""),
]

changed = 0
for arg in sys.argv[1:]:
    p = Path(arg)
    for f in [p] if p.is_file() else sorted(p.rglob("*.swift")):
        if "LegacyCompat/Sources" in str(f):
            continue
        old = f.read_text()
        new = old
        for pattern, repl in RULES:
            new = pattern.sub(repl, new)
        if new != old:
            f.write_text(add_import(new))
            changed += 1
print(f"rewrote {changed} file(s)")
