#!/bin/bash
# Tests for nbme-fix.sh.
#
# sysctl, sudo and uname are replaced by stubs on a private PATH directory. The fake
# sysctl keeps its "kernel state" in a file, so on/off/status run for real against it
# and the tests assert on the resulting state and output, not on the stubs.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/../nbme-fix.sh"
PASS=0
FAIL=0

DEFAULT_STATE="net.inet.tcp.always_keepalive=0
net.inet.tcp.keepcnt=8
net.inet.tcp.keepidle=7200000
net.inet.tcp.keepintvl=75000"
FIX_STATE="net.inet.tcp.always_keepalive=0
net.inet.tcp.keepcnt=2
net.inet.tcp.keepidle=7200000
net.inet.tcp.keepintvl=1000"
# The first release forced keepalive onto every socket; 'on' must undo that too.
OLD_FIX_STATE="net.inet.tcp.always_keepalive=1
net.inet.tcp.keepcnt=3
net.inet.tcp.keepidle=30000
net.inet.tcp.keepintvl=3000"

setup() {
  SANDBOX=$(mktemp -d)
  export FAKE_SYSCTL_STATE="$SANDBOX/state"
  export FAKE_SUDO_LOG="$SANDBOX/sudo.log"
  export FAKE_UNAME="Darwin"
  export FAKE_SUDO_EXIT=0
  export FAKE_LAUNCHCTL_LOG="$SANDBOX/launchctl.log"
  export NBME_FIX_DAEMON_DIR="$SANDBOX/LaunchDaemons"
  mkdir "$NBME_FIX_DAEMON_DIR"
  : > "$FAKE_LAUNCHCTL_LOG"
  : > "$FAKE_SUDO_LOG"
  echo "$DEFAULT_STATE" > "$FAKE_SYSCTL_STATE"
  mkdir "$SANDBOX/bin"
  cat > "$SANDBOX/bin/sysctl" <<'STUB'
#!/bin/bash
mode=$1; shift
if [ "$mode" = "-n" ]; then
  for k in "$@"; do grep "^$k=" "$FAKE_SYSCTL_STATE" | cut -d= -f2; done
elif [ "$mode" = "-w" ]; then
  for kv in "$@"; do
    k=${kv%%=*}; v=${kv#*=}
    old=$(grep "^$k=" "$FAKE_SYSCTL_STATE" | cut -d= -f2)
    grep -v "^$k=" "$FAKE_SYSCTL_STATE" > "$FAKE_SYSCTL_STATE.tmp"
    echo "$k=$v" >> "$FAKE_SYSCTL_STATE.tmp"
    mv "$FAKE_SYSCTL_STATE.tmp" "$FAKE_SYSCTL_STATE"
    echo "$k: $old -> $v"
  done
fi
STUB
  cat > "$SANDBOX/bin/sudo" <<'STUB'
#!/bin/bash
echo "$*" >> "$FAKE_SUDO_LOG"
[ "$FAKE_SUDO_EXIT" = "0" ] || { echo "sudo: a password is required" >&2; exit "$FAKE_SUDO_EXIT"; }
exec "$@"
STUB
  cat > "$SANDBOX/bin/uname" <<'STUB'
#!/bin/bash
echo "$FAKE_UNAME"
STUB
  cat > "$SANDBOX/bin/launchctl" <<'STUB'
#!/bin/bash
echo "$*" >> "$FAKE_LAUNCHCTL_LOG"
STUB
  chmod +x "$SANDBOX/bin/"*
}

teardown() { rm -rf "$SANDBOX"; }

run() { # run the script with stubs first on PATH; captures OUT and RC
  OUT=$(PATH="$SANDBOX/bin:$PATH" /bin/bash "$SCRIPT" "$@" 2>&1)
  RC=$?
}

state() { sort "$FAKE_SYSCTL_STATE"; }

ok() { PASS=$((PASS + 1)); echo "  ok   - $1"; }
not_ok() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; shift; printf '         %s\n' "$@"; }

check() { # check "name" condition-command...
  local name=$1; shift
  if "$@"; then ok "$name"; else not_ok "$name" "rc=$RC" "output: $OUT"; fi
}

