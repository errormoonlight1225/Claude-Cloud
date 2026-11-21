# Rootless ROM for Nyxian

A Nyxian ROM with a standard rootless (`/var/jb`) userspace. Work in progress:
see [docs/ANALYSIS.md](docs/ANALYSIS.md) for what Nyxian provides and what this
ROM has to implement itself.

| Milestone | State |
|---|---|
| 0. Build pipeline: template ROM built and signed by CI | done |
| 1. `/var/jb`: the Procursus bootstrap, laid down on flash | built, needs device test |
| 1b. `/var/jb` path layer for every guest process (`src/rtpatch`) | built, host-tested, needs device test |
| 1c. Library paths and signing: at packing time, and after every dpkg run (`src/fixup`) | built, host-tested, needs device test |
| 2. launchd / launchctl (`src/`) | built, run for real on macOS in CI, needs device test |
| 2a. Boot wiring: the ROM starts launchd with its entitlements; first-boot `nxfixup` | built, needs device test |
| 2b. Mach-service / XPC check-in | not started |
| 3. sudo/su, tweak injection, safe mode | set-user-ID bit honoured (built, needs device test); the rest not started |
| 4. Package managers: apps in `/var/jb/Applications` on the home screen, Sileo and Zebra shipped | built, needs device test |
| 4b. SpringBoard replacement, respring | not started |

Milestone 1: `/var/jb` is the Procursus rootless bootstrap (apt, dpkg, bash,
zsh, coreutils and so on; 67 packages). The build downloads it from
apt.procurs.us, checks it against the hash in `rom.conf`, and packs it into the
ROM; the ROM's installer (`rom-overlay/installer`) extracts it into the data
partition on flash, the first time only. On top of it the build adds this
project's own files (`rom-overlay/bootstrap`, `nxlaunchctl`, `nxfixup`), makes
`launchctl` mean `nxlaunchctl` (Procursus' own is kept as `launchctl.procursus`
through a dpkg diversion), and turns off the two daemons in the bootstrap that
need Apple's launchd.

    STRAP_TAR=~/bootstrap.tar.zst scripts/build.sh   # a bootstrap of your own
    STRAP_URL= scripts/build.sh                      # an empty /var/jb instead

Supported formats: `.tar`, `.tar.gz`, `.tar.xz`, `.tar.zst`, `.tar.bz2`,
`.tar.lzma`.

A Nyxian guest runs on the real filesystem, so `/var/jb` does not exist for it
by itself. Milestone 1b is the path layer that makes every program use the
`/var/jb` inside the app: `rtpatch` (`src/rtpatch/nxjbpath.c`) is loaded by
every guest process at startup and rewrites any path at or below `/var/jb` to
`<container>/Documents/rootfs/var/jb` in the file functions Nyxian lets a ROM
replace (open, stat, rename, symlink, opendir, posix_spawn, exec, ...). The
ROM's kernel installs it on every boot (`rom-overlay/kernel/shimcache.m`).
`make -C src/rtpatch test` runs its test on any OS.

- Scripts are started here too: a file that begins with `#!` is run through
  its interpreter by the path layer, as the real kernel would outside Nyxian
  (every dpkg package script starts with `#!/var/jb/bin/sh`).
- Library paths never pass through those functions (the dynamic loader opens
  files itself), so binaries that link `/var/jb/usr/lib/...` are rewritten
  instead: `scripts/relocate-macho.py` turns those load commands and rpaths
  into `@loader_path/...` when the bootstrap is packed, and the rewritten files
  are signed again with `ldid` if it is installed. Symlinks with an absolute
  `/var/jb` target are made relative at the same time. `dlopen("/var/jb/...")`
  is not handled.
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

### Package managers

A package manager is an app that dpkg installs into `/var/jb/Applications`, and
that runs dpkg and apt itself. Three things make that work here:

- The ROM's home screen lists the apps in `/var/jb/Applications` next to the
  ROM's own, and starts them the same way (`scripts/patch-rom.py` adapts the
  template's `NXMainSlot.m`).
- The ROM's kernel (`rom-overlay/kernel/rootless.m`) lets those apps start, stop
  and list processes, and lets what they start do the same. It also honours the
  set-user-ID bit of files in `/var/jb`: such a program may become uid 0, which
  is how Sileo's `giveMeRoot` helper and `sudo` work. That root is Nyxian's
  virtual one and reaches nothing outside the app's container.
- `uicache` and `sbreload`, which package scripts call and which cannot work
  inside Nyxian, are replaced by a tool that succeeds (the originals are kept
  as `*.procursus`, with dpkg diversions).

Sileo 2.5.1 and Zebra 1.1.36 (from Procursus) and Irisin 5.1.8 (OwnGoal
Studio, from its GitHub release, the file `apt.owngoal.dev` indexes) are
downloaded at build time, hash-checked (`FIRSTBOOT_DEBS` in `rom.conf`), and
installed by dpkg on the first boot, so they can be updated and removed like
any package.

Irisin is built differently from the other two, and it cannot install
packages here yet. Its app runs as mobile and hands every install to a root
daemon, `irisind`, over the Mach service `wiki.qaq.irisin.service`; launchd
starts the daemon when that service is looked up. Inside Nyxian three things
are missing for that: `nxlaunchd` does not provide Mach services yet (milestone
2b); Irisin loads its daemon through launchd's own interface rather than
`launchctl`, so its install script only warns; and the daemon admits a client
by what the real kernel reports about it (its path, user and code-signing
entitlements), which inside Nyxian describe Nyxian's process, not Irisin's.
Irisin installs, appears on the home screen and browses repositories; use
Sileo or Zebra to install packages until 2b is done. Any other
package manager that exists as a rootless `.deb` (`iphoneos-arm64`, files under
`/var/jb`) installs the same way: put the file in `rom-overlay/debs`, add its
URL to `FIRSTBOOT_DEBS`, or install it from a running system with `dpkg -i` or
from a repository. Procursus has no Cydia package, and no rootless build of
Cydia is known to this project.

Not verified without a device: that each app works once started. In particular
Sileo's helper checks who started it by path, and the paths it sees inside
Nyxian are the container's; if it refuses, that check is what to look at first.

### What happens at boot

1. The ROM's kernel installs the path layer and registers `nxlaunchd` (in the
   slot, `Application/libexec/nxlaunchd`) as a Nyxian launch service
   (`rom-overlay/kernel/shimcache.m`). Its entitlements come from the manifest
   (`scripts/set-manifest.py`): root, and the right to start and sign programs,
   which Nyxian passes on to everything it starts.
2. `nxlaunchd` loads `/var/jb/Library/LaunchDaemons`.
3. The first job there, `rootless.nxfixup`, relocates and signs every Mach-O in
   `/var/jb` that is new or changed. On the first boot after flashing that is
   the whole bootstrap (about 390 files); its log is
   `/var/jb/var/log/nxfixup.log`.
4. Right after that, `usr/libexec/nxfirstboot`: once, the bootstrap's own
   `prep_bootstrap.sh` (it configures the base packages and deletes itself),
   then `dpkg -i` for every package shipped with the ROM (Sileo and Zebra). A
   package that fails to install is tried again at the next boot.

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

On GitHub: every push that changes more than documentation runs the tests and
builds `rom.zip` on a macOS runner (Actions > Build ROM > artifact `rom`). macOS
minutes count ten times in a private repository; a run that fails within
seconds without any step usually means the month's included minutes are used
up (Settings > Billing and plans). Set these once under Settings > Secrets and variables > Actions:

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
