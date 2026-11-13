#!/usr/bin/env bash
# The relocation, proven with the real toolchain and the real dynamic loader
# (macOS only): build a library whose install name is under /var/jb and a
# program that links it, relocate the tree, and run the program from where the
# tree really is. Before relocating it cannot start; afterwards it must.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
mkdir -p "$t/usr/lib" "$t/usr/bin"

echo 'int seven(void) { return 7; }' | \
  clang -x c - -dynamiclib -install_name /var/jb/usr/lib/libseven.dylib -o "$t/usr/lib/libseven.dylib"
echo 'int seven(void); int main(void) { return seven(); }' | \
  clang -x c - -L"$t/usr/lib" -lseven -Wl,-rpath,/var/jb/usr/lib -o "$t/usr/bin/prog"

set +e; "$t/usr/bin/prog" 2>/dev/null; before=$?; set -e
[ "$before" -ne 7 ] || { echo "test is void: the program runs without relocation" >&2; exit 1; }

python3 -I "$here/relocate-macho.py" "$t" --verbose --changed="$t/changed"
grep -qx 'usr/bin/prog' "$t/changed"
otool -L "$t/usr/bin/prog" | grep -q '@loader_path/../lib/libseven.dylib'
otool -l "$t/usr/bin/prog" | grep -A2 LC_RPATH | grep -q '@loader_path/../lib'
otool -D "$t/usr/lib/libseven.dylib" | grep -q '^/var/jb/usr/lib/libseven.dylib$'

codesign -f -s - "$t/usr/bin/prog" 2>/dev/null
set +e; "$t/usr/bin/prog"; after=$?; set -e
[ "$after" -eq 7 ] || { echo "relocated program exited $after, expected 7" >&2; exit 1; }
echo "ok: the relocated program loads its library from $t"
