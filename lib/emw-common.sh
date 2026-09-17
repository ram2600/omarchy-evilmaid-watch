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
