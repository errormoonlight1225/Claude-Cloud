#!/bin/sh
# Assemble macboot.img: GRUB EFI (installed by Buildroot into $BINARIES_DIR/efi-part)
# + kernel + squashfs root + data partition.
set -e
BOARD_DIR="$(dirname "$0")"
cp "$BOARD_DIR/grub.cfg" "$BINARIES_DIR/efi-part/EFI/BOOT/grub.cfg"

rm -rf "${BUILD_DIR}/genimage.tmp"
genimage --rootpath "$TARGET_DIR" --tmppath "${BUILD_DIR}/genimage.tmp" \
         --inputpath "$BINARIES_DIR" --outputpath "$BINARIES_DIR" \
         --config "$BOARD_DIR/genimage.cfg"
