#!/bin/bash
# Builds out/rom.zip: fetches Nyxian, bakes its ROM template, adds the rootless
# /var/jb bootstrap, its installer and the /var/jb path layer, then compiles and
# signs it.
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
# this ROM's own kernel sources, over the generated template: the shim cache step
# that installs the /var/jb path layer (rtpatch) for every guest process
shimcache=$rom/rom/src/LindChain/ProcEnvironment/Surface/cache/shimcache.m
[ -f "$shimcache" ] || { echo "build: the ROM template has no shimcache.m to replace" >&2; exit 1; }
cp "$root/rom-overlay/kernel/shimcache.m" "$shimcache"
# ... the policy for what lives in /var/jb, and the home screen that lists its apps
mkdir -p "$rom/rom/src/Rootless"
cp "$root/rom-overlay/kernel/rootless.m" "$rom/rom/src/Rootless/rootless.m"
python3 -I "$root/scripts/patch-rom.py" "$rom/rom/src"

# fetch URL SHA256 FILE: download unless FILE is already the right one; a file
# that does not match its hash stops the build.
sha256() { if command -v shasum >/dev/null; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
fetch() {
    if [ ! -f "$3" ] || [ "$(sha256 "$3")" != "$2" ]; then
        mkdir -p "$(dirname "$3")"
        curl -fsSL --retry 3 -o "$3.part" "$1"
        mv "$3.part" "$3"
    fi
    actual=$(sha256 "$3")
    if [ "$actual" != "$2" ]; then
        echo "build: $1 has SHA-256 $actual, rom.conf expects $2" >&2
        echo "build: if a new version was published, check it and update the hash in rom.conf" >&2
        exit 1
    fi
}

# the Procursus bootstrap, unless STRAP_TAR already names one
if [ -z "${STRAP_TAR:-}" ] && [ -n "${STRAP_URL:-}" ]; then
    fetch "$STRAP_URL" "$STRAP_SHA256" "$build/strap/${STRAP_URL##*/}"
    export STRAP_TAR=$build/strap/${STRAP_URL##*/}
fi

# the packages installed on the first boot
export FIRSTBOOT_DEB_DIR=$build/debs
rm -rf "$FIRSTBOOT_DEB_DIR" && mkdir -p "$FIRSTBOOT_DEB_DIR"
while read -r url hash; do
    [ -n "$url" ] || continue
    fetch "$url" "$hash" "$build/debs-cache/${url##*/}"
    cp "$build/debs-cache/${url##*/}" "$FIRSTBOOT_DEB_DIR/"
done <<DEBS
${FIRSTBOOT_DEBS:-}
DEBS

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
# the /var/jb path layer, loaded by every guest process
make -C "$root/src/rtpatch" ios
cp "$root/src/rtpatch/build/rtpatch" "$rom/rtpatch"
# the service supervisor, in the slot (the ROM's kernel starts it at boot)
make -C "$root/src" slot
mkdir -p "$rom/Application/libexec"
cp "$root/src/build/slot/nxlaunchd" "$rom/Application/libexec/nxlaunchd"
# this project's tools that live in /var/jb, then the bootstrap again with them
make -C "$root/src" ios
make -C "$root/src/fixup" ios
make -C "$root/src/stubs" ios
tools=$build/tools
rm -rf "$tools" && mkdir -p "$tools"
cp "$root/src/build/nxlaunchctl" "$root/src/fixup/build/nxfixup" "$root/src/stubs/build/nxnoop" "$tools/"
"$root/scripts/make-bootstrap.sh" "$rom/bootstrap/bootstrap.tar" "$tools"

# --- assemble and sign the ROM zip (installer + bootstrap included) ---
mkdir -p "$root/out"
out=$root/out/rom.zip
pkg=$rom/.rompkg
rm -rf "$pkg" "$out"
mkdir -p "$pkg/ROM/bootstrap"
cp "$rom/main" "$rom/manifest.plist" "$rom/installer" "$rom/rtpatch" "$pkg/ROM/"
cp -R "$rom/Application" "$pkg/ROM/Application"
cp "$rom/bootstrap/bootstrap.tar" "$pkg/ROM/bootstrap/bootstrap.tar"
( cd "$pkg" && zip -qry -X "$out" ROM -x '*.DS_Store' '*/._*' )
rm -rf "$pkg"

romgen sign "$out" --key "$key"
romgen public "$key" > "$build/signer.pub.pem"
romgen verify "$out" --public "$build/signer.pub.pem"
romgen info "$out"
romgen digest "$out"
