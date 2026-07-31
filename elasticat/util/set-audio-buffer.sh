#!/usr/bin/env bash
# set-audio-buffer.sh -- reversibly change the norns JACK period size for CPU
# headroom, WITHOUT editing the stock service file. Drives the Elasticat
# "AUDIO INTERFACE" settings page, and works standalone over maiden/SSH.
#
#   ./set-audio-buffer.sh status     # machine-readable live/target/stock/override
#   ./set-audio-buffer.sh 256        # high-headroom: -p 256  (SLEEP->wake to apply)
#   ./set-audio-buffer.sh 512        # max headroom:  -p 512  (more latency)
#   ./set-audio-buffer.sh reset      # remove the override -> back to norns stock (128)
#
# Elasticat is a heavy engine; the norns ships jack at -p 128 (a 2.7 ms per-cycle
# deadline) for low latency, which leaves little slack and causes "crone was not
# finished" xrun storms under load. -p 256 doubles the per-cycle budget to 5.3 ms
# (a few ms more latency) and largely stops them; -p 512 is 10.7 ms.
#
# HOW IT WORKS: a systemd DROP-IN at
#   /etc/systemd/system/norns-jack.service.d/10-elasticat-buffer.conf
# overrides only ExecStart, copied from the stock line with -p substituted, so it
# adapts to whatever the stock command is (device name, flags). "reset" deletes the
# drop-in -> the norns default returns, cleanly. Applying needs a jack restart, so
# SLEEP->wake or reboot after changing it (it can't hot-swap under a running script).
#
# Uses `sudo -n` (passwordless -- the norns default for `we`); it fails fast with a
# clear message instead of hanging if a norns has been hardened to require a password.
set -euo pipefail

DROPIN_DIR=/etc/systemd/system/norns-jack.service.d
DROPIN="$DROPIN_DIR/10-elasticat-buffer.conf"

live_arg() {  # $1 = flag letter (p|n); prints the live jackd value, or empty
  local pid; pid=$(pgrep -x jackd 2>/dev/null | head -1) || true
  if [ -n "${pid:-}" ] && [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' ' ' < "/proc/$pid/cmdline" | grep -oE -- "-$1 [0-9]+" | awk '{print $2}'
  fi
}

stock_execstart() {  # the ORIGINAL ExecStart from the unit file, ignoring drop-ins
  systemctl cat norns-jack.service \
    | awk '/^# .*norns-jack\.service$/{m=1} m && /^ExecStart=/{sub(/^ExecStart=/,""); print; exit}'
}

arg_of() { printf '%s' "$1" | grep -oE -- "-p [0-9]+" | awk '{print $2}'; }

require_sudo() {
  sudo -n true 2>/dev/null || {
    echo "ERROR: passwordless sudo required (the norns default for 'we')." >&2
    echo "       Edit $DROPIN by hand + 'systemctl daemon-reload' if your norns needs a password." >&2
    exit 3
  }
}

case "${1:-status}" in
  status)
    live=$(live_arg p); [ -n "$live" ] || live="?"
    stock=$(arg_of "$(stock_execstart)"); [ -n "$stock" ] || stock="?"
    if [ -f "$DROPIN" ]; then
      target=$(arg_of "$(grep -E '^ExecStart=.+' "$DROPIN" | tail -1)"); ov=on
    else
      target="$stock"; ov=off
    fi
    echo "live: $live"
    echo "target: $target"
    echo "stock: $stock"
    echo "override: $ov"
    ;;
  reset|default|off|128)
    require_sudo
    sudo -n rm -f "$DROPIN"
    sudo -n systemctl daemon-reload
    echo "OK reset to norns stock buffer. SLEEP->wake or reboot to apply."
    ;;
  *[!0-9]*|'')
    echo "usage: $0 [status | reset | <period, e.g. 256 or 512>]" >&2; exit 1 ;;
  *)
    require_sudo
    period="$1"
    stock=$(stock_execstart)
    [ -n "$stock" ] || { echo "ERROR: could not read stock ExecStart" >&2; exit 1; }
    new=$(printf '%s' "$stock" | sed -E "s/-p [0-9]+/-p $period/")
    sudo -n mkdir -p "$DROPIN_DIR"
    printf '[Service]\nExecStart=\nExecStart=%s\n' "$new" | sudo -n tee "$DROPIN" >/dev/null
    sudo -n systemctl daemon-reload
    echo "OK period set to $period. SLEEP->wake or reboot to apply."
    ;;
esac
