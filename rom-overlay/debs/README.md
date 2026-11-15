Any `.deb` placed in this directory is packed into the ROM and installed by
dpkg on the first boot after flashing, after the ones listed in `rom.conf`
(`FIRSTBOOT_DEBS`). Use it for a package that is not in a repository the build
can download from. Packages must be rootless (`iphoneos-arm64`, files under
`/var/jb`).
