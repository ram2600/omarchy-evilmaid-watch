#!/bin/bash

# Remove Omarchy EvilMaid Watch.
#
# Config and evidence are KEPT unless explicitly asked for, because both are
# things you cannot get back: the config holds API tokens, and the evidence is
# the record of everything that ever triggered. Removing the software should
# never be the thing that destroys the photographs it took.
#
#   sudo ./uninstall.sh                     stop and remove the software
#   sudo ./uninstall.sh --purge-config      also remove /etc/omarchy/emw.conf
#   sudo ./uninstall.sh --purge-evidence    also remove /var/lib/omarchy-emw
#   sudo ./uninstall.sh --purge             both
#
# Reconfiguring from scratch is the supported path for a major version change -
# this project does not migrate configs forward. --purge-config then a fresh
# install.sh gives you a config written by the version you are running, with
# every value stated rather than inherited.

set -euo pipefail

readonly BIN_DIR=/usr/local/bin
readonly LIB_DIR=/usr/local/lib/omarchy-emw
readonly CONF_DIR=/etc/omarchy
readonly CONF_FILE="$CONF_DIR/emw.conf"
readonly HOOK_DIR="$CONF_DIR/emw-hooks.d"
readonly STATE_DIR=/var/lib/omarchy-emw
readonly RUNTIME_DIR=/run/omarchy-emw
readonly UNIT_DIR=/etc/systemd/system
readonly UDEV_RULE=/etc/udev/rules.d/99-omarchy-emw-usb.rules

purge_config=false
purge_evidence=false
while (($# > 0)); do
  case $1 in
  --purge-config) purge_config=true ;;
  --purge-evidence) purge_evidence=true ;;
  --purge)
    purge_config=true
    purge_evidence=true
    ;;
  *)
    echo "usage: uninstall.sh [--purge-config] [--purge-evidence] [--purge]" >&2
    exit 64
    ;;
  esac
  shift
done

if ((EUID != 0)); then
  echo "uninstall.sh must run as root: sudo $0" >&2
  exit 1
fi

echo -e "\nRemoving Omarchy EvilMaid Watch..."

# --- Units -----------------------------------------------------------------
# Stop before disable: a disabled unit that is still running would keep
# watching the lid until reboot, which is exactly the surprise an uninstall
# must not leave behind.
units=(
  omarchy-emw.service
  omarchy-emw-faillock.service
  omarchy-emw-resume.service
  omarchy-emw-spool.timer
  omarchy-emw-spool.service
)
for unit in "${units[@]}"; do
  systemctl stop "$unit" 2>/dev/null || true
  systemctl disable "$unit" 2>/dev/null || true
  rm -f "$UNIT_DIR/$unit"
done
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
echo "  units stopped, disabled and removed"

# --- udev ------------------------------------------------------------------
if [[ -f $UDEV_RULE ]]; then
  rm -f "$UDEV_RULE"
  udevadm control --reload-rules 2>/dev/null || true
  echo "  udev rule removed"
fi

# --- Programs --------------------------------------------------------------
rm -f "$BIN_DIR"/omarchy-emw-*
rm -rf "$LIB_DIR"
# RuntimeDirectoryPreserve=yes means staged toast photos outlive the units.
rm -rf "$RUNTIME_DIR"
echo "  programs removed"

# --- Config ----------------------------------------------------------------
if $purge_config; then
  rm -f "$CONF_FILE"
  # Only if empty: a hook someone wrote is their work, not ours to delete.
  rmdir "$HOOK_DIR" 2>/dev/null && echo "  hook directory removed (was empty)" || true
  rmdir "$CONF_DIR" 2>/dev/null || true
  echo "  config removed"
else
  [[ -f $CONF_FILE ]] && echo "  KEPT $CONF_FILE (holds your API tokens; --purge-config to remove)"
fi

# --- Evidence --------------------------------------------------------------
if $purge_evidence; then
  # events.log is chattr +a, so rm alone fails with EPERM.
  chattr -a "$STATE_DIR/events.log" 2>/dev/null || true
  rm -rf "$STATE_DIR"
  echo "  evidence removed"
else
  if [[ -d $STATE_DIR ]]; then
    count=$(find "$STATE_DIR/incidents" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    echo "  KEPT $STATE_DIR ($count incident(s); --purge-evidence to remove)"
  fi
fi

echo -e "\nDone."
