#!/usr/bin/env bash
# iPhone 恢复辅助脚本（依赖 libimobiledevice / idevicerestore，在你自己的电脑上运行）
# 用法:
#   ./ios_restore.sh info                 查看设备真实信息
#   ./ios_restore.sh backup [目录]        备份设备
#   ./ios_restore.sh restore <固件.ipsw>  恢复到指定固件（会清除数据）
set -euo pipefail

need() { command -v "$1" >/dev/null || { echo "缺少 $1，请先安装 libimobiledevice / idevicerestore"; exit 1; }; }

cmd="${1:-info}"
case "$cmd" in
info)
  need ideviceinfo
  ideviceinfo | grep -E '^(ProductType|ProductVersion|BuildVersion|DeviceName|UniqueChipID|CPUArchitecture):' || {
    echo "读不到设备：请解锁手机、点“信任”，或进入恢复/DFU 模式"; exit 1; }
  echo "提示: iPhone6(iPhone7,2) 官方最高 iOS 12.5.x，iOS 13 不受支持"
  ;;
backup)
  need idevicebackup2
  dir="${2:-./backup}"; mkdir -p "$dir"
  idevicebackup2 backup "$dir"
  echo "备份完成: $dir"
  ;;
restore)
  need idevicerestore
  ipsw="${2:?请提供 .ipsw 固件路径（iPhone7,2 / iPhone 6 的 12.5.x）}"
  [ -f "$ipsw" ] || { echo "找不到文件: $ipsw"; exit 1; }
  echo "即将清除设备所有数据并恢复。请确认已备份。输入 yes 继续:"
  read -r ans; [ "$ans" = yes ] || exit 1
  idevicerestore -e "$ipsw"   # -e = 擦除恢复
  ;;
*) echo "未知命令: $cmd"; exit 1 ;;
esac
