#!/bin/bash
# Build the MacBoot GPU edition: an Ubuntu 24.04 minimal system that boots to a fullscreen macOS VM
# with reims-vgpu 3D acceleration (Vulkan on the host GPU, e.g. Intel Iris Xe via Mesa anv).
#
#   sudo ./build-image.sh <reims-dir> <out.img> [size_GB=12]
#
# <reims-dir> holds what build-reims.sh produced:
#   qemu/bin/qemu-system-x86_64, qemu/share/...   (the reims-vgpu QEMU, a staged install prefix)
#   bin/reims-ctl                                  (required)
#   bin/reims-util                                 (optional here, required to create the VM at first run)
#
# Needs on the build machine: debootstrap grub-efi-amd64-bin dosfstools mtools e2fsprogs fdisk mount binutils.
set -euo pipefail

REIMS=$(cd "${1:?usage: $0 <reims-dir> <out.img> [size_GB]}" && pwd)
OUT=${2:?usage: $0 <reims-dir> <out.img> [size_GB]}
SIZE_GB=${3:-12}
SUITE=noble
MIRROR=${MIRROR:-http://archive.ubuntu.com/ubuntu}
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
for c in debootstrap grub-mkimage mkfs.vfat mkfs.ext4 sfdisk losetup strip mcopy; do
    command -v "$c" >/dev/null || { echo "missing '$c' on the build machine: apt-get install debootstrap grub-efi-amd64-bin dosfstools mtools e2fsprogs fdisk mount binutils"; exit 1; }
done
[ -x "$REIMS/qemu/bin/qemu-system-x86_64" ] || { echo "missing $REIMS/qemu/bin/qemu-system-x86_64"; exit 1; }
[ -x "$REIMS/bin/reims-ctl" ] || { echo "missing $REIMS/bin/reims-ctl"; exit 1; }

WORK=$(mktemp -d); M=$WORK/root; LOOPS=()
cleanup() {
    set +e
    for m in "$M/dev/pts" "$M/dev" "$M/proc" "$M/sys" "$M/run" "$M"; do mountpoint -q "$m" && umount -l "$m"; done
    for l in "${LOOPS[@]}"; do losetup -d "$l"; done
    rm -rf "$WORK"
}
trap cleanup EXIT
mkdir -p "$M"

# ---- partitions: ESP 256M | rootfs 6G | MACDATA (rest, grown to the disk at first boot)
ESP_START=2048;      ESP_SECT=$((256*2048))
ROOT_START=$((ESP_START+ESP_SECT)); ROOT_SECT=$((6*1024*2048))
DATA_START=$((ROOT_START+ROOT_SECT))
rm -f "$OUT"; truncate -s "${SIZE_GB}G" "$OUT"
sfdisk -q "$OUT" <<PT
label: gpt
start=$ESP_START, size=$ESP_SECT, type=U, name="ESP"
start=$ROOT_START, size=$ROOT_SECT, type=L, name="rootfs"
start=$DATA_START, type=L, name="macdata"
PT
total=$(( $(stat -c %s "$OUT") / 512 ))
DATA_SECT=$(( total - DATA_START - 34 ))
mkloop() { local l; l=$(losetup -f --show -o $(($1*512)) --sizelimit $(($2*512)) "$OUT"); LOOPS+=("$l"); echo "$l"; }
L_ESP=$(mkloop $ESP_START $ESP_SECT); L_ROOT=$(mkloop $ROOT_START $ROOT_SECT); L_DATA=$(mkloop $DATA_START $DATA_SECT)
mkfs.vfat -F32 -n ESP "$L_ESP" >/dev/null
mkfs.ext4 -q -L rootfs -m 0 "$L_ROOT"
mkfs.ext4 -q -L MACDATA -m 0 -O ^has_journal "$L_DATA"
mount "$L_ROOT" "$M"; mkdir -p "$M/boot/efi"   # the ESP is filled with mtools below, no vfat mount needed

# ---- base system
debootstrap --variant=minbase --components=main,universe \
    --include=systemd-sysv,dbus,libpam-systemd,systemd-resolved,udev,kmod,initramfs-tools,e2fsprogs,fdisk,util-linux,iproute2,iputils-ping,curl,ca-certificates,iwd,wpasupplicant,less,nano \
    "$SUITE" "$M" "$MIRROR"

mount -t proc proc "$M/proc"; mount -t sysfs sys "$M/sys"; mount --bind /dev "$M/dev"; mount -t devpts devpts "$M/dev/pts"; mount -t tmpfs tmpfs "$M/run"
printf '#!/bin/sh\nexit 101\n' > "$M/usr/sbin/policy-rc.d"; chmod +x "$M/usr/sbin/policy-rc.d"
cat > "$M/etc/apt/sources.list.d/ubuntu.sources" <<SRC
Types: deb
URIs: $MIRROR
Suites: $SUITE $SUITE-updates $SUITE-security
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SRC
echo macboot > "$M/etc/hostname"
printf 'LABEL=rootfs / ext4 defaults,noatime 0 1\nLABEL=ESP /boot/efi vfat umask=0077,nofail,x-systemd.device-bound=no 0 2\nLABEL=MACDATA /data ext4 defaults,noatime,nofail,x-systemd.device-bound=no 0 2\n' > "$M/etc/fstab"
mkdir -p "$M/data"

# The chroot needs the build machine's DNS and, if set, its proxy; resolv.conf is replaced at the end of this step.
rm -f "$M/etc/resolv.conf"; cp -L /etc/resolv.conf "$M/etc/resolv.conf"
PROXYENV=(); for v in http_proxy https_proxy no_proxy HTTP_PROXY HTTPS_PROXY NO_PROXY; do [ -n "${!v:-}" ] && PROXYENV+=("$v=${!v}"); done
chroot "$M" env "${PROXYENV[@]}" /bin/bash -euo pipefail -c '
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q --no-install-recommends \
    linux-image-generic linux-firmware \
    cage mesa-vulkan-drivers libvulkan1 vulkan-tools libegl1 libgbm1 libdrm2 \
    libglib2.0-0t64 libpixman-1-0 libslirp0 libfdt1 libusb-1.0-0 zlib1g \
    libxkbcommon0 libwayland-client0 libwayland-cursor0 libwayland-egl1 libdecor-0-0 libx11-6 libxext6 libxcursor1 libxi6 libxrandr2 libxfixes3 libxss1 libxtst6 libudev1 libdbus-1-3 \
    xwayland
useradd -m -u 1000 -s /bin/bash -G video,render,input,kvm,audio macboot
passwd -d macboot >/dev/null
systemctl mask apt-daily.timer apt-daily-upgrade.timer motd-news.timer e2scrub_all.timer fstrim.timer e2scrub_reap.service >/dev/null 2>&1 || true
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
'

# ---- MacBoot overlay, reims tools, QEMU
cp -a "$HERE/overlay/." "$M/"
mv "$M/home-macboot/.bash_profile" "$M/home/macboot/.bash_profile"; rmdir "$M/home-macboot"
chroot "$M" chown 1000:1000 /home/macboot/.bash_profile
chroot "$M" systemctl enable systemd-networkd systemd-resolved iwd macboot-firstboot.service
chroot "$M" test -e /etc/systemd/system/local-fs.target.wants/macboot-firstboot.service
mkdir -p "$M/etc/systemd/system/getty@tty1.service.d" "$M/usr/share/doc/macboot"
cat > "$M/etc/systemd/system/getty@tty1.service.d/autologin.conf" <<'GT'
[Unit]
Wants=data.mount
After=data.mount macboot-firstboot.service

[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin macboot --noclear %I $TERM
GT
cp "$HERE/README.md" "$M/usr/share/doc/macboot/README.md"
mkdir -p "$M/opt/reims"; cp -a "$REIMS/qemu" "$M/opt/reims/qemu-tree"
# reims-ctl looks for <data>/qemu/current/bin/qemu-system-x86_64
mkdir -p "$M/opt/reims/qemu"; ln -sfn ../qemu-tree "$M/opt/reims/qemu/current"
strip --strip-unneeded "$M/opt/reims/qemu-tree/bin/qemu-system-x86_64" 2>/dev/null || true
install -m 0755 "$REIMS/bin/reims-ctl" "$M/usr/local/bin/reims-ctl"
[ -x "$REIMS/bin/reims-util" ] && install -m 0755 "$REIMS/bin/reims-util" "$M/usr/local/bin/reims-util" || echo "NOTE: no reims-util in $REIMS/bin: the image cannot create the VM at first run until it is added"

# Fail loudly if the QEMU or reims-ctl binaries need a shared library the image lacks.
missing=$(chroot "$M" /bin/sh -c 'ldd /opt/reims/qemu-tree/bin/qemu-system-x86_64 /usr/local/bin/reims-ctl 2>&1 | grep "not found"' || true)
[ -z "$missing" ] || { echo "MISSING SHARED LIBRARIES:"; echo "$missing"; exit 1; }

# ---- state directories on MACDATA, created now so the macboot user (uid 1000) can use /data at once
mkdir -p "$WORK/data" && mount "$L_DATA" "$WORK/data"
mkdir -p "$WORK/data/reims/data" "$WORK/data/reims/config" "$WORK/data/reims/cache"
chown -R 1000:1000 "$WORK/data/reims"
umount "$WORK/data"

# ---- kernel command line, GRUB (standalone EFI binary built here, config written by hand)
mkdir -p "$M/boot/grub"
cat > "$M/boot/grub/grub.cfg" <<'GRUB'
set timeout=1
set default=0
menuentry "MacBoot" {
    search --no-floppy --label rootfs --set=root
    linux /boot/vmlinuz root=LABEL=rootfs ro console=tty0 quiet loglevel=3 mitigations=off transparent_hugepage=madvise
    initrd /boot/initrd.img
}
menuentry "MacBoot (rescue shell on tty1)" {
    search --no-floppy --label rootfs --set=root
    linux /boot/vmlinuz root=LABEL=rootfs ro console=tty0 console=ttyS0,115200 systemd.unit=rescue.target
    initrd /boot/initrd.img
}
GRUB
mkdir -p "$WORK/esp/EFI/BOOT"
cat > "$WORK/early.cfg" <<'EARLY'
search --no-floppy --label rootfs --set=root
configfile ($root)/boot/grub/grub.cfg
EARLY
grub-mkimage -O x86_64-efi -o "$WORK/esp/EFI/BOOT/BOOTX64.EFI" -p /boot/grub -c "$WORK/early.cfg" \
    part_gpt fat ext2 normal linux search search_label configfile echo all_video gfxterm
mcopy -s -i "$L_ESP" "$WORK/esp/EFI" ::

# ---- shrink
chroot "$M" /bin/sh -c 'apt-get clean; rm -rf /var/lib/apt/lists/* /usr/share/man /usr/share/info /usr/share/locale/* /var/cache/debconf/*-old; find /usr/share/doc -name changelog\* -delete 2>/dev/null; true'
mkdir -p "$M/usr/share/doc/macboot"; cp "$HERE/README.md" "$M/usr/share/doc/macboot/README.md"
rm -f "$M/usr/sbin/policy-rc.d"
sync
echo "built $OUT"
