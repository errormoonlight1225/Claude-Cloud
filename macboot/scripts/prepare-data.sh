#!/bin/bash
# Fill the MACDATA partition of a built macboot.img with everything the guest needs:
# OpenCore, OVMF firmware and the macOS recovery installer.
#
#   sudo scripts/prepare-data.sh output/images/macboot.img [size_GB=160] [macOS=sonoma]
#
# Needs: git python3 dmg2img qemu-utils util-linux e2fsprogs  (run on the *build* machine, not the target)
# You must own Apple hardware / accept Apple's macOS licence terms to use the downloaded installer.
set -euo pipefail

IMG=${1:?usage: $0 macboot.img [size_GB] [macOS shortname]}
SIZE_GB=${2:-160}
MACOS=${3:-sonoma}
[ "$(id -u)" = 0 ] || { echo "run as root (needs losetup/mount)"; exit 1; }

WORK=$(mktemp -d); MNT=$WORK/mnt; LOOP=""
cleanup() { mountpoint -q "$MNT" 2>/dev/null && umount "$MNT"; [ -n "$LOOP" ] && losetup -d "$LOOP"; rm -rf "$WORK"; }
trap cleanup EXIT
mkdir -p "$MNT"

echo ">> growing image to ${SIZE_GB}G and extending partition 3"
truncate -s "${SIZE_GB}G" "$IMG"
echo ", +" | sfdisk --no-reread -N 3 "$IMG" >/dev/null
LOOP=$(losetup -Pf --show "$IMG")
mkfs.ext4 -q -L MACDATA -m 0 -O ^has_journal "${LOOP}p3"
mount -o noatime "${LOOP}p3" "$MNT"

echo ">> fetching OpenCore + OVMF from OSX-KVM"
git clone --depth 1 https://github.com/kholia/OSX-KVM.git "$WORK/osx-kvm"
mkdir -p "$MNT/OpenCore" "$MNT/OVMF"
cp "$WORK/osx-kvm/OpenCore/OpenCore.qcow2" "$MNT/OpenCore/"
cp "$WORK/osx-kvm/OVMF_CODE_4M.fd"         "$MNT/OVMF/OVMF_CODE_4M.fd"
cp "$WORK/osx-kvm/OVMF_VARS-1920x1080.fd"  "$MNT/OVMF/OVMF_VARS.fd"

echo ">> downloading macOS recovery ($MACOS) from Apple"
( cd "$WORK/osx-kvm" && python3 fetch-macOS-v2.py --shortname "$MACOS" )
dmg2img -i "$WORK/osx-kvm/BaseSystem.dmg" "$MNT/BaseSystem.img"

cat > "$MNT/macboot.conf" <<CONF
GUEST_RAM=8G
SYSTEM_DISK_SIZE=$((SIZE_GB - 20))G
CONF
sync
echo ">> done. Write $IMG to the target disk (dd/Etcher). First boot installs macOS from BaseSystem.img;"
echo "   delete /data/BaseSystem.img afterwards (macboot.shell=1 -> rm /data/BaseSystem.img)."
