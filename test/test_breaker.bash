#!/usr/bin/env bash
# test_breaker.bash -- lib/guard/breaker.bash: the ACTING state machine, tested
# with a RECORDING fake `kill` (fixtures/bin/kill). The iron invariant of this
# file: NO test may send a real signal. Every assertion about "what would be
# signalled" reads the kill stub's log; a green run proves zero real signals.
#   * guard_severity thresholds
#   * guard_pick_target: biggest / fastest-grower selection, NO signalling
#   * guard_build_protect_set COVERS the guard's own basename + terminal/shell
#   * KILL_BUDGET caps kills per CRIT episode
#   * the pre-signal rg_proc_alive revalidation ABORTS on a recycled pid
set -uo pipefail
IFS=$' \t\n'
export LC_ALL=C
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.bash"

rg_test_begin test_breaker
rg_src config
rg_src sample
rg_src fmt
rg_src proc
rg_src_guard log
rg_src_guard ledger
rg_src_guard breaker

scratch="$(rg_test_scratch)"
trap 'rm -rf "$scratch"' EXIT

# Adapters -> stubs/fixtures. RG_KILL is the recording stub. NOTIFY=0 keeps the
# osascript adapter out of the picture entirely.
export RG_PS="$RG_FIX/bin/ps"
export RG_KILL="$RG_FIX/bin/kill"
export RG_OSASCRIPT="$RG_FIX/bin/osascript"
export FAKE_PS_DB="$RG_FIX/ps.txt"
export FAKE_KILL_LOG="$scratch/kill.log"
export RG_STATE="$scratch/state"
export LOG_FILE="$scratch/ramgate.log"
export RG_UID=502
: > "$FAKE_KILL_LOG"

rg_defaults # seed WARN_PCT/CRIT_PCT/MIN_RSS_MB/GROW_MIN_MB/...
NOTIFY=0
LABEL='com.milansantosi.ramgate'

# start-epoch token for the Chrome hog (pid 5001), via the SUT (not hand-mirrored).
_rg_lstart_to_epoch EP5001 Jul 2 16:58:11 2026

## --- guard_severity thresholds ---------------------------------------------
WARN_PCT=20 CRIT_PCT=10 WARN_PRESSURE=2 CRIT_PRESSURE=4
assert_eq 'NORMAL' "$(guard_severity 1 55)" 'severity NORMAL: low pressure, ample free'
assert_eq 'WARN' "$(guard_severity 2 55)" 'severity WARN via pressure level 2'
assert_eq 'WARN' "$(guard_severity 1 20)" 'severity WARN via free% at WARN_PCT'
assert_eq 'CRIT' "$(guard_severity 4 55)" 'severity CRIT via pressure level 4'
assert_eq 'CRIT' "$(guard_severity 1 10)" 'severity CRIT via free% at CRIT_PCT'
assert_eq 'NORMAL' "$(guard_severity 1 100)" 'severity NORMAL at 100% free'

## --- protect set covers SELF + terminal/shell ------------------------------
guard_build_protect_set 'ram-guard' "$LABEL" "$$"
assert_match '/Users/milan.santosi/projects/ramgate/bin/ram-guard' "$GUARD_PROTECT_RE" \
  'protect set covers the guard OWN binary (ram-guard) -- can never target itself'
assert_match '/Applications/Ghostty.app/Contents/MacOS/Ghostty' "$GUARD_PROTECT_RE" \
  'protect set covers the Ghostty terminal'
assert_match '/opt/homebrew/bin/tmux' "$GUARD_PROTECT_RE" 'protect set covers tmux'
assert_match '/bin/zsh' "$GUARD_PROTECT_RE" 'protect set covers the login shell'
assert_no_match '/usr/bin/somebigapp' "$GUARD_PROTECT_RE" \
  'an ordinary app is NOT protected (remains eligible)'

