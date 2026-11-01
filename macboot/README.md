# MacBoot

一个极简的 Linux 宿主系统：开机后直接全屏进入 macOS（QEMU/KVM + OpenCore）。
目标是在**没有 macOS 原生核显驱动**的机器（如 Intel Arc / Xe / 12 代以后的核显）上也能装、能用 macOS，
同时让宿主本身的内存开销尽量小。

> **状态：未在真机上验证。** Buildroot 配置符号已用 Buildroot 2025.02.7 校验；启动脚本做过语法检查；
> 没有在带 KVM 的硬件上实际启动过 macOS。第一次使用请预期需要调试。

## 它能做到什么，做不到什么

| 目标 | 现状 |
|---|---|
| 不被支持的核显也能安装并进入 macOS | 可以。宿主用 Linux 的 i915/xe 驱动点亮显示，macOS 看到的是 QEMU 虚拟显卡 |
| GPU 硬件加速（Metal） | **没有。** Apple 没有为这些核显写驱动，虚拟显卡也没有 macOS 驱动。界面能用但偏卡，视频、动画、部分 App 吃 CPU，少数 App 无法运行 |
| 功能与普通黑苹果一致 | 大部分一致（网络、键鼠、磁盘）。**不一致的：** GPU 加速、核显直通、硬件解码、睡眠/唤醒、蓝牙/Wi-Fi/声卡等需要 USB 直通或额外配置 |
| 启动 macOS 后占用 < 512MB / 256MB | 只指**宿主开销**（Linux 内核 + QEMU 进程 + 用户态），目标 200–250MB。macOS 自己的内存（建议 ≥ 8GB）由 `GUEST_RAM` 决定，无法压缩到 256MB |

宿主开销的估算（**未实测**，用 `macboot-mem` 实测）：

| 部分 | 估计 |
|---|---|
| 内核（裁剪后）+ slab | ~40 MB |
| QEMU 进程（不含来宾内存） | ~80–100 MB |
| SDL2 + Mesa（KMS/DRM 显示） | ~30–50 MB |
| BusyBox + tmpfs | ~10 MB |

## 构建

需要一台 Linux 构建机（约 30GB 空间，首次构建 1 小时以上）。

```bash
wget https://buildroot.org/downloads/buildroot-2025.02.7.tar.xz && tar xf buildroot-2025.02.7.tar.xz
make BUILDROOT=$PWD/buildroot-2025.02.7 -C macboot
# 产物: macboot/output/images/macboot.img
```

然后准备数据分区（下载 OpenCore、OVMF 和 macOS 恢复镜像）：

```bash
sudo macboot/scripts/prepare-data.sh macboot/output/images/macboot.img 160 sonoma
```

把 `macboot.img` 写入目标机器的 SSD/U 盘，BIOS 里开启 VT-x、从 UEFI 启动。首次启动会进入 macOS 安装器，
装完后进入 tty2（Alt+F2）执行 `rm /data/BaseSystem.img` 并重启。

## 配置

`/data/macboot.conf` 覆盖 `etc/macboot.conf` 里的默认值：内存、vCPU 数、是否使用大页、磁盘大小、CPU 型号、额外 QEMU 参数。

## 调试

- tty2（Alt+F2）是救援 shell；GRUB 里选 "debug shell" 可跳过自动启动。
- `macboot-mem`：显示宿主开销与来宾内存的分离统计。
- `/dev/kvm` 不存在 → 固件里开 VT-x。
- macOS 卡在苹果标志 → 先试 `CPU_MODEL=Cascadelake-Server`/`Skylake-Client`，并确认 `ignore_msrs=1`。

## 版权与合规

macOS 的许可协议只允许在 Apple 硬件上运行。本项目仅供研究和个人学习，不含任何 Apple 文件，
安装镜像由 `prepare-data.sh` 在你自己的机器上从 Apple 服务器下载。OpenCore 的 SMBIOS 是公开样例，
需要 iMessage/iCloud 请自行生成独立序列号。
