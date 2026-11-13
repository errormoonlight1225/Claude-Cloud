#!/usr/bin/env bash
# Assemble the rootless /var/jb bootstrap tarball that the ROM's NXRomInstaller
# extracts on flash. Entries are relative to /var/jb.
#
#   scripts/make-bootstrap.sh <out-tar> [launchd-build-dir]
#
# The committed skeleton (rom-overlay/bootstrap) carries the dpkg/apt rootless
# configuration; this script adds the empty runtime directories git cannot keep
# and, if a launchd build directory is given, the nxlaunchd/nxlaunchctl binaries.
# Drop a full Procursus rootless bootstrap in place of this skeleton later.
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
out=${1:?usage: make-bootstrap.sh <out-tar> [launchd-build-dir]}
launchd_dir=${2:-}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# 1. the committed skeleton (config, dpkg status)
cp -a "$here/rom-overlay/bootstrap/." "$stage/"
rm -f "$stage/Library/LaunchDaemons/.keep"

# 2. the standard rootless runtime directories
mkdir -p \
  "$stage/usr/bin" "$stage/usr/lib" "$stage/usr/libexec" \
  "$stage/var/cache/apt/archives/partial" \
  "$stage/var/lib/apt/lists/partial" \
  "$stage/var/lib/dpkg/info" "$stage/var/lib/dpkg/updates" "$stage/var/lib/dpkg/triggers" \
  "$stage/var/log" "$stage/var/run" "$stage/var/db" "$stage/tmp" \
  "$stage/Library/LaunchDaemons" "$stage/Applications"

# 3. the service supervisor, if built
if [ -n "$launchd_dir" ] && [ -f "$launchd_dir/nxlaunchd" ]; then
  install -m755 "$launchd_dir/nxlaunchd"  "$stage/usr/libexec/nxlaunchd"
  install -m755 "$launchd_dir/nxlaunchctl" "$stage/usr/bin/nxlaunchctl"
  echo "make-bootstrap: included nxlaunchd/nxlaunchctl"
else
  echo "make-bootstrap: no launchd build dir (skipping nxlaunchd)"
fi

# 4. a ustar tar, entries relative to /var/jb, reproducible-ish ordering.
# ustar is understood by both GNU tar and macOS bsdtar; the skeleton's paths are
# short. A full Procursus strap is dropped in as its own tar (pax is fine too:
# the installer's extractor understands pax long names).
tar --format=ustar -C "$stage" -cf "$out" .
echo "make-bootstrap: wrote $out ($(wc -c < "$out") bytes)"
