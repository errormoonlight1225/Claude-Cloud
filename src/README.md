# nxlaunchd / nxlaunchctl

A small, launchd-compatible service supervisor, written from scratch for this
project. It is the init/service-management layer of the rootless environment —
not a jailbreak or a code loader. It runs on a host that already permits
`fork`/`exec`: a jailbroken device's rootless prefix (`/var/jb`), or any Unix
for testing.

## What it does

`nxlaunchd` reads ordinary launchd property lists and supervises the jobs:

- `Label` (required), `Program` / `ProgramArguments`
- `RunAtLoad`
- `KeepAlive` — either `<true/>` or a dict with `SuccessfulExit` / `Crashed`
- `EnvironmentVariables`, `WorkingDirectory`, `RootDirectory`
- `StandardOutPath` / `StandardErrorPath` / `StandardInPath`
- `UserName` / `GroupName` (best effort; needs privilege)
- `ThrottleInterval` (default 10 s), `StartInterval`, `Disabled`

It throttles restarts, backs off after fast crashes, gives up after a run of
them, reaps children, and persists `enable`/`disable` overrides.

`nxlaunchctl` is the client. It speaks to the daemon over an `AF_UNIX` socket:

```
nxlaunchctl load|bootstrap   <plist|dir>...
nxlaunchctl unload|bootout   <plist|label>...
nxlaunchctl start|stop       <label>...
nxlaunchctl kickstart [-k]   <label>...
nxlaunchctl list             [filter]
nxlaunchctl print            <label>
nxlaunchctl enable|disable   <label>...
```

## Build

```sh
make -C src ios        # iOS arm64, signed with ldid if present
make -C src host       # build for the current macOS, for local testing
```

`PREFIX` (default `/var/jb`) is baked into the socket and state paths:

- control socket: `$PREFIX/var/run/nxlaunchd.sock`
- enable/disable overrides: `$PREFIX/var/db/nxlaunchd.overrides.plist`
- boot scan directory: `$PREFIX/Library/LaunchDaemons`

Override any of these at run time with `LAUNCHD_SOCKET`, `LAUNCHD_OVERRIDES`,
and `--daemons-dir`.

## Try it (jailbroken device, e.g. iPhone with a rootless bootstrap)

1. Build both with `make -C src ios` (macOS with Xcode; signed with ldid if it
   is installed).
2. Copy both binaries into the rootless prefix and make them executable:
   ```sh
   install -m755 nxlaunchd  /var/jb/usr/libexec/nxlaunchd
   install -m755 nxlaunchctl /var/jb/usr/bin/nxlaunchctl
   ```
3. Start the daemon (from a terminal app, or later from the real launchd):
   ```sh
   /var/jb/usr/libexec/nxlaunchd &
   ```
4. Load the example job and watch it:
   ```sh
   nxlaunchctl load /var/jb/path/to/examples/com.example.hello.plist
   nxlaunchctl list
   tail -f /var/jb/var/log/hello.log
   nxlaunchctl print com.example.hello
   nxlaunchctl stop com.example.hello     # KeepAlive brings it back
   nxlaunchctl unload com.example.hello    # gone for good
   ```

The example runs `bash`; point `ProgramArguments` at whatever you have.

## Status

This is milestone 2 (launchd/launchctl) of the project. It does not yet
implement the Mach-service / XPC check-in path — that is tracked separately,
because on a stock sandbox it depends on the runtime, which is out of scope for
this layer. On a jailbroken host the fork/exec supervision above is the real
thing.
