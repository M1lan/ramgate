#!/usr/bin/env bash
# lib/guard/ledger.bash -- restart-safe pause ledger for SIGSTOP'd victims (PRIVATE)
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

# The ledger persists every process we have SIGSTOP'd so a daemon restart can
# SIGCONT them again instead of leaving them frozen forever. One line per victim:
#   pid<TAB>start_epoch<TAB>comm
# start_epoch is the recycle guard: a PID reused by a different process after our
# restart will NOT have the same start time, so we never CONT the wrong process.

# guard_ledger_path -- absolute path to the ledger file (dir created lazily on write).
guard_ledger_path() {
  printf '%s/ramgate.paused' "${RG_STATE:-$HOME/var/run}"
}

# _guard_ledger_ensure_dir -- create the ledger's parent directory on demand.
_guard_ledger_ensure_dir() {
  local dir
  dir="${RG_STATE:-$HOME/var/run}"
  [[ -d $dir ]] || mkdir -p "$dir"
}

# guard_ledger_add <pid> <start_epoch> <comm> -- record a paused victim,
# de-duplicating any prior line for the same pid.
guard_ledger_add() {
  local pid="$1" start="$2" comm="$3" file
  file="$(guard_ledger_path)"
  guard_ledger_remove "$pid"
  _guard_ledger_ensure_dir || return 1
  printf '%s\t%s\t%s\n' "$pid" "$start" "$comm" >> "$file"
}

# guard_ledger_remove <pid> -- drop the ledger line(s) for a pid via atomic rewrite.
guard_ledger_remove() {
  local pid="$1" file tmp l_pid rest
  file="$(guard_ledger_path)"
  [[ -f $file ]] || return 0
  tmp="${file}.tmp.$$"
  while IFS=$'\t' read -r l_pid rest; do
    [[ -n $l_pid ]] || continue
    [[ $l_pid == "$pid" ]] && continue
    printf '%s\t%s\n' "$l_pid" "$rest"
  done < "$file" > "$tmp"
  mv -f "$tmp" "$file"
}

# guard_ledger_count -- echo the number of currently-ledgered (paused) pids.
# One non-empty line == one paused victim. Absent ledger yields 0.
guard_ledger_count() {
  local file pid rest count=0
  file="$(guard_ledger_path)"
  if [[ -f $file ]]; then
    while IFS=$'\t' read -r pid rest; do
      [[ -n $pid ]] || continue
      count=$((count + 1))
    done < "$file"
  fi
  printf '%s\n' "$count"
}

# guard_ledger_load -- read the ledger into the global assoc array GUARD_LEDGER,
# keyed by pid -> "start_epoch<TAB>comm". Absent file yields an empty map.
guard_ledger_load() {
  # GUARD_LEDGER is this function's OUTPUT map (§11 API), consumed by other guard
  # modules, not within this file -- hence shellcheck sees it as "unused".
  declare -gA GUARD_LEDGER=()
  local file pid start comm
  file="$(guard_ledger_path)"
  [[ -f $file ]] || return 0
  while IFS=$'\t' read -r pid start comm; do
    [[ -n $pid ]] || continue
    # shellcheck disable=SC2034
    GUARD_LEDGER["$pid"]="${start}"$'\t'"${comm}"
  done < "$file"
}

# guard_ledger_resume -- daemon-startup recovery. For every still-live ledger pid
# whose start-epoch still matches (recycle-safe via rg_proc_alive), send SIGCONT so
# an app SIGSTOP'd before the restart is un-frozen. Then clear the ledger entirely:
# any resumed pid is no longer paused and any non-matching line is stale/recycled,
# so nothing remains a live paused victim. This fixes the orphaned-frozen-app bug.
guard_ledger_resume() {
  local file uid pid start comm resumed=0
  file="$(guard_ledger_path)"
  [[ -f $file ]] || return 0
  uid="${RG_UID:-$EUID}"
  while IFS=$'\t' read -r pid start comm; do
    [[ -n $pid ]] || continue
    if rg_proc_alive "$pid" "$uid" "$start"; then
      # Flatten comm to one safe log token (basename, then newline/tab/space ->
      # '_'), matching breaker.bash::_guard_log_token without coupling to it.
      comm="${comm##*/}"
      comm="${comm//[$'\n\t ']/_}"
      # Honour DRY_RUN: `ram-guard test` / `--dry-run run` advertise "no signals
      # sent", so log a DRYRUN-CONT line instead of actually SIGCONT'ing.
      if ((${DRY_RUN:-0})); then
        guard_log action=DRYRUN-CONT event=ledger-resume pid="$pid" start="$start" comm="$comm"
      else
        "$RG_KILL" -CONT "$pid" 2> /dev/null || true
        guard_log action=RESUME event=ledger-resume pid="$pid" start="$start" comm="$comm"
      fi
      resumed=$((resumed + 1))
    fi
  done < "$file"
  : > "$file" 2> /dev/null || true
  ((resumed > 0)) && guard_log event=ledger-resume-done resumed="$resumed"
  return 0
}
