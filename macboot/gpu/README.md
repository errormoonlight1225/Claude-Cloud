# MacBoot GPU edition

Ubuntu 24.04 minimal host that boots straight into a fullscreen macOS VM with **3D acceleration** through
[reims-vgpu](https://github.com/steelbrain/reims-vgpu): macOS loads its own `AppleParavirtGPU` driver, the host
translates the Metal command stream to **Vulkan** and runs it on the host GPU (Intel Iris Xe via Mesa `anv`).
No software-rendering fallback is built in.

## Status: read this first

| Piece | Verified how | Result |
|---|---|---|
| reims-vgpu library, Linux x86-64 Vulkan build | built from source in a clean container | builds |
| reims-vgpu QEMU fork with `apple-gfx-pci` | built from source, `-device help` | present |
| `apple-gfx-pci` initialises on a Vulkan driver | headless run on **llvmpipe** (CPU Vulkan), PCI `106b:eeee` appears | works |
| Same on **Intel Iris Xe (anv)** | **not tested: no Intel GPU, no KVM in the build environment** | **unknown** |
| macOS guest boots and shows a Metal desktop | **not tested** | unknown |
| Image boots to the MacBoot session | see "Boot test" below | see below |

Nobody has published a result of reims-vgpu on an Intel iGPU. The upstream project reports x86-64 macOS 26 on an
NVIDIA RTX 5080 laptop GPU and ~25-30 presents/s on another independent implementation. Expect a usable but not fast
desktop at best, and expect to debug on first run.

## Memory

The old target (host overhead under 512 MB, ideally 256 MB) was set for a Buildroot host with no GPU stack. Vulkan
(Mesa anv), a Wayland compositor (cage), the reims library with its Vulkan runtime and QEMU cost more than that. The
host overhead of this edition is **not measured yet**; run `macboot-mem` on the target and report the number.

## Build

On Ubuntu 24.04 (the same release the image uses, so the binaries match its libraries):

```sh
sudo apt-get install debootstrap grub-efi-amd64-bin dosfstools mtools e2fsprogs fdisk mount binutils   # image builder
./build-reims.sh  out/reims            # reims-vgpu library, its QEMU, reims-ctl   (about 40 min)
sudo ./build-image.sh out/reims out/macboot-gpu.img 16
```

`reims-util` (a separate repository, `steelbrain/reims-util`) makes the VM's OpenCore image and downloads the macOS
installer from Apple. Build it yourself (`cargo install --locked --git https://github.com/steelbrain/reims-util
--root out/reims`) so that `out/reims/bin/reims-util` exists before `build-image.sh`; without it the image still
boots but cannot create the VM.

## First run on the target

1. Write the image to a disk (this erases it) and boot it with UEFI; enable VT-x in the firmware.
2. tty1 checks the machine (`reims-ctl doctor`), then, with a network connection (wired automatically; Wi-Fi on
   Alt+F2 with `iwctl`), creates the VM and downloads the installer from Apple (about 1 GB).
3. The VM boots into macOS Recovery in a fullscreen window: erase its disk in Disk Utility (APFS), Reinstall macOS.
4. **Once**, set Metal's error mode or the desktop will not appear (upstream documents this in its README, "Set
   Metal's error mode in the guest"). From Recovery's Terminal:
   `cd /Volumes/*Data/Library/Preferences && defaults write "$PWD/.GlobalPreferences" METAL_ERROR_MODE -int 5 && chmod 644 .GlobalPreferences.plist && reboot`
   (OpenCore's picker must be on to reach Recovery: `reims-ctl update-opencore mac --boot-selection`, from tty2.)

State lives on the MACDATA partition (`/data/reims`), so the root can be rebuilt without losing the VM.

## Legal

macOS is licensed only for Apple-branded hardware. This repository contains no Apple software; the installer is
downloaded from Apple's servers on your machine.
