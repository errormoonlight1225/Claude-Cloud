#!/bin/bash
# Builds out/rom.zip: fetches Nyxian, bakes its ROM template, adds the rootless
# /var/jb bootstrap and its installer, then compiles and signs it.
#
#   scripts/build.sh            the whole build (macOS with Xcode)
#   scripts/build.sh generate   stop after the template + bootstrap tar (any OS)
#   scripts/build.sh fetch      only fetch Nyxian (.build/nyxian, with RomGen.py)
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
[ "$stage" = fetch ] && exit 0

key=${ROM_SIGNING_KEY:-}
if [ -z "$key" ]; then
    key=$build/key/throwaway.key.pem
    [ -f "$key" ] || romgen genkey --name throwaway --out "$build/key" >/dev/null
    echo "warning: ROM_SIGNING_KEY is not set, signing with a throwaway key (not bootable)" >&2
fi

# --- template + manifest + bootstrap (portable, no Xcode needed) ---
romgen generate "$nyxian" "$rom" --identifier "$ROM_IDENTIFIER" --name "$ROM_NAME" \
    --min-nyxian "$ROM_MIN_NYXIAN" --key "$key"
python3 -I "$root/scripts/set-manifest.py" "$rom/manifest.plist" "$ROM_VERSION" "$ROM_SECURITY_VERSION"

mkdir -p "$rom/bootstrap"
"$root/scripts/make-bootstrap.sh" "$rom/bootstrap/bootstrap.tar"

[ "$stage" = generate ] && exit 0

# --- native build (macOS + Xcode) ---
# the ROM's kernel surface and the sample app, via the generated Makefile
make -C "$rom" -j"$(getconf _NPROCESSORS_ONLN)" main 'Application/Hello.app/Hello' \
    ROM_SIGNING_KEY="$key"
# the NXRomInstaller dylib
make -C "$root/rom-overlay/installer" ios
cp "$root/rom-overlay/installer/build/installer" "$rom/installer"

# --- assemble and sign the ROM zip (installer + bootstrap included) ---
mkdir -p "$root/out"
out=$root/out/rom.zip
pkg=$rom/.rompkg
rm -rf "$pkg" "$out"
mkdir -p "$pkg/ROM/bootstrap"
cp "$rom/main" "$rom/manifest.plist" "$rom/installer" "$pkg/ROM/"
cp -R "$rom/Application" "$pkg/ROM/Application"
cp "$rom/bootstrap/bootstrap.tar" "$pkg/ROM/bootstrap/bootstrap.tar"
( cd "$pkg" && zip -qry -X "$out" ROM -x '*.DS_Store' '*/._*' )
rm -rf "$pkg"

romgen sign "$out" --key "$key"
romgen public "$key" > "$build/signer.pub.pem"
romgen verify "$out" --public "$build/signer.pub.pem"
romgen info "$out"
romgen digest "$out"
