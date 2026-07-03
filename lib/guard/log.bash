#!/usr/bin/env bash
# lib/guard/log.bash -- flat key=value logging + best-effort desktop notify (PRIVATE)
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

# guard_log k=v [k=v ...] -- append a flat key=value record with an ISO-8601
# timestamp to LOG_FILE (created lazily). Echo to stdout only on a TTY; under
# launchd stdout is redirected to LOG_FILE, so echoing there would double lines.
# Timestamp is derived from the rg_now clock seam so tests can pin it. Never
# fails the caller (best-effort log).
guard_log() {
  local ts line dir
  printf -v ts '%(%Y-%m-%dT%H:%M:%S%z)T' "$(rg_now)"
  line="ts=$ts $*"
  dir="${LOG_FILE%/*}"
  [[ -d $dir ]] || mkdir -p "$dir" 2> /dev/null || true
  printf '%s\n' "$line" >> "$LOG_FILE" 2> /dev/null || true
  [[ -t 1 ]] && printf '%s\n' "$line"
  return 0
}

# guard_notify <title> <msg> -- best-effort macOS desktop notification via the
# injectable osascript adapter. Honours the NOTIFY tunable when set (default on).
# Double quotes inside title/msg are squashed to single quotes so the AppleScript
# string literal stays well-formed. Never fails the caller.
guard_notify() {
  ((${NOTIFY:-1})) || return 0
  local title="${1:-}" msg="${2:-}"
  # Strip backslashes FIRST, then squash double quotes to single quotes. A comm
  # ending in `\` would otherwise escape the closing `"` and produce malformed
  # AppleScript (DoS; no RCE since `"` is already squashed).
  local m="${msg//\\/}" t="${title//\\/}"
  m="${m//\"/\'}"
  t="${t//\"/\'}"
  "$RG_OSASCRIPT" -e \
    "display notification \"$m\" with title \"$t\"" \
    > /dev/null 2>&1 || true
  return 0
}
