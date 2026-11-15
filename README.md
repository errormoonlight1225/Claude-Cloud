# Rootless ROM for Nyxian

A Nyxian ROM with a standard rootless (`/var/jb`) userspace. Work in progress:
see [docs/ANALYSIS.md](docs/ANALYSIS.md) for what Nyxian provides and what this
ROM has to implement itself.

| Milestone | State |
|---|---|
| 0. Build pipeline: template ROM built and signed by CI | done |
| 1. `/var/jb` bootstrap laid down on flash, dpkg layout | built, needs device test |
| 1b. `/var/jb` path layer for every guest process (`src/rtpatch`) | built, host-tested, needs device test |
| 1c. Library paths and signing: at packing time, and after every dpkg run (`src/fixup`) | built, host-tested, needs device test |
| 2. launchd / launchctl (`src/`) | built, run for real on macOS in CI, needs device test |
| 2a. Boot wiring: the ROM starts launchd with its entitlements; first-boot `nxfixup` | built, needs device test |
| 2b. Mach-service / XPC check-in | not started |
| 3. sudo/su, tweak injection, safe mode | not started |
| 4. SpringBoard, uicache, Sileo | not started |

Milestone 1 ships a skeleton rootless bootstrap (dpkg/apt config for
`iphoneos-arm64` plus the directory layout) that the ROM's installer
(`rom-overlay/installer`) extracts into the data partition on flash.

A Nyxian guest runs on the real filesystem, so `/var/jb` does not exist for it
by itself. Milestone 1b is the path layer that makes every program use the
`/var/jb` inside the app: `rtpatch` (`src/rtpatch/nxjbpath.c`) is loaded by
every guest process at startup and rewrites any path at or below `/var/jb` to
`<container>/Documents/rootfs/var/jb` in the file functions Nyxian lets a ROM
replace (open, stat, rename, symlink, opendir, posix_spawn, exec, ...). The
ROM's kernel installs it on every boot (`rom-overlay/kernel/shimcache.m`).
`make -C src/rtpatch test` runs its test on any OS.

- Library paths never pass through those functions (the dynamic loader opens
  files itself), so binaries that link `/var/jb/usr/lib/...` are rewritten
  instead: `scripts/relocate-macho.py` turns those load commands and rpaths
  into `@loader_path/...` when the bootstrap is packed, and the rewritten files
  are signed again with `ldid` if it is installed. Neither
  `dlopen("/var/jb/...")` nor `#!/var/jb/...` lines are handled.
- Packages installed later: dpkg runs `/var/jb/usr/libexec/nxfixup`
  (`src/fixup`) after every transaction (`post-invoke` in `dpkg.cfg.d`). It
  does the same rewrite on the device and has Nyxian sign each new or changed
  Mach-O with your certificate; Nyxian itself only signs a program when it is
  started, not the libraries it links. It keeps a list of what it has done, so
  a run only touches what changed. Run `nxfixup --all` after the signing
  certificate was renewed. A package's own install script still runs before
  this, so one that starts a just-unpacked program with new libraries can fail
  on the first install.
- Not verified without a device: that the slots are reachable from `rtpatch`
  on your Nyxian version, and that libc-internal opens (`fopen`) go through
  them. To check on the device, run any program with `NXJB_DEBUG=1` in its
  environment: it prints where `/var/jb` maps to and how many slots it took
  (about 39; 0 means the slots are not reachable).
- If guests stop starting after flashing, add the boot argument `nxjb_off`
  (Nyxian > Settings > General > Boot Arguments): the ROM then boots without
  the path layer and without `nxlaunchd`.

To ship a real rootless userland (apt, dpkg, bash, …) instead of the skeleton,
point `STRAP_TAR` at a Procursus rootless bootstrap archive when building; its
contents become `/var/jb` and the skeleton only fills what it does not provide,
so the strap's own dpkg database is kept:

    STRAP_TAR=~/bootstrap.tar.zst scripts/build.sh
    # STRAP_STRIP=N if the strap is not already rooted at /var/jb

Supported strap formats: `.tar`, `.tar.gz`, `.tar.xz`, `.tar.zst`, `.tar.bz2`,
`.tar.lzma`.

### What happens at boot

