#!/usr/bin/env bash
# lib/guard/agent.bash -- per-user launchd LaunchAgent install/uninstall (PRIVATE)
if [ -z "${BASH_VERSINFO+set}" ]; then
  echo >&2 'error: ramgate requires GNU bash'
  exit 78 # EX_CONFIG
fi
((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3))) || {
  printf >&2 'error: bash 5.3+ required (found %s)\n' "$BASH_VERSION"
  exit 78
}
set -uo pipefail
IFS=$' \t\n'
export LC_ALL=C

# guard_plist_path -- absolute path to this user's LaunchAgent plist.
guard_plist_path() {
  printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$LABEL"
}

# _guard_agent_bin -- absolute path to the ram-guard binary launchd must invoke.
# Honours an RG_SELF override (tests / relocation); otherwise derives it from this
# file's location: <root>/lib/guard/agent.bash -> <root>/bin/ram-guard.
_guard_agent_bin() {
  if [[ -n ${RG_SELF:-} ]]; then
    printf '%s' "$RG_SELF"
    return 0
  fi
  local here root
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  root="$(cd "$here/../.." && pwd)"
  printf '%s/bin/ram-guard' "$root"
}

# _guard_write_plist -- render the LaunchAgent plist. ThrottleInterval is set
# explicitly (>=10s) so a crash-on-bad-conf cannot respawn-spam launchd, and
# KeepAlive keeps the watchdog running. Creates the LaunchAgents and log dirs
# lazily. Echoes the plist path on success.
_guard_write_plist() {
  local plist bin logf
  plist="$(guard_plist_path)"
  bin="$(_guard_agent_bin)"
  logf="$LOG_FILE"
  mkdir -p "${plist%/*}" "${logf%/*}" || return 1
  cat > "$plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/homebrew/bin/bash</string>
    <string>${bin}</string>
    <string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>${logf}</string>
  <key>StandardErrorPath</key><string>${logf}</string>
</dict>
</plist>
EOF
  [[ -s $plist ]] || {
    printf 'error: failed to write %s\n' "$plist" >&2
    return 1
  }
  printf '%s' "$plist"
}

# guard_install -- write the plist and (re)load the LaunchAgent. Preserves the
# bootout-then-poll install-race fix: bootstrap races a still-terminating
# KeepAlive job and fails with EIO unless we wait for the old instance to vanish.
guard_install() {
  local plist uid i
  uid="${RG_UID:-$UID}"
  plist="$(_guard_write_plist)" || {
    printf 'error: could not write LaunchAgent plist\n' >&2
    return 1
  }
  "$RG_LAUNCHCTL" bootout "gui/$uid/$LABEL" > /dev/null 2>&1 || true
  for ((i = 0; i < 50; i++)); do
    "$RG_LAUNCHCTL" print "gui/$uid/$LABEL" > /dev/null 2>&1 || break
    "$RG_SLEEP" 0.1
  done
  if ! "$RG_LAUNCHCTL" bootstrap "gui/$uid" "$plist"; then
    printf 'error: launchctl bootstrap failed for %s\n' "$plist" >&2
    return 1
  fi
  "$RG_LAUNCHCTL" enable "gui/$uid/$LABEL" 2> /dev/null || true
  printf 'installed and loaded: %s\n' "$plist"
}

# guard_uninstall -- unload and remove the LaunchAgent.
guard_uninstall() {
  local uid
  uid="${RG_UID:-$UID}"
  "$RG_LAUNCHCTL" bootout "gui/$uid/$LABEL" > /dev/null 2>&1 || true
  rm -f "$(guard_plist_path)"
  printf 'uninstalled: %s\n' "$(guard_plist_path)"
}