## --- guard_pick_target: biggest (size) -------------------------------------
# No growth history -> "kill the biggest" path. Must pick the Chrome hog (5001)
# and MUST skip every protected proc (WindowServer/ram-guard/Ghostty/tmux/zsh).
_guard_init_state
guard_build_protect_set 'ram-guard' "$LABEL" "$$"
guard_pick_target 0
assert_eq '5001' "$TARGET_PID" 'pick_target (size) selects the biggest non-protected hog'
assert_eq 'size' "$TARGET_REASON" 'pick_target reason=size when no growth seen'
assert_no_match "$TARGET_PID" '^(5003|5004|5005|5006|5007)$' \
  'pick_target NEVER selects a protected pid (self/WindowServer/terminal/shell)'
assert_file_empty "$FAKE_KILL_LOG" 'target SELECTION sends ZERO signals'

## --- guard_pick_target: fastest-grower -------------------------------------
# Seed pid 5002's previous RSS low so it registers a large delta this tick; it
# must win over the (bigger but static) Chrome hog. Growth beats size.
_guard_init_state
guard_build_protect_set 'ram-guard' "$LABEL" "$$"
GROW_MIN_MB=20
GUARD_PREV_RSS[5002]=1024 # 5002 jumps 1024KB -> 1048576KB this tick
guard_pick_target 0
assert_eq '5002' "$TARGET_PID" 'pick_target picks the FASTEST GROWER over the bigger static hog'
assert_match "$TARGET_REASON" '^growth' 'pick_target reason indicates growth'
assert_file_empty "$FAKE_KILL_LOG" 'grower selection still sends ZERO signals'

## --- KILL_BUDGET caps kills per episode ------------------------------------
# Budget 2: the third kill in an episode must be refused (BUDGET-EXHAUSTED) and
# send NO signal. Target 5001 with its REAL start-epoch so revalidation passes.
_guard_init_state
: > "$FAKE_KILL_LOG"
: > "$LOG_FILE"
DRY_RUN=0 KILL_BUDGET=2 CRIT_SIGNAL=KILL
_guard_kill 5001 502 "$EP5001" 4194304 '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' size
_guard_kill 5001 502 "$EP5001" 4194304 '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' size
_guard_kill 5001 502 "$EP5001" 4194304 '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' size
kills="$(grep -c . "$FAKE_KILL_LOG")"
assert_eq '2' "$kills" 'KILL_BUDGET=2 allows exactly 2 kills, refuses the 3rd'
assert_eq '-KILL 5001' "$(head -1 "$FAKE_KILL_LOG")" 'recorded signal is exactly -KILL <pid> (no real signal sent)'
assert_contains "$(< "$LOG_FILE")" 'action=BUDGET-EXHAUSTED' 'over-budget kill logged as BUDGET-EXHAUSTED'

## --- pre-signal rg_proc_alive revalidation ABORTS on a recycled pid ---------
# Same pid 5001, but a stale/wrong start-epoch (the number was recycled by a new
# process). The revalidation gate MUST abort BEFORE the kill adapter is touched.
_guard_init_state
: > "$FAKE_KILL_LOG"
: > "$LOG_FILE"
DRY_RUN=0 KILL_BUDGET=3 CRIT_SIGNAL=KILL
_guard_kill 5001 502 999999999 4194304 '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' size
assert_file_empty "$FAKE_KILL_LOG" 'recycled-pid kill sends ZERO real signals (aborted pre-signal)'
assert_contains "$(< "$LOG_FILE")" 'reason=pid-revalidate-failed' 'recycled-pid abort logged with pid-revalidate-failed'

## --- DRY_RUN never signals -------------------------------------------------
_guard_init_state
: > "$FAKE_KILL_LOG"
DRY_RUN=1 CRIT_SIGNAL=KILL
_guard_kill 5001 502 "$EP5001" 4194304 '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' size
assert_file_empty "$FAKE_KILL_LOG" 'DRY_RUN=1 logs intent but sends ZERO real signals'

rg_test_end
