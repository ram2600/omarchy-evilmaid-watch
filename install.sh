#!/bin/bash

# Install Omarchy EvilMaid Watch. Idempotent: safe to re-run after an edit.
#
# Deploys to /usr/local rather than into the Omarchy checkout, so `omarchy
# update` cannot clobber it and this stays a separate, publishable project.
# Note that /usr/share/omarchy/bin/omarchy only scans its OWN directory for
# subcommands, so `omarchy emw ...` will NOT route until these are copied
# into the Omarchy tree. Call the binaries directly for now - they are on PATH.

set -euo pipefail

readonly REPO_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
readonly BIN_DIR=/usr/local/bin
readonly LIB_DIR=/usr/local/lib/omarchy-emw
readonly CONF_DIR=/etc/omarchy
readonly CONF_FILE="$CONF_DIR/emw.conf"
readonly HOOK_DIR="$CONF_DIR/emw-hooks.d"
readonly STATE_DIR=/var/lib/omarchy-emw
readonly UNIT_DIR=/etc/systemd/system

if ((EUID != 0)); then
  echo "install.sh must run as root: sudo $0" >&2
  exit 1
fi

# The desktop user is whoever invoked sudo, not root. Resolving it here means
# the config ships correct and the daemon never has to guess at runtime.
target_user=${SUDO_USER:-}
if [[ -z $target_user || $target_user == "root" ]]; then
  target_user=$(loginctl list-sessions --no-legend 2>/dev/null |
    while read -r sid _; do
      props=$(loginctl show-session "$sid" -p Name -p Class -p Seat 2>/dev/null)
      if [[ $props == *"Class=user"* && $props == *"Seat=seat"* ]]; then
        name=${props#*Name=}
        echo "${name%%$'\n'*}"
        break
      fi
    done)
fi

if [[ -z $target_user ]]; then
  echo "could not determine the desktop user; re-run with sudo from your session" >&2
  exit 1
fi

echo -e "\nInstalling Omarchy EvilMaid Watch for user '$target_user'..."

# --- Programs --------------------------------------------------------------
install -d -m 0755 "$LIB_DIR"
install -m 0755 "$REPO_DIR"/bin/omarchy-emw-* "$BIN_DIR/"
install -m 0644 "$REPO_DIR"/lib/*.py "$LIB_DIR/"
install -m 0644 "$REPO_DIR"/lib/*.sh "$LIB_DIR/"

# --- Config ----------------------------------------------------------------
install -d -m 0755 "$CONF_DIR"
if [[ -f $CONF_FILE ]]; then
  echo "  keeping existing $CONF_FILE"
else
  install -m 0600 -o root -g root "$REPO_DIR/etc/emw.conf.example" "$CONF_FILE"
  # Bake in the resolved user so the daemon never has to guess.
  sed -i "s/^EMW_USER=.*/EMW_USER=$target_user/" "$CONF_FILE"
  echo "  wrote $CONF_FILE (0600 root:root)"
fi

# --- Hooks -----------------------------------------------------------------
# Root-owned on purpose. These run as root on an intruder verdict, so a
# user-writable hook directory would be a straight privilege escalation:
# anything running as the desktop user could drop a script here and get root
# on the next lid open, bypassing the sudo password entirely.
install -d -m 0755 -o root -g root "$HOOK_DIR"

# --- Evidence store --------------------------------------------------------
install -d -m 0700 -o root -g root "$STATE_DIR"
install -d -m 0700 -o root -g root "$STATE_DIR/incidents"

readonly EVENTS_LOG="$STATE_DIR/events.log"
if [[ ! -f $EVENTS_LOG ]]; then
  : >"$EVENTS_LOG"
  chmod 0600 "$EVENTS_LOG"
fi

# Append-only. An O_APPEND write still succeeds with +a set, so this is applied
# once and never cleared at runtime - clearing it per write would open exactly
# the window it exists to close. It stops truncation, unlink and rewriting by
# anyone who is not root; it does NOT stop a root attacker, who can chattr -a.
# Real integrity comes from shipping the alert off the box.
if chattr +a "$EVENTS_LOG" 2>/dev/null; then
  echo "  events.log is append-only (chattr +a)"
else
  echo "  WARNING: could not set append-only on $EVENTS_LOG" >&2
  echo "           the log is still 0600 root:root, but is locally rewritable by root" >&2
fi

# --- Service ---------------------------------------------------------------
install -m 0644 "$REPO_DIR/systemd/omarchy-emw.service" "$UNIT_DIR/"
install -m 0644 "$REPO_DIR/systemd/omarchy-emw-spool.service" "$UNIT_DIR/"
install -m 0644 "$REPO_DIR/systemd/omarchy-emw-spool.timer" "$UNIT_DIR/"
install -m 0644 "$REPO_DIR/systemd/omarchy-emw-resume.service" "$UNIT_DIR/"
install -m 0644 "$REPO_DIR/systemd/omarchy-emw-faillock.service" "$UNIT_DIR/"
install -m 0644 "$REPO_DIR/systemd/99-omarchy-emw-usb.rules" /etc/udev/rules.d/
install -d -m 0700 -o root -g root "$STATE_DIR/spool"
systemctl daemon-reload
systemctl enable --now omarchy-emw-spool.timer
systemctl enable omarchy-emw-resume.service
systemctl enable omarchy-emw-faillock.service
systemctl restart omarchy-emw-faillock.service
udevadm control --reload-rules
systemctl enable omarchy-emw.service
# restart, not `enable --now`: --now only *starts* a stopped unit, so on a
# re-install the long-running watcher would keep executing the previous
# version of lidwatch.py. The trigger is re-exec'd per event and so picks up
# changes immediately, which makes this mismatch easy to miss - the new
# trigger runs while the old watcher feeds it.
systemctl restart omarchy-emw.service

echo -e "\nInstalled. Status:"
systemctl --no-pager --lines=0 status omarchy-emw.service || true

cat <<EOF

Next:
  journalctl -u omarchy-emw -f          # watch it live
  sudo omarchy-emw-show                 # view the latest incident
  sudo tail -f $EVENTS_LOG   # the append-only log

Lock the screen, then close and reopen the lid to produce an incident.
Unlock within the grace window and it stays silent; walk away and it escalates.

NOTE: capturing lights the camera LED. That is hardware-wired on this machine
and is intended - the same visible deterrent macOS gives you.
EOF

# Report the alerting state rather than asserting one. This line used to say
# alerts were off unconditionally, including on machines that had just sent a
# Telegram - an install message that lies about whether you will be told.
alert_channel=$(sed -n 's/^[[:space:]]*ALERT_CHANNEL=\([^#]*\).*/\1/p' "$CONF_FILE" 2>/dev/null | tr -d '"'"'"'[:space:]' | head -1)
if [[ -n ${alert_channel:-} && $alert_channel != none ]]; then
  echo "Remote alerts: $alert_channel (configured in $CONF_FILE)."
else
  echo "Remote alerts are off until you set ALERT_CHANNEL in $CONF_FILE."
fi