contains() { case "$OUT" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
lacks() { ! contains "$1"; }

# ---------------------------------------------------------------- status
setup
run status
check "status reports OFF when the kernel has macOS defaults" contains "OFF"
teardown

setup
echo "$FIX_STATE" > "$FAKE_SYSCTL_STATE"
run status
check "status reports ACTIVE when all four fix values are set" contains "ACTIVE"
teardown

setup
echo "$OLD_FIX_STATE" > "$FAKE_SYSCTL_STATE"
run status
check "status reports PARTIAL when the first-release settings are active" contains "PARTIAL"
teardown

# -------------------------------------------------------------------- on
setup
run on
check "on sets exactly the four tested fix values" [ "$(state)" = "$FIX_STATE" ]
check "on exits 0 when it succeeds" [ "$RC" -eq 0 ]
check "on changes the settings through sudo" grep -q "sysctl -w" "$FAKE_SUDO_LOG"
teardown

setup
echo "$OLD_FIX_STATE" > "$FAKE_SYSCTL_STATE"
run on
check "on replaces the first-release settings with the current fix" [ "$(state)" = "$FIX_STATE" ]
teardown

setup
FAKE_SUDO_EXIT=1
run on
check "on exits non-zero when sudo is refused" [ "$RC" -ne 0 ]
check "on leaves the settings untouched when sudo is refused" [ "$(state)" = "$DEFAULT_STATE" ]
check "on says the fix was not applied when sudo is refused" contains "not applied"
teardown

# ------------------------------------------------------------------- off
setup
echo "$FIX_STATE" > "$FAKE_SYSCTL_STATE"
run off
check "off restores exactly the macOS defaults" [ "$(state)" = "$DEFAULT_STATE" ]
check "off changes the settings through sudo" grep -q "sysctl -w" "$FAKE_SUDO_LOG"
teardown

# --------------------------------------------------------- install/uninstall
PLIST_NAME="com.nbme-keepalive-fix.plist"

setup
run install
PLIST="$NBME_FIX_DAEMON_DIR/$PLIST_NAME"
check "install exits 0" [ "$RC" -eq 0 ]
check "install applies the fix immediately" [ "$(state)" = "$FIX_STATE" ]
check "install writes a boot job into the LaunchDaemons dir" [ -f "$PLIST" ]
check "the boot job is a valid property list" plutil -lint -s "$PLIST"
check "the boot job runs at load" grep -q "RunAtLoad" "$PLIST"
check "the boot job sets keepintvl to the fix value" grep -q "net.inet.tcp.keepintvl=1000" "$PLIST"
check "the boot job sets keepcnt to the fix value" grep -q "net.inet.tcp.keepcnt=2" "$PLIST"
check "the boot job resets always_keepalive to default" grep -q "net.inet.tcp.always_keepalive=0" "$PLIST"
check "install loads the boot job with launchctl bootstrap" grep -q "bootstrap system $PLIST" "$FAKE_LAUNCHCTL_LOG"
check "install writes the boot job through sudo" grep -q "$PLIST_NAME" "$FAKE_SUDO_LOG"
run status
check "status reports the boot job as installed" lacks "not installed"
check "status names the boot job file" contains "$PLIST_NAME"
teardown

setup
run install
run install
check "install twice still exits 0" [ "$RC" -eq 0 ]
check "install twice unloads the old job before loading again" grep -q "bootout system/com.nbme-keepalive-fix" "$FAKE_LAUNCHCTL_LOG"
teardown

setup
FAKE_SUDO_EXIT=1
run install
check "install exits non-zero when sudo is refused" [ "$RC" -ne 0 ]
check "install leaves the settings untouched when sudo is refused" [ "$(state)" = "$DEFAULT_STATE" ]
check "install writes no boot job when sudo is refused" [ ! -f "$NBME_FIX_DAEMON_DIR/$PLIST_NAME" ]
teardown

setup
run install
run uninstall
check "uninstall exits 0" [ "$RC" -eq 0 ]
check "uninstall removes the boot job file" [ ! -f "$NBME_FIX_DAEMON_DIR/$PLIST_NAME" ]
check "uninstall unloads the boot job with launchctl bootout" grep -q "bootout system/com.nbme-keepalive-fix" "$FAKE_LAUNCHCTL_LOG"
check "uninstall restores the macOS defaults" [ "$(state)" = "$DEFAULT_STATE" ]
run status
check "status reports the boot job as not installed after uninstall" contains "not installed"
teardown

setup
run uninstall
check "uninstall with nothing installed still exits 0" [ "$RC" -eq 0 ]
check "uninstall with nothing installed still restores defaults" [ "$(state)" = "$DEFAULT_STATE" ]
teardown

setup
run install
run off
check "off while the boot job is installed warns that it comes back at boot" contains "uninstall"
teardown

# ------------------------------------------------------------ usage/guards
setup
run frobnicate
check "an unknown subcommand exits non-zero" [ "$RC" -ne 0 ]
check "an unknown subcommand prints usage" contains "Usage:"
teardown

setup
run
check "no subcommand exits non-zero" [ "$RC" -ne 0 ]
check "no subcommand prints usage" contains "Usage:"
teardown

setup
FAKE_UNAME="Linux"
run on
check "refuses to run on a non-macOS system" [ "$RC" -ne 0 ]
check "does not touch settings on a non-macOS system" [ "$(state)" = "$DEFAULT_STATE" ]
check "explains that it is macOS-only" contains "macOS"
teardown

# ------------------------------------------------------- test (live probe)
# Needs the network: two anonymous HEAD requests to the exam host. A 3-second idle is
# far too short for the server to drop the connection, so the probe must report that
# the connection survived (inconclusive, exit 2) rather than pass or fail.
if nc -z -G 5 www.starttest.com 443 >/dev/null 2>&1; then
  setup
  run test 3
  check "test with a short idle reports the connection survived (exit 2)" [ "$RC" -eq 2 ]
  check "test with a short idle says the result is inconclusive" contains "INCONCLUSIVE"
  teardown
else
  echo "  skip - live probe tests (www.starttest.com:443 unreachable)"
fi

setup
run test abc
check "test rejects a non-numeric idle time" [ "$RC" -ne 0 ]
check "test with a non-numeric idle time prints usage" contains "Usage:"
teardown

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
