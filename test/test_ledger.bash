#!/usr/bin/env bash
# test_ledger.bash -- lib/guard/ledger.bash: the restart-safe pause ledger.
#   * guard_ledger_add / guard_ledger_remove / guard_ledger_count (with dedup)
#   * guard_ledger_resume: on startup, SIGCONT (via the recording kill stub) ONLY
#     still-live, start-epoch-matching pids -- skipping recycled + dead pids --
#     then truncate the ledger. This is the "no app left frozen across a restart"
#     invariant. Zero real signals: assertions read the kill stub's log.
set -uo pipefail
IFS=$' \t\n'
export LC_ALL=C
# shellcheck source=SCRIPTDIR/lib.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.bash"

rg_test_begin test_ledger
rg_src config
rg_src sample
rg_src fmt
rg_src proc
rg_src_guard log
rg_src_guard ledger

scratch="$(rg_test_scratch)"
trap 'rm -rf "$scratch"' EXIT

export RG_PS="$RG_FIX/bin/ps"
export RG_KILL="$RG_FIX/bin/kill"
export FAKE_PS_DB="$RG_FIX/ps.txt"
export FAKE_KILL_LOG="$scratch/kill.log"
export RG_STATE="$scratch/state"
export LOG_FILE="$scratch/ramgate.log"
export RG_UID=502
rg_defaults
: > "$FAKE_KILL_LOG"

ledger="$(guard_ledger_path)"

## --- add / count / dedup / remove ------------------------------------------
assert_eq '0' "$(guard_ledger_count)" 'empty ledger counts 0'
guard_ledger_add 5001 1783011491 '/Applications/Chrome'
guard_ledger_add 5002 1783069200 '/usr/bin/somebigapp'
assert_eq '2' "$(guard_ledger_count)" 'two adds -> count 2'
guard_ledger_add 5001 1783011491 '/Applications/Chrome' # duplicate pid
assert_eq '2' "$(guard_ledger_count)" 'adding an existing pid de-duplicates (still 2)'
guard_ledger_remove 5001
assert_eq '1' "$(guard_ledger_count)" 'remove drops exactly one pid'
guard_ledger_remove 4242 # not present
assert_eq '1' "$(guard_ledger_count)" 'removing an absent pid is a no-op'

## --- guard_ledger_resume: recycle-safe startup un-pause --------------------
# Build a ledger with three victims:
#   5001 -> live AND start-epoch matches   => MUST be SIGCONT'd
#   5002 -> live pid but WRONG start-epoch => recycled, MUST be skipped
#   9999 -> not in the roster at all       => dead,     MUST be skipped
_rg_lstart_to_epoch EP5001 Jul 2 16:58:11 2026 # 5001's true token
_rg_lstart_to_epoch EP5002 Jul 3 09:00:00 2026 # 5002's true token
wrong_5002=$((EP5002 + 12345))                 # a stale/recycled token

: > "$FAKE_KILL_LOG"
{
  printf '%s\t%s\t%s\n' 5001 "$EP5001" '/Applications/Chrome'
  printf '%s\t%s\t%s\n' 5002 "$wrong_5002" '/usr/bin/somebigapp'
  printf '%s\t%s\t%s\n' 9999 1783000000 '/usr/bin/ghost'
} > "$ledger"
assert_eq '3' "$(guard_ledger_count)" 'ledger seeded with 3 victims'

guard_ledger_resume

# Only the live+matching pid is CONT'd -- exactly one signal, and it is 5001.
assert_eq '1' "$(grep -c . "$FAKE_KILL_LOG")" 'resume SIGCONTs exactly ONE pid'
assert_eq '-CONT 5001' "$(head -1 "$FAKE_KILL_LOG")" 'resume CONTs the live start-matching pid (5001) only'
assert_not_contains "$(< "$FAKE_KILL_LOG")" '5002' 'recycled pid (wrong start-epoch) is NOT resumed'
assert_not_contains "$(< "$FAKE_KILL_LOG")" '9999' 'dead pid is NOT resumed'

# ...and the ledger is truncated afterwards (nothing remains a live paused victim).
assert_file_empty "$ledger" 'ledger is truncated after resume'
assert_eq '0' "$(guard_ledger_count)" 'ledger count is 0 after resume'
assert_contains "$(< "$LOG_FILE")" 'action=RESUME' 'resume of the live pid is logged'

rg_test_end
