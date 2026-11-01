#!/bin/sh
# Trim the target and add the Xe GPU firmware that Buildroot 2025.02's i915 option omits.
set -e
TARGET_DIR="$1"
rm -rf "$TARGET_DIR/usr/share/man" "$TARGET_DIR/usr/share/doc" "$TARGET_DIR/usr/share/info"
install -d "$TARGET_DIR/data"

# xe/ firmware (Lunar Lake, Arc B-series, ...) lives next to i915/ in linux-firmware.
for d in "$BUILD_DIR"/linux-firmware-*/xe; do
    [ -d "$d" ] && { install -d "$TARGET_DIR/lib/firmware/xe"; cp -a "$d"/. "$TARGET_DIR/lib/firmware/xe/"; }
done
exit 0
