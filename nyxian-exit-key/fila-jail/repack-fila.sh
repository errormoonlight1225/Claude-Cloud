#!/bin/bash
# 下载官方 Fila roothide 包，去掉 filad / LaunchDaemon（Switzach 没有真 launchd），
# 让 Fila 退回进程内后端。输出: $2（默认 ../build/Fila_switzach.deb）
set -euo pipefail
VER="${1:-0.8.4}"
OUT="${2:-../build/Fila_switzach.deb}"
work=$(mktemp -d)
curl -fsSL -o "$work/orig.deb" \
  "https://github.com/owngoal-dev/Fila/releases/download/v$VER/wiki.qaq.fila_${VER}_iphoneos-arm64e.deb"
dpkg-deb -R "$work/orig.deb" "$work/r"
r="$work/r"
rm -f "$r/usr/libexec/filad" "$r/Library/LaunchDaemons/wiki.qaq.filad.plist"
rmdir "$r/Library/LaunchDaemons" "$r/Library" 2>/dev/null || true
# postinst: 保留建目录部分，去掉 launchctl 部分
awk '/^# The daemon id is named once/{exit} {print}' "$r/DEBIAN/postinst" > "$work/postinst"
printf '# Switzach: no filad; Fila uses its in-process backend.\nexit 0\n' >> "$work/postinst"
mv "$work/postinst" "$r/DEBIAN/postinst"
printf '#!/bin/sh\nexit 0\n' > "$r/DEBIAN/prerm"
printf '#!/bin/sh\nexit 0\n' > "$r/DEBIAN/postrm"
chmod 755 "$r/DEBIAN/postinst" "$r/DEBIAN/prerm" "$r/DEBIAN/postrm"
sh -n "$r/DEBIAN/postinst"
sed -i.bak -e "s/^Version: .*/Version: ${VER}+switzach/" \
  -e 's/^Depends: .*/Depends: firmware (>= 15.0), uikittools/' \
  -e '/^Installed-Size/d' "$r/DEBIAN/control"
rm -f "$r/DEBIAN/control.bak"
dpkg-deb -Zgzip --root-owner-group -b "$r" "$OUT" >/dev/null
dpkg-deb -f "$OUT" Package Version Depends
dpkg-deb -c "$OUT" | grep -v 'Fila.app/.' 
rm -rf "$work"
