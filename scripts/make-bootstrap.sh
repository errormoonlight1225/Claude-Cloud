#!/usr/bin/env bash
# Assemble the rootless /var/jb bootstrap tarball that the ROM's NXRomInstaller
# extracts on flash. Entries are relative to /var/jb.
#
#   scripts/make-bootstrap.sh <out-tar> [tools-dir]
#
# tools-dir holds the built nxlaunchd, nxlaunchctl and nxfixup (any that exist
# are installed).
#
# Without a strap this ships the committed skeleton (rom-overlay/bootstrap): the
# dpkg/apt rootless configuration and an empty package database. To install a
# real rootless userland (apt, dpkg, bash, ...), point STRAP_TAR at a Procursus
# rootless bootstrap archive; its contents become /var/jb and the skeleton only
# fills what the strap does not provide (so the strap's own dpkg database wins).
#
#   STRAP_TAR=~/bootstrap.tar.zst scripts/make-bootstrap.sh out.tar
#   STRAP_STRIP=2 ...   strip N leading path components (if the strap is not
#                       already rooted at /var/jb, e.g. entries like ./var/jb/..)
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: make-bootstrap.sh <out-tar> [tools-dir]}
launchd_dir=${2:-}
strap_tar=${STRAP_TAR:-}
strap_strip=${STRAP_STRIP:-0}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# 1. a real Procursus strap first, if given, so its files are the base layer.
if [ -n "$strap_tar" ]; then
  [ -f "$strap_tar" ] || { echo "make-bootstrap: STRAP_TAR not found: $strap_tar" >&2; exit 1; }
  decomp() {
    case "$1" in
      *.tar)            cat -- "$1" ;;
      *.tar.gz|*.tgz)   gzip -dc -- "$1" ;;
      *.tar.xz|*.txz)   xz -dc -- "$1" ;;
      *.tar.zst|*.tzst) zstd -dc -- "$1" ;;
      *.tar.bz2|*.tbz2) bzip2 -dc -- "$1" ;;
      *.tar.lzma)       xz -dc --format=lzma -- "$1" ;;
      *) echo "make-bootstrap: unknown strap format: $1" >&2; return 1 ;;
    esac
  }
  # tool availability
  case "$strap_tar" in
    *.zst|*.tzst) command -v zstd  >/dev/null || { echo "make-bootstrap: need zstd to read $strap_tar" >&2; exit 1; } ;;
    *.xz|*.txz|*.lzma) command -v xz >/dev/null || { echo "make-bootstrap: need xz to read $strap_tar" >&2; exit 1; } ;;
  esac
  echo "make-bootstrap: extracting strap $strap_tar (strip=$strap_strip)"
  decomp "$strap_tar" | tar -x --strip-components="$strap_strip" -C "$stage" -f -
fi

# 2. the committed skeleton, WITHOUT clobbering anything the strap provided
#    (a real strap already has its dpkg database, sources and arch).
cp -Rn "$here/rom-overlay/bootstrap/." "$stage/" 2>/dev/null || \
  cp -R -n "$here/rom-overlay/bootstrap/." "$stage/"
rm -f "$stage/Library/LaunchDaemons/.keep"

# 3. the standard rootless runtime directories (mkdir -p never clobbers)
mkdir -p \
  "$stage/usr/bin" "$stage/usr/lib" "$stage/usr/libexec" \
  "$stage/var/cache/apt/archives/partial" \
  "$stage/var/lib/apt/lists/partial" \
  "$stage/var/lib/dpkg/info" "$stage/var/lib/dpkg/updates" "$stage/var/lib/dpkg/triggers" \
  "$stage/var/log" "$stage/var/run" "$stage/var/db" "$stage/tmp" \
  "$stage/Library/LaunchDaemons" "$stage/Applications"

# 4. this project's own tools, if built (overwrite any strap copy on purpose):
#    the service supervisor and the tool dpkg runs to relocate and sign.
included=
if [ -n "$launchd_dir" ]; then
  for tool in libexec/nxlaunchd bin/nxlaunchctl libexec/nxfixup; do
    if [ -f "$launchd_dir/${tool##*/}" ]; then
      install -m755 "$launchd_dir/${tool##*/}" "$stage/usr/$tool"
      included="$included ${tool##*/}"
    fi
  done
fi
echo "make-bootstrap: own tools included:${included:- none (no build dir)}"

# 5. library paths. Binaries name their libraries as /var/jb/usr/lib/..., which
#    the dynamic loader opens itself (the path layer never sees it) and which
#    does not exist inside Nyxian: rewrite them relative to each binary, then
#    sign the rewritten files again (their old signature no longer matches).
changed=$(mktemp)
python3 -I "$here/scripts/relocate-macho.py" "$stage" --changed="$changed" || \
  echo "make-bootstrap: WARNING: some binaries could not be relocated (listed above); they will not load" >&2
if [ -s "$changed" ]; then
  if command -v ldid >/dev/null; then
    while IFS= read -r f; do ldid -S "$stage/$f"; done < "$changed"
    echo "make-bootstrap: signed $(wc -l < "$changed" | tr -d ' ') relocated file(s) with ldid"
  else
    echo "make-bootstrap: WARNING: ldid not found; the relocated binaries are left with a stale signature" >&2
  fi
fi
rm -f "$changed"

# 6. a ustar tar when the paths are short, pax when the strap has long ones.
# Both are understood by GNU tar and macOS bsdtar and by the installer's reader.
fmt=ustar
if [ -n "$strap_tar" ]; then fmt=pax; fi
tar --format=$fmt -C "$stage" -cf "$out" .
echo "make-bootstrap: wrote $out ($(wc -c < "$out") bytes, format $fmt)"
