#!/usr/bin/env bash
# test_proc.bash -- lib/proc.bash: rg_ps_snapshot TSV shape, the rg_proc_alive
# anti-recycle gate (pass / wrong-start / dead pid), rg_footprint, and the subtle
# rg_dominant_region field-from-the-right RESIDENT extraction. Every ps/vmmap call
# is mocked; no real process is inspected and nothing is signalled.
set -uo pipefail
IFS=$' \t\n'
export LC_ALL=C
# shellcheck source=SCRIPTDIR/lib.bash
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.bash"

rg_test_begin test_proc
rg_src config
rg_src sample
rg_src fmt
rg_src proc

export RG_PS="$RG_FIX/bin/ps"
export RG_VMMAP="$RG_FIX/bin/vmmap"
export FAKE_PS_DB="$RG_FIX/ps.txt"

## --- rg_ps_snapshot TSV shape ----------------------------------------------
# Emits pid<TAB>rss_kb<TAB>uid<TAB>start_epoch<TAB>comm. Verify exactly 5 tab
# fields, a numeric start-epoch token, and that a comm containing spaces survives.
snap="$(rg_ps_snapshot)"
first="$(printf '%s\n' "$snap" | head -1)"
IFS=$'\t' read -r s_pid s_rss s_uid s_epoch s_comm <<< "$first"
assert_eq '5001' "$s_pid" 'snapshot row 1 pid'
assert_eq '4194304' "$s_rss" 'snapshot row 1 rss_kb'
assert_eq '502' "$s_uid" 'snapshot row 1 uid'
assert_match "$s_epoch" '^[0-9]+$' 'snapshot start_epoch is a numeric token'
assert_eq '1783011491' "$s_epoch" 'snapshot start_epoch = civil-date token for Jul 2 16:58:11 2026'
assert_contains "$s_comm" 'Google Chrome Helper (Renderer)' 'snapshot comm keeps embedded spaces'
# Field count: split first row on TAB and count.
IFS=$'\t' read -ra fields <<< "$first"
assert_eq '5' "${#fields[@]}" 'snapshot row has exactly 5 TAB fields'
# All 8 fixture rows survive (only comment lines dropped).
assert_eq '8' "$(printf '%s\n' "$snap" | grep -c .)" 'snapshot emits one row per fixture process'

## --- rg_proc_alive: the anti-PID-recycle gate ------------------------------
# 5001's true start-epoch token is 1783011491 (computed above). Compute it via the
# SUT itself so the "pass" case is not hand-mirrored.
_rg_lstart_to_epoch epoch_5001 Jul 2 16:58:11 2026
# shellcheck disable=SC2154  # epoch_5001 assigned via nameref out-param above
rg_proc_alive 5001 502 "$epoch_5001"
assert_true $? 'proc_alive PASSES on pid+uid+start match'

# Recycled pid: same pid + uid, but a DIFFERENT start-epoch (a new process reused
# the number). MUST be rejected -- this is the core safety gate before any signal.
rg_proc_alive 5001 502 999999999
assert_false $? 'proc_alive REJECTS wrong start-epoch (recycled pid)'

# Wrong uid (someone else's process with the same pid) -> reject (same-user-only).
rg_proc_alive 5001 777 "$epoch_5001"
assert_false $? 'proc_alive REJECTS uid mismatch'

# Dead pid: not in the roster at all -> ps returns nothing, exit 1 -> reject.
rg_proc_alive 9999 502 "$epoch_5001"
assert_false $? 'proc_alive REJECTS dead pid'

## --- rg_footprint: exact phys_footprint via vmmap --summary -----------------
# fixtures/vmmap_summary.txt reports "Physical footprint: 1.5G" (and a "(peak)"
# line that MUST be ignored). 1.5G = 1610612736 bytes.
assert_eq '1610612736' "$(rg_footprint 5002)" 'rg_footprint reads Physical footprint (skips peak)'

## --- rg_dominant_region: field-from-the-right RESIDENT extraction -----------
# The vmmap region table is NOT pre-sorted and region names contain spaces, so
# RESIDENT is located relative to the rightmost pure-integer (REGION COUNT). The
# heaviest region in the fixture is VM_ALLOCATE @ 900M resident = 943718400 bytes.
RG_GAWK="$(command -v gawk)"
export RG_GAWK
dom="$(rg_dominant_region 5002)"
assert_eq $'VM_ALLOCATE\t943718400' "$dom" 'rg_dominant_region picks heaviest region, resident in bytes'

# No gawk -> graceful empty (degrade path; region drill-downs are optional).
assert_eq '' "$(RG_GAWK='' rg_dominant_region 5002)" 'rg_dominant_region degrades to empty without gawk'

rg_test_end
