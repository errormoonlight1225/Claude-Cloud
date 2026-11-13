# Rootless ROM for Nyxian

A Nyxian ROM with a standard rootless (`/var/jb`) userspace. Work in progress:
see [docs/ANALYSIS.md](docs/ANALYSIS.md) for what Nyxian provides and what this
ROM has to implement itself.

| Milestone | State |
|---|---|
| 0. Build pipeline: template ROM built and signed by CI | done |
| 1. `/var/jb` bootstrap laid down on flash, dpkg layout | built, needs device test |
| 2. launchd / launchctl (`src/`) | built, needs device test |
| 2b. Mach-service / XPC check-in | not started |
| 3. sudo/su, tweak injection, safe mode | not started |
| 4. SpringBoard, uicache, Sileo | not started |

Milestone 1 ships a skeleton rootless bootstrap (dpkg/apt config for
`iphoneos-arm64` plus the directory layout) that the ROM's installer
(`rom-overlay/installer`) extracts into the data partition on flash. Whether a
guest process actually resolves `/var/jb` into that data partition is the open
question that needs a device to confirm.

To ship a real rootless userland (apt, dpkg, bash, …) instead of the skeleton,
point `STRAP_TAR` at a Procursus rootless bootstrap archive when building; its
contents become `/var/jb` and the skeleton only fills what it does not provide,
so the strap's own dpkg database is kept:

    STRAP_TAR=~/bootstrap.tar.zst scripts/build.sh
    # STRAP_STRIP=N if the strap is not already rooted at /var/jb

Supported strap formats: `.tar`, `.tar.gz`, `.tar.xz`, `.tar.zst`, `.tar.bz2`,
`.tar.lzma`.

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
