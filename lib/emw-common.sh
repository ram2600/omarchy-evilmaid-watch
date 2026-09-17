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
# The second argument caps the probe attempts. The initial sample after a lid
# opens wants a few, because the shell may still be returning from suspend. The
# grace loop wants exactly one: it already re-probes every 2s for a minute, so
# retrying inside each poll multiplies the work for no extra information.
emw_locked() {
  local sid=$1 tries=${2:-4} user uid attempt answer hint

  user=$(conf_get EMW_USER "")
  uid=""
  [[ -n $user ]] && uid=$(id -u "$user" 2>/dev/null || true)

  if [[ -n $uid ]]; then
    # Probe briefly, then give up and let the caller's grace loop do the
    # waiting. This runs the instant the lid opens - which, after a suspend, is
    # while the shell is still coming back and may not answer at all. The probe
    # is kept short on purpose: it sits in front of the camera capture, and
    # delaying the photo to interrogate the lock screen is backwards when the
    # person we want a picture of is standing there now.
    #
    # Giving up fast is safe because "unknown" counts as locked, so the grace
    # loop runs anyway and re-probes every 2s for the full window. That loop is
    # where a shell recovering from resume gets the time it needs.
    for ((attempt = 0; attempt < tries; attempt++)); do
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
      ((attempt + 1 < tries)) && sleep 0.25
    done
  fi

  # We get here only when the IPC never answered.
  #
  # If this IS a Wayland session, refuse to fall back to LockedHint. Quickshell
  # never sets it, so logind would confidently answer "no" - and "no" routes
  # straight to the attended verdict, which alerts nobody. A shell too busy to
  # reply would therefore silently disarm the watcher at precisely the moment
  # something is happening. Report "unknown" instead, which callers treat as
  # locked and which still runs the grace period.
  if [[ -n $uid ]] && compgen -G "/run/user/$uid/wayland-[0-9]*" >/dev/null 2>&1; then
    printf 'unknown'
    return 0
  fi

  # No Wayland session at all: a different locker may well maintain LockedHint,
  # so it is the best signal available here.
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
  local user=$1 uid=$2 gid
  shift 2

  if ((EUID != 0)); then
    XDG_RUNTIME_DIR="/run/user/$uid" omarchy-shell "$@"
    return
  fi

  # setpriv, not runuser. runuser opens a full PAM session for every call, and
  # the grace loop polls for a minute - one incident produced 722 journal lines
  # of pam_unix/pam_lastlog2 chatter, drowning the security log it is supposed
  # to be writing. setpriv only changes credentials: no PAM, no session, no log
  # entry. runuser stays as a fallback in case setpriv is unavailable.
  gid=$(id -g "$user" 2>/dev/null || echo "$uid")
  if setpriv --reuid="$uid" --regid="$gid" --init-groups -- \
    env XDG_RUNTIME_DIR="/run/user/$uid" omarchy-shell "$@" 2>/dev/null; then
    return 0
  fi

  runuser -u "$user" -- env XDG_RUNTIME_DIR="/run/user/$uid" omarchy-shell "$@"
}
