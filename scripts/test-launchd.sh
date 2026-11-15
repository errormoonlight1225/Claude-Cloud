#!/usr/bin/env bash
# Runs nxlaunchd and nxlaunchctl for real (macOS only): builds them for the
# host with a prefix that is too long for a socket address, as an app container
# path is, then loads jobs, checks they run and restart, stops them, and shuts
# the daemon down.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
t=$(mktemp -d)
daemon=
cleanup() { [ -z "$daemon" ] || kill "$daemon" 2>/dev/null || true; rm -rf "$t"; }
trap cleanup EXIT

prefix=$t/$(printf 'c%.0s' $(seq 1 100))/jb
mkdir -p "$prefix/Library/LaunchDaemons" "$prefix/var/log"
make -C "$root/src" host PREFIX="$prefix" BUILD="$t/build" >/dev/null
ctl=$t/build/host-nxlaunchctl

job() {   # job LABEL KEEPALIVE COMMAND
  cat > "$prefix/Library/LaunchDaemons/$1.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>Label</key><string>$1</string>
  <key>ProgramArguments</key><array><string>/bin/sh</string><string>-c</string><string>$3</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><$2/>
  <key>ThrottleInterval</key><integer>1</integer>
  <key>EnvironmentVariables</key><dict><key>NX_TEST</key><string>from-plist</string></dict>
  <key>StandardOutPath</key><string>$prefix/var/log/$1.out</string>
</dict></plist>
PLIST
}
job test.once false 'echo $NX_TEST'
job test.keep true "echo run >> $prefix/var/log/keep.count; sleep 1"

"$t/build/host-nxlaunchd" 2> "$t/daemon.log" &
daemon=$!
wait_for() {   # wait_for SECONDS COMMAND...
  local n=$(( $1 * 10 )); shift
  while [ "$n" -gt 0 ]; do "$@" 2>/dev/null && return 0; sleep 0.1; n=$((n - 1)); done
  echo "timed out waiting for: $*" >&2
  for f in "$t/daemon.log" "$prefix"/var/log/*; do echo "--- $f" >&2; cat "$f" >&2; done
  return 1
}
wait_for 10 test -S "$prefix/var/run/nxlaunchd.sock"

# both jobs were loaded from the daemons directory and started
"$ctl" list > "$t/list"
grep -q test.once "$t/list" && grep -q test.keep "$t/list" || { cat "$t/list"; exit 1; }
wait_for 10 grep -qx from-plist "$prefix/var/log/test.once.out"

# KeepAlive: the job is started again after it exits
wait_for 20 sh -c "[ \"\$(wc -l < '$prefix/var/log/keep.count')\" -ge 2 ]"

# stop and unload: it stays down
"$ctl" unload test.keep
sleep 1
before=$(wc -l < "$prefix/var/log/keep.count")
sleep 4
[ "$(wc -l < "$prefix/var/log/keep.count")" -eq "$before" ] || { echo "job restarted after unload" >&2; exit 1; }
"$ctl" list | grep -q test.keep && { echo "job still listed after unload" >&2; exit 1; }

# load by path again, and print
"$ctl" load "$prefix/Library/LaunchDaemons/test.keep.plist"
"$ctl" print test.keep | grep -q test.keep
"$ctl" stop test.keep || true

# an unknown command or label fails
if "$ctl" print no.such.job >/dev/null 2>&1; then echo "print of an unknown job succeeded" >&2; exit 1; fi

kill -TERM "$daemon"
wait "$daemon" || true
daemon=
[ ! -e "$prefix/var/run/nxlaunchd.sock" ] || { echo "socket left behind" >&2; exit 1; }
echo "ok: nxlaunchd ran jobs under a $(printf %s "$prefix" | wc -c | tr -d ' ')-byte prefix"
