#!/bin/bash
# Builds out/rom.zip: fetches Nyxian, bakes its ROM template, compiles and signs it.
#
#   scripts/build.sh            the whole build (macOS with Xcode)
#   scripts/build.sh generate   stop after the template (.build/rom), works on any OS
#
# ROM_SIGNING_KEY: your private ROM key (NAME.key.pem). Without it the ROM is signed
# with a throwaway key: it builds and verifies, but Nyxian will not boot it until
# you sign it again with a key in the TrustStore (RomGen.py sign).
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/rom.conf"
build=$root/.build
nyxian=$build/nyxian
rom=$build/rom
stage=${1:-all}

mkdir -p "$build"
if [ "$(git -C "$nyxian" rev-parse HEAD 2>/dev/null || true)" != "$NYXIAN_REF" ]; then
    rm -rf "$nyxian"
    git init -q "$nyxian"
    git -C "$nyxian" fetch -q --depth 1 "$NYXIAN_REPO" "$NYXIAN_REF"
    git -C "$nyxian" checkout -q FETCH_HEAD
fi
romgen() { python3 -I "$nyxian/RomGen.py" "$@"; }

key=${ROM_SIGNING_KEY:-}
if [ -z "$key" ]; then
    key=$build/key/throwaway.key.pem
    [ -f "$key" ] || romgen genkey --name throwaway --out "$build/key" >/dev/null
    echo "warning: ROM_SIGNING_KEY is not set, signing with a throwaway key (not bootable)" >&2
fi

romgen generate "$nyxian" "$rom" --identifier "$ROM_IDENTIFIER" --name "$ROM_NAME" \
    --min-nyxian "$ROM_MIN_NYXIAN" --key "$key"
python3 -I "$root/scripts/set-manifest.py" "$rom/manifest.plist" "$ROM_VERSION" "$ROM_SECURITY_VERSION"
[ "$stage" = generate ] && exit 0

mkdir -p "$root/out"
make -C "$rom" -j"$(getconf _NPROCESSORS_ONLN)" ROM_OUT="$root/out/rom.zip" ROM_SIGNING_KEY="$key"
romgen public "$key" > "$build/signer.pub.pem"
romgen verify "$root/out/rom.zip" --public "$build/signer.pub.pem"
romgen info "$root/out/rom.zip"
romgen digest "$root/out/rom.zip"
