#!/bin/bash

# Shared helpers. Source this, do not run it.
#
# Everything here runs as root, so the config is PARSED rather than sourced.
# Sourcing a config file is arbitrary code execution the moment that file is
# writable by anyone but root - and a security tool that can be turned into a
# root shell by editing its own settings is worse than no tool. /etc/omarchy/
# emw.conf is 0600 root:root today, so this is defence in depth rather than a
# live hole, but it costs eight lines.

readonly EMW_CONFIG_FILE=${EMW_CONFIG_FILE:-/etc/omarchy/emw.conf}

# conf_get <KEY> <default>
# Reads one scalar. Values are returned verbatim as strings and are never
# evaluated, so a value like `x; rm -rf /` is just an odd string.
conf_get() {
  local key=$1 default=$2 value=""
  if [[ -r $EMW_CONFIG_FILE ]]; then
    value=$(sed -n "s/^[[:space:]]*$key=\([^#]*\).*/\1/p" "$EMW_CONFIG_FILE" |
      tr -d '"'\''' | sed 's/[[:space:]]*$//' | head -1)
  fi
  printf '%s' "${value:-$default}"
}

# conf_bool <KEY> <default-true|false>
# Anything that is not exactly "true" is false, so a typo fails closed for
# enable-flags and open for disable-flags. Callers pick the default to match.
conf_bool() {
  [[ $(conf_get "$1" "$2") == "true" ]]
}

# emw_user_home
# Resolves the desktop user's home. A system service cannot use $HOME or
# systemd's %h for this: both are /root.
emw_user_home() {
  local user
  user=$(conf_get EMW_USER "")
  [[ -n $user ]] || return 1
  getent passwd "$user" | cut -d: -f6
}

# emw_session_id
# The desktop user's seated, user-class session. A user typically has several
# sessions - here a seat0 tty session and a seatless "manager" one - and only
# the seated one has a lock screen, so matching on Class and Seat matters.
# Prints nothing and returns 1 when there is no graphical session at all.
emw_session_id() {
  local want sid props name
  want=$(conf_get EMW_USER "")
  while read -r sid _rest; do
    [[ -n $sid ]] || continue
    props=$(loginctl show-session "$sid" -p Name -p Class -p Seat 2>/dev/null) || continue
    [[ $props == *"Class=user"* ]] || continue
    [[ $props == *"Seat=seat"* ]] || continue
    name=${props#*Name=}
    name=${name%%$'\n'*}
    if [[ -z $want || $name == "$want" ]]; then
      printf '%s' "$sid"
      return 0
    fi
  done < <(loginctl list-sessions --no-legend 2>/dev/null || true)
  return 1
}

# emw_locked <session-id>
# Prints yes | no | unknown.
#
# logind's LockedHint is NOT authoritative here. Omarchy's lock screen is
# Quickshell, which takes the lock through the ext-session-lock Wayland
# protocol and never tells logind, so LockedHint reads "no" the whole time the
# screen is locked. Omarchy ships omarchy-hyprland-session-locked precisely
# because, as its own comment puts it, "Hyprland reports no lock state
# directly" - it infers the lock from LOCK appearing in a monitor's
# solitaryBlockedBy. Ask that first and keep LockedHint only as a fallback for
# lockers that do talk to logind.
#
# Callers must treat "unknown" as locked: failing toward running the grace
# period and possibly alerting is the safe direction for a security tool.
emw_locked() {
  local sid=$1 user uid his hyprdir rc hint

  user=$(conf_get EMW_USER "")
  uid=""
  [[ -n $user ]] && uid=$(id -u "$user" 2>/dev/null || true)

  if [[ -n $uid && -d /run/user/$uid/hypr ]]; then
    for hyprdir in /run/user/"$uid"/hypr/*/; do
      # A stale instance directory outlives its compositor; only a live socket
      # means hyprctl will actually get an answer.
      [[ -S $hyprdir/.socket.sock ]] || continue
      his=$(basename "$hyprdir")
      rc=0
      if ((EUID == 0)); then
        runuser -u "$user" -- env \
          XDG_RUNTIME_DIR="/run/user/$uid" \
          HYPRLAND_INSTANCE_SIGNATURE="$his" \
          omarchy-hyprland-session-locked || rc=$?
      else
        XDG_RUNTIME_DIR="/run/user/$uid" \
          HYPRLAND_INSTANCE_SIGNATURE="$his" \
          omarchy-hyprland-session-locked || rc=$?
      fi
      case $rc in
      0)
        printf 'yes'
        return 0
        ;;
      1)
        printf 'no'
        return 0
        ;;
      esac
      # rc 2 means the compositor could not decide; try logind below.
    done
  fi

  hint=$(loginctl show-session "$sid" -p LockedHint --value 2>/dev/null || true)
  case $hint in
  yes | no) printf '%s' "$hint" ;;
  *) printf 'unknown' ;;
  esac
}