1. The ROM's kernel installs the path layer and registers `nxlaunchd` (in the
   slot, `Application/libexec/nxlaunchd`) as a Nyxian launch service
   (`rom-overlay/kernel/shimcache.m`). Its entitlements come from the manifest
   (`scripts/set-manifest.py`): root, and the right to start and sign programs,
   which Nyxian passes on to everything it starts.
2. `nxlaunchd` loads `/var/jb/Library/LaunchDaemons`.
3. The first job there, `rootless.nxfixup`, relocates and signs every Mach-O in
   `/var/jb` that is new or changed. On the first boot after flashing that is
   the whole bootstrap; its log is `/var/jb/var/log/nxfixup.log`.

Not verified without a device: that Nyxian starts a service whose entry is
written at boot rather than mounted, that a slot program built as a dylib with
`main` starts the way the template's Hello app does, that `fork`/`exec` in
`nxlaunchd` behaves under Nyxian's emulation of them, and that a socket can be
bound inside the container. `scripts/test-launchd.sh` covers the daemon itself
(jobs, restart, unload, a prefix too long for a socket address) on macOS.

## Licence: personal use only

The ROM's `main` is Nyxian's kernel surface, compiled from
[emexlab/nyxian](https://github.com/emexlab/nyxian), which is under EPSL 1.1.
Building and flashing it yourself is allowed; giving `rom.zip` to anyone else
needs written permission from emexLabs. Keep this repository **private**, so
that the build artifacts stay with you. Nyxian's source is fetched at build
time and is not part of this repository.

## Build

Settings are in `rom.conf` (identifier, version, security version, the Nyxian
commit the kernel is built from).

On GitHub: every push builds `rom.zip` on a macOS runner (Actions > Build ROM >
artifact `rom`). Set these once under Settings > Secrets and variables > Actions:

- variable `ROM_IDENTIFIER` (optional): overrides the `NXRomIdentifier` in `rom.conf`
- secret `ROM_SIGNING_KEY`: the contents of your private key (`rom.key.pem`)

Without the secret the ROM is signed with a throwaway key: it proves the build
works, but Nyxian will not boot it.

Locally (macOS with Xcode): `ROM_SIGNING_KEY=~/.config/nyxian/romkey/rom.key.pem scripts/build.sh`

## Signing key and install tickets

`RomGen.py` is in the Nyxian checkout (`.build/nyxian/RomGen.py` after a build);
it needs Python 3 and `openssl`, on any OS.

1. `python3 RomGen.py genkey --name rom` creates
   `~/.config/nyxian/romkey/rom.key.pem` (private, never share it) and `rom.pub.pem`.
2. On developer.emexlabs.org, register `rom.pub.pem` together with your
   `NXRomIdentifier`. The portal shows a code; prove the key is yours with
   `python3 RomGen.py prove --key rom.key.pem 'CODE'`.
3. Once the key is in the TrustStore, check a build with
   `python3 RomGen.py verify rom.zip --truststore online`.
4. For every release, `python3 RomGen.py digest rom.zip` prints its digest (CI
   prints it at the end of the build log too). Sign that digest on your key's
   page of the portal ("Signed releases"). Devices then get an install ticket
   for it when they flash, which needs an internet connection.

### Without a registered key

Nyxian reads `NXBootPolicy.plist` from its own app bundle; NyxLoader writes it
when it installs Nyxian, from NyxLoader's settings. With `NXTrustStoreValidation`
off, ROMs flash that no TrustStore key signed; with `NXTSSValidation` off, they
flash and boot without an install ticket. If your Nyxian was installed that way,
steps 2 to 4 are not needed. Still keep one key of your own in `ROM_SIGNING_KEY`
rather than the throwaway one, so every build is signed by the same key.
Changing the policy means installing Nyxian again with NyxLoader (over the
existing install, not after deleting it).

## Releases and recovery

- Raise `ROM_SECURITY_VERSION` in `rom.conf` for every build you flash. Nyxian
  never goes back to a lower one.
- Update Nyxian by installing over it. Deleting the app deletes the ROM and
  its data.
- If the ROM does not boot, hold Volume Down while Nyxian starts to enter
  recovery. Do not use "Wipe ROM Data" unless you want to lose everything
  installed in the ROM.
