#!/usr/bin/env bash
# Assemble the rootless /var/jb bootstrap tarball that the ROM's NXRomInstaller
# extracts on flash. Entries are relative to /var/jb.
#
#   scripts/make-bootstrap.sh <out-tar> [tools-dir]
#
# tools-dir holds the built nxlaunchctl and nxfixup (any that exist are
# installed).
#
# Without a strap this ships only the committed overlay (rom-overlay/bootstrap):
# the dpkg/apt rootless configuration and an empty package database. With
# STRAP_TAR pointing at a Procursus rootless bootstrap archive, its contents
# become /var/jb and the overlay only adds what the strap does not have (so the
# strap's own dpkg database and apt sources win).
#
#   STRAP_TAR=~/bootstrap.tar.zst scripts/make-bootstrap.sh out.tar
#   STRAP_STRIP=N   strip N leading path components. Not needed for an archive
#                   laid out as var/jb/... (Procursus) or rooted at /var/jb.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: make-bootstrap.sh <out-tar> [tools-dir]}
tools_dir=${2:-}
strap_tar=${STRAP_TAR:-}
strap_strip=${STRAP_STRIP:-}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
stage=$work/jb
mkdir -p "$stage"

# 1. a real Procursus strap first, if given, so its files are the base layer.
if [ -n "$strap_tar" ]; then
  [ -f "$strap_tar" ] || { echo "make-bootstrap: STRAP_TAR not found: $strap_tar" >&2; exit 1; }
  unzstd() {
    if command -v zstd >/dev/null; then zstd -dc -- "$1"
    elif python3 -c 'import zstandard' 2>/dev/null; then
      python3 -I -c 'import sys, zstandard; zstandard.ZstdDecompressor().copy_stream(open(sys.argv[1], "rb"), sys.stdout.buffer)' "$1"
    else echo "make-bootstrap: need zstd (or the python zstandard module) to read $1" >&2; return 1
    fi
  }
  decomp() {
    case "$1" in
      *.tar)            cat -- "$1" ;;
      *.tar.gz|*.tgz)   gzip -dc -- "$1" ;;
      *.tar.xz|*.txz)   xz -dc -- "$1" ;;
      *.tar.zst|*.tzst) unzstd "$1" ;;
      *.tar.bz2|*.tbz2) bzip2 -dc -- "$1" ;;
      *.tar.lzma)       xz -dc --format=lzma -- "$1" ;;
      *) echo "make-bootstrap: unknown strap format: $1" >&2; return 1 ;;
    esac
  }
  mkdir "$work/strap"
  decomp "$strap_tar" | tar -x ${strap_strip:+--strip-components="$strap_strip"} -C "$work/strap" -f -
  # the tree that is /var/jb: var/jb inside the archive, or the archive itself
  root=$work/strap
  if [ -z "$strap_strip" ] && [ -d "$work/strap/var/jb" ]; then root=$work/strap/var/jb; fi
  [ -d "$root/usr" ] || { echo "make-bootstrap: $strap_tar does not look like a /var/jb tree (no usr/); set STRAP_STRIP" >&2; exit 1; }
  rmdir "$stage" && mv "$root" "$stage"
  echo "make-bootstrap: strap $(basename "$strap_tar"): $(find "$stage" | wc -l | tr -d ' ') entries"
fi

# 2. links and library paths. The real kernel and the dynamic loader resolve
#    these themselves, and inside Nyxian there is no real /var/jb: absolute
#    /var/jb link targets become relative, and binaries name their libraries
#    relative to themselves. (Before the overlay, which needs the links to work
#    here: Procursus has var/lib/dpkg -> /var/jb/Library/dpkg.)
changed=$work/changed
python3 -I "$here/scripts/relocate-macho.py" "$stage" --changed="$changed" || \
  echo "make-bootstrap: WARNING: some binaries could not be relocated (listed above); they will not load" >&2

# 3. the committed overlay, WITHOUT replacing anything the strap provides.
python3 -I - "$here/rom-overlay/bootstrap" "$stage" <<'PY'
import os, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
for directory, _, names in os.walk(src):
    rel = os.path.relpath(directory, src)
    target = os.path.normpath(os.path.join(dst, rel))
    os.makedirs(target, exist_ok=True)          # follows the strap's (now relative) links
    for name in names:
        if not os.path.lexists(os.path.join(target, name)):
            shutil.copy2(os.path.join(directory, name), os.path.join(target, name))
PY

# 4. the standard rootless runtime directories (mkdir -p never clobbers)
mkdir -p \
  "$stage/usr/bin" "$stage/usr/lib" "$stage/usr/libexec" \
  "$stage/var/cache/apt/archives/partial" \
  "$stage/var/lib/apt/lists/partial" \
  "$stage/var/lib/dpkg/info" "$stage/var/lib/dpkg/updates" "$stage/var/lib/dpkg/triggers" \
  "$stage/var/log" "$stage/var/run" "$stage/var/db" "$stage/tmp" \
  "$stage/Library/LaunchDaemons" "$stage/Applications"

# 5. this project's own tools, if built: nxlaunchctl and the tool dpkg runs to
#    relocate and sign.
included=
if [ -n "$tools_dir" ]; then
  for tool in bin/nxlaunchctl libexec/nxfixup; do
    if [ -f "$tools_dir/${tool##*/}" ]; then
      install -m755 "$tools_dir/${tool##*/}" "$stage/usr/$tool"
      included="$included ${tool##*/}"
    fi
  done
fi
echo "make-bootstrap: own tools included:${included:- none (no tools dir)}"

# `launchctl` is what package scripts call to load their daemons, and here the
# service manager is nxlaunchd. Procursus' launchctl (which talks to Apple's
# launchd) is moved aside with a dpkg diversion, so that an update of that
# package does not put it back.
if [ -f "$stage/usr/bin/nxlaunchctl" ]; then
  if [ -f "$stage/usr/bin/launchctl" ] && [ ! -L "$stage/usr/bin/launchctl" ]; then
    mv "$stage/usr/bin/launchctl" "$stage/usr/bin/launchctl.procursus"
    printf '%s\n' /var/jb/usr/bin/launchctl /var/jb/usr/bin/launchctl.procursus : \
      >> "$stage/var/lib/dpkg/diversions"
    echo "make-bootstrap: launchctl diverted to launchctl.procursus"
  fi
  ln -sf nxlaunchctl "$stage/usr/bin/launchctl"
fi

# 6. sign what step 2 rewrote (its old signature no longer matches). Optional:
#    nxfixup signs everything with the user's certificate on the first boot.
if [ -s "$changed" ]; then
  if command -v ldid >/dev/null; then
    while IFS= read -r f; do ldid -S "$stage/$f"; done < "$changed"
    echo "make-bootstrap: signed $(wc -l < "$changed" | tr -d ' ') relocated file(s) with ldid"
  else
    echo "make-bootstrap: ldid not found; the relocated binaries keep a stale signature until the first boot"
  fi
fi

# 7. a ustar tar when the paths are short, pax when the strap has long ones.
# Both are understood by GNU tar and macOS bsdtar and by the installer's reader.
fmt=ustar
if [ -n "$strap_tar" ]; then fmt=pax; fi
tar --format=$fmt -C "$stage" -cf "$out" .
echo "make-bootstrap: wrote $out ($(wc -c < "$out" | tr -d ' ') bytes, format $fmt)"
