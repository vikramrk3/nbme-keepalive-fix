#!/bin/bash
# nbme-fix.sh - macOS workaround for NBME / starttest.com exam "crashes" (SE=1002,
# "Navigation was not complete in sufficient time"). See README.md for the why.
#
#   ./nbme-fix.sh on      apply the TCP keepalive settings (asks for your password)
#   ./nbme-fix.sh off     restore the macOS defaults
#   ./nbme-fix.sh status  show current values (no password needed)
#   ./nbme-fix.sh test    ~3 min live check that dead connections now get detected
#
# The settings are system-wide and reset on reboot. Tested with Chrome on macOS only.
set -euo pipefail

KEYS=(net.inet.tcp.always_keepalive net.inet.tcp.keepidle net.inet.tcp.keepintvl net.inet.tcp.keepcnt)
# Only keepintvl and keepcnt change. Chrome enables keepalive on its own sockets with
# its own 45 s idle time, so always_keepalive and keepidle would not affect it; they are
# listed here at their defaults so that 'on' also undoes the first release, which set them.
FIX=(0 7200000 1000 2)
DEFAULTS=(0 7200000 75000 8)

EXAM_HOST="www.starttest.com"
DEFAULT_IDLE=150

# 'install' writes a launchd job here so the fix is re-applied at every startup.
DAEMON_LABEL="com.nbme-keepalive-fix"
DAEMON_DIR=${NBME_FIX_DAEMON_DIR:-/Library/LaunchDaemons}
DAEMON_PLIST="$DAEMON_DIR/$DAEMON_LABEL.plist"

usage() {
  cat <<EOF
Usage: $(basename "$0") on | off | install | uninstall | status | test [idle_seconds]

  on         apply the TCP keepalive fix until the next reboot (needs sudo)
  off        restore the macOS default TCP keepalive settings (needs sudo)
  install    apply the fix now AND at every startup, until uninstalled (needs sudo)
  uninstall  remove the startup job and restore the defaults (needs sudo)
  status     show the current settings and whether the fix is active
  test       open a browser-style idle connection to $EXAM_HOST and check that a
             silently dropped connection is detected (default idle: ${DEFAULT_IDLE}s)
EOF
}

require_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "This script only works on macOS (it sets macOS-specific net.inet.tcp sysctls)." >&2
    exit 1
  fi
}

# Prints ACTIVE, OFF or PARTIAL for the live settings.
current_state() {
  local i value fix_matches=0 default_matches=0
  for i in 0 1 2 3; do
    value=$(sysctl -n "${KEYS[$i]}")
    [ "$value" = "${FIX[$i]}" ] && fix_matches=$((fix_matches + 1))
    [ "$value" = "${DEFAULTS[$i]}" ] && default_matches=$((default_matches + 1))
  done
  if [ "$fix_matches" -eq 4 ]; then
    echo ACTIVE
  elif [ "$default_matches" -eq 4 ]; then
    echo OFF
  else
    echo PARTIAL
  fi
}

show_status() {
  local i
  printf '%-32s %10s %10s %10s\n' "setting" "current" "fix" "default"
  for i in 0 1 2 3; do
    printf '%-32s %10s %10s %10s\n' "${KEYS[$i]}" "$(sysctl -n "${KEYS[$i]}")" "${FIX[$i]}" "${DEFAULTS[$i]}"
  done
  echo
  case "$(current_state)" in
    ACTIVE)
      if daemon_installed; then
        echo "Fix is ACTIVE and re-applied at every startup until you run '$(basename "$0") uninstall'."
      else
        echo "Fix is ACTIVE. It stays on until you run '$(basename "$0") off' or reboot."
      fi
      ;;
    OFF) echo "Fix is OFF (macOS defaults). Run '$(basename "$0") on' before starting the exam." ;;
    PARTIAL) echo "Fix is PARTIAL: the values match neither the fix nor the defaults. Run 'on' or 'off' to reset them." ;;
  esac
  if daemon_installed; then
    echo "Boot job: installed ($DAEMON_PLIST)."
  else
    echo "Boot job: not installed, so the fix resets at reboot. '$(basename "$0") install' makes it stick."
  fi
}

daemon_installed() {
  [ -f "$DAEMON_PLIST" ]
}

write_plist() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$DAEMON_LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/sbin/sysctl</string>
		<string>-w</string>
		<string>${KEYS[0]}=${FIX[0]}</string>
		<string>${KEYS[1]}=${FIX[1]}</string>
		<string>${KEYS[2]}=${FIX[2]}</string>
		<string>${KEYS[3]}=${FIX[3]}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
</dict>
</plist>
EOF
}

install_daemon() {
  local tmp
  tmp=$(mktemp)
  write_plist > "$tmp"
  # launchd only accepts daemon plists that are owned by root and not group/world
  # writable, so the file is created by root through sudo with a 022 umask.
  if ! sudo sh -c "umask 022 && cat > '$DAEMON_PLIST'" < "$tmp"; then
    rm -f "$tmp"
    echo "The boot job was not installed (sudo failed)." >&2
    exit 1
  fi
  rm -f "$tmp"
  sudo launchctl bootout "system/$DAEMON_LABEL" >/dev/null 2>&1 || true
  if ! sudo launchctl bootstrap system "$DAEMON_PLIST"; then
    echo "The boot job was written but launchd refused to load it." >&2
    exit 1
  fi
}

