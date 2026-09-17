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
  local sid=$1 user uid attempt answer hint

  user=$(conf_get EMW_USER "")
  uid=""
  [[ -n $user ]] && uid=$(id -u "$user" 2>/dev/null || true)

  if [[ -n $uid ]]; then
    # Retry briefly. This is called the instant the lid opens, while the
    # compositor is still re-enumerating monitors and the shell may not answer
    # on the first try. A second of patience here is far cheaper than
    # misclassifying the incident.
    for attempt in 1 2 3 4; do
      answer=$(emw_shell_as_user "$user" "$uid" lock isLocked 2>/dev/null || true)
      case $answer in
      true)
        printf 'yes'
        return 0
        ;;
      false)
        printf 'no'
        return 0
        ;;
      esac
      sleep 0.5
    done
  fi

  # Fallback for a session that is not this shell. Note LockedHint is NOT
  # trusted above: Quickshell never sets it, so a definite-looking "no" from
  # logind would silently override a correct "locked" answer.
  hint=$(loginctl show-session "$sid" -p LockedHint --value 2>/dev/null || true)
  case $hint in
  yes | no) printf '%s' "$hint" ;;
  *) printf 'unknown' ;;
  esac
}

# emw_shell_as_user <user> <uid> <target> <method> [args...]
# Calls the Omarchy Quickshell IPC as the desktop user. omarchy-shell locates
# the shell through the Wayland socket in XDG_RUNTIME_DIR, so that variable has
# to be set even when we are already the right user.
emw_shell_as_user() {
  local user=$1 uid=$2
  shift 2
  if ((EUID == 0)); then
    runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" \
      omarchy-shell "$@"
  else
    XDG_RUNTIME_DIR="/run/user/$uid" omarchy-shell "$@"
  fi
}
