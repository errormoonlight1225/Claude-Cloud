#!/bin/bash
# Build reims-vgpu's library, its QEMU fork and reims-ctl on Ubuntu 24.04 into <out>:
#   <out>/qemu/...   staged QEMU install prefix (bin/qemu-system-x86_64, share/qemu/ReimsVgpu.rom, ...)
#   <out>/bin/reims-ctl
# Run it where it can reach github.com and static.rust-lang.org. About 40 minutes on 4 cores.
set -euo pipefail
OUT=$(mkdir -p "${1:?usage: $0 <out>}" && cd "$1" && pwd)
SRC=${SRC:-$OUT/src}
mkdir -p "$SRC" "$OUT/bin"
sudo apt-get update -qq
sudo apt-get install -y --no-install-recommends build-essential git curl ca-certificates pkg-config python3 python3-venv \
  ninja-build flex bison bzip2 cmake clang lld binutils libglib2.0-dev libpixman-1-dev libslirp-dev zlib1g-dev \
  libfdt-dev libusb-1.0-0-dev libvulkan1 libvulkan-dev mesa-vulkan-drivers libx11-dev libxext-dev libxrandr-dev \
  libxcursor-dev libxi-dev libxfixes-dev libxss-dev libxtst-dev libxkbcommon-dev libwayland-dev libwayland-bin \
  libdecor-0-dev libegl-dev libgl-dev libdrm-dev libgbm-dev libdbus-1-dev libudev-dev
command -v rustup >/dev/null || { echo "install rustup first: https://rustup.rs"; exit 1; }

[ -d "$SRC/reims-vgpu" ] || git clone --depth 1 https://github.com/steelbrain/reims-vgpu.git "$SRC/reims-vgpu"
R=$SRC/reims-vgpu
(cd "$R" && CARGO_TARGET_DIR="$R/target" cargo xtask dist)            # the library (Vulkan platform)
git -C "$R" submodule update --init --depth 1 vendor/qemu
mkdir -p "$SRC/qemu-build" && cd "$SRC/qemu-build"
PKG_CONFIG_PATH="$R/target/dist-vulkan/lib/pkgconfig" "$R/vendor/qemu/configure" --prefix=/macboot-qemu \
  --target-list=x86_64-softmmu --enable-kvm --enable-pvg --enable-slirp --disable-sdl --disable-gtk \
  --disable-docs --disable-tests --disable-werror
ninja -j"$(nproc)"
rm -rf "$SRC/qemu-stage"; DESTDIR="$SRC/qemu-stage" ninja install >/dev/null
rm -rf "$OUT/qemu"; cp -a "$SRC/qemu-stage/macboot-qemu" "$OUT/qemu"
(cd "$R" && CARGO_TARGET_DIR="$SRC/ctl-target" cargo install --locked --force --path crates/reims-ctl --root "$OUT")
"$OUT/qemu/bin/qemu-system-x86_64" -device help 2>&1 | grep -q 'apple-gfx-pci' || { echo "QEMU has no apple-gfx-pci"; exit 1; }
echo "done: $OUT (reims-util is NOT included; see README.md)"