remove_daemon() {
  sudo launchctl bootout "system/$DAEMON_LABEL" >/dev/null 2>&1 || true
  if daemon_installed && ! sudo rm -f "$DAEMON_PLIST"; then
    echo "The boot job could not be removed (sudo failed)." >&2
    exit 1
  fi
}

# apply_values <failure message> <four values...>
apply_values() {
  local failure=$1 i args=()
  shift
  local values=("$@")
  for i in 0 1 2 3; do
    args+=("${KEYS[$i]}=${values[$i]}")
  done
  if ! sudo sysctl -w "${args[@]}"; then
    echo "$failure" >&2
    exit 1
  fi
}

find_python() {
  local py
  py=$(command -v python3 || true)
  # /usr/bin/python3 is only a stub that pops an installer dialog until the
  # Xcode Command Line Tools are installed.
  if [ -z "$py" ] || { [ "$py" = "/usr/bin/python3" ] && ! xcode-select -p >/dev/null 2>&1; }; then
    echo "'test' needs Python 3. Install it with: xcode-select --install" >&2
    exit 1
  fi
  echo "$py"
}

run_probe() {
  local idle=$1 py
  py=$(find_python)
  echo "Opening a browser-style idle connection to $EXAM_HOST (idle ${idle}s, then one more request)..."
  "$py" - "$EXAM_HOST" "$idle" <<'PROBE'
import socket
import ssl
import sys
import time

host, idle = sys.argv[1], int(sys.argv[2])
RESPONSE_TIMEOUT = 20
TCP_KEEPALIVE = 0x10  # macOS: seconds idle before the first probe; Chrome uses 45
REQUEST = (
    f"HEAD / HTTP/1.1\r\nHost: {host}\r\nUser-Agent: nbme-keepalive-fix-probe\r\n"
    "Connection: keep-alive\r\n\r\n"
).encode()


def head(sock):
    sock.sendall(REQUEST)
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = sock.recv(4096)
        if not chunk:
            raise ConnectionResetError("peer closed the connection")
        buf += chunk


def our_timer_expired(err):
    # The kernel's keepalive timeout is also a TimeoutError, but carries errno ETIMEDOUT.
    return isinstance(err, TimeoutError) and err.errno is None


try:
    raw = socket.create_connection((host, 443), timeout=15)
    raw.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    raw.setsockopt(socket.IPPROTO_TCP, TCP_KEEPALIVE, 45)
    sock = ssl.create_default_context().wrap_socket(raw, server_hostname=host)
    sock.settimeout(RESPONSE_TIMEOUT)
    head(sock)
except OSError as err:
    print(f"ERROR: could not reach {host}: {err}")
    sys.exit(3)

started = time.time()
while time.time() - started < idle:
    time.sleep(min(3, max(0.1, idle - (time.time() - started))))
    sock.setblocking(False)
    try:
        if sock.recv(1) == b"":
            raise ConnectionResetError("peer closed the connection")
    except (ssl.SSLWantReadError, BlockingIOError):
        pass
    except OSError as err:
        waited = time.time() - started
        if isinstance(err, TimeoutError):
            print(f"PASS: macOS detected the silently dropped connection after {waited:.0f}s idle.")
            print("      A browser discards it and reconnects instead of hanging.")
        else:
            print(f"OK: the server closed the idle connection cleanly after {waited:.0f}s ({type(err).__name__}).")
            print("    No silent drop seen; a browser reconnects without hanging.")
        sys.exit(0)
    finally:
        sock.settimeout(RESPONSE_TIMEOUT)

try:
    head(sock)
except OSError as err:
    if our_timer_expired(err):
        print(f"FAIL: the connection was silently dropped and nothing noticed ({RESPONSE_TIMEOUT}s with no reply).")
        print("      A browser would hang here and the exam would time out. Is the fix on? Run: status")
        sys.exit(1)
    print(f"PASS: the dead connection failed fast on reuse ({type(err).__name__}); a browser just reconnects.")
    sys.exit(0)

print(f"INCONCLUSIVE: the connection was still alive after {idle}s idle, so there was no drop to detect.")
print("              Use the default idle (150s) or longer.")
sys.exit(2)
PROBE
}

main() {
  local command=${1:-}
  case "$command" in
    on)
      require_macos
      apply_values "The fix was not applied (sudo failed)." "${FIX[@]}"
      echo
      show_status
      ;;
    off)
      require_macos
      apply_values "The defaults were not restored (sudo failed)." "${DEFAULTS[@]}"
      echo
      show_status
      if daemon_installed; then
        echo
        echo "Note: the boot job is still installed, so the fix comes back at the next startup."
        echo "Run '$(basename "$0") uninstall' to remove it for good."
      fi
      ;;
    install)
      require_macos
      apply_values "The fix was not applied (sudo failed)." "${FIX[@]}"
      install_daemon
      echo
      show_status
      ;;
    uninstall)
      require_macos
      remove_daemon
      apply_values "The defaults were not restored (sudo failed)." "${DEFAULTS[@]}"
      echo
      show_status
      ;;
    status)
      require_macos
      show_status
      ;;
    test)
      require_macos
      local idle=${2:-$DEFAULT_IDLE}
      case "$idle" in
        '' | *[!0-9]*)
          usage >&2
          exit 64
          ;;
      esac
      run_probe "$idle"
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
}

main "$@"
