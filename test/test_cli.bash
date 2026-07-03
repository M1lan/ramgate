#!/usr/bin/env bash
# test_cli.bash -- both binaries end to end, with EVERY host adapter pointed at a
# stub/fixture so no real vm_stat/ps/kill/launchctl is ever invoked:
#   * --version / --help for both bins
#   * unknown command -> exit 2 (GNU usage-error convention, per contract)
#   * `ram-guard once` is DRY_RUN-forced: even under forced-CRIT fixtures it logs
#     intent and sends ZERO real signals (kill stub log stays empty)
#   * the INERT invariant: ram-xray contains NO signal-sending code and never
#     sources lib/guard/*
set -uo pipefail
IFS=$' \t\n'
export LC_ALL=C
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.bash"

rg_test_begin test_cli
BASH_BIN='/opt/homebrew/bin/bash'

scratch="$(rg_test_scratch)"
trap 'rm -rf "$scratch"' EXIT

## --- ram-xray: version / help / unknown ------------------------------------
out="$("$BASH_BIN" "$RG_BIN/ram-xray" --version)"
rc=$?
assert_eq 'ram-xray (ramgate) 0.1.0' "$out" 'ram-xray --version prints name + version'
assert_rc 0 "$rc" 'ram-xray --version exits 0'

out="$("$BASH_BIN" "$RG_BIN/ram-xray" --help)"
rc=$?
assert_rc 0 "$rc" 'ram-xray --help exits 0'
assert_contains "$out" 'Usage: ram-xray' 'ram-xray --help shows usage'
assert_contains "$out" 'sends NO signals' 'ram-xray --help advertises its read-only nature'

"$BASH_BIN" "$RG_BIN/ram-xray" bogus-cmd > /dev/null 2>&1
rc=$?
assert_rc 2 "$rc" 'ram-xray unknown command exits 2 (usage error)'

## --- ram-guard: version / help / unknown -----------------------------------
# All adapters stubbed so even top-level guard_build_protect_set uses the fake ps.
guard_env=(
  "RG_PS=$RG_FIX/bin/ps" "RG_KILL=$RG_FIX/bin/kill"
  "RG_OSASCRIPT=$RG_FIX/bin/osascript" "RG_VMMAP=$RG_FIX/bin/vmmap"
  "RG_SYSCTL=$RG_FIX/bin/sysctl" "RG_LAUNCHCTL=$RG_FIX/bin/osascript"
  "RG_VMSTAT=$RG_FIX/bin/osascript"
  "FAKE_PS_DB=$RG_FIX/ps.txt" "RG_FIX=$RG_FIX"
  "RG_CONF=$scratch/none.conf" "RG_UID=502" "NOTIFY=0"
)

out="$(env "${guard_env[@]}" "$BASH_BIN" "$RG_BIN/ram-guard" --version)"
rc=$?
assert_eq 'ram-guard (ramgate) 0.1.0' "$out" 'ram-guard --version prints name + version'
assert_rc 0 "$rc" 'ram-guard --version exits 0'

out="$(env "${guard_env[@]}" "$BASH_BIN" "$RG_BIN/ram-guard" --help)"
rc=$?
assert_rc 0 "$rc" 'ram-guard --help exits 0'
assert_contains "$out" 'Usage: ram-guard' 'ram-guard --help shows usage'

env "${guard_env[@]}" "$BASH_BIN" "$RG_BIN/ram-guard" bogus-cmd > /dev/null 2>&1
rc=$?
assert_rc 2 "$rc" 'ram-guard unknown command exits 2 (usage error)'

## --- ram-guard once is DRY_RUN-forced (no signals, ever) --------------------
# Force a CRIT reading via sysctl fixtures so the tick actually reaches the kill
# decision -- then prove DRY_RUN blocks it: the kill stub log MUST stay empty.
sysdir="$scratch/sysctl"
mkdir -p "$sysdir"
printf '4\n' > "$sysdir/kern.memorystatus_vm_pressure_level.txt" # CRIT pressure
printf '0\n' > "$sysdir/kern.memorystatus_level.txt"             # 0% free
printf '17179869184\n' > "$sysdir/hw.memsize.txt"
printf 'total = 4096.00M  used = 4096.00M\n' > "$sysdir/vm.swapusage.txt"
killlog="$scratch/once-kill.log"
: > "$killlog"
guardlog="$scratch/once.log"

once_env=(
  "${guard_env[@]}"
  "FAKE_SYSCTL_DIR=$sysdir" "FAKE_KILL_LOG=$killlog"
  "RG_STATE=$scratch/state" "LOG_FILE=$guardlog"
)
env "${once_env[@]}" "$BASH_BIN" "$RG_BIN/ram-guard" once > /dev/null 2>&1
rc=$?
assert_rc 0 "$rc" 'ram-guard once exits 0'
assert_file_empty "$killlog" 'ram-guard once sends ZERO real signals (DRY_RUN forced)'
assert_contains "$(< "$guardlog")" 'DRYRUN' 'once logs a DRYRUN action, proving it reached-but-blocked the kill'

## --- INERT invariant: ram-xray is provably signal-free ---------------------
# Contract §0: ram-xray contains ZERO signal-sending code and never sources guard.
# NB: the contract's literal `rg 'RG_KILL|kill '` over-matches the file's own
# header PROSE ("... pause or kill a process ..."), so we assert against CODE
# lines only (full-line comments stripped) -- same invariant, no false positive.
inert="$(rg -v '^[[:space:]]*#' "$RG_BIN/ram-xray" | rg -n 'RG_KILL|\bkill\b' || true)"
assert_eq '' "$inert" 'ram-xray contains NO signal-sending code (no RG_KILL / kill in code)'
# And RG_KILL -- the ONLY signal mechanism in the codebase -- appears nowhere at
# all in ram-xray, not even in a comment.
inert_all="$(rg -nw 'RG_KILL' "$RG_BIN/ram-xray" || true)"
assert_eq '' "$inert_all" 'ram-xray never references the RG_KILL signal adapter (anywhere)'
guardsrc="$(rg -n '^[[:space:]]*source.*guard/' "$RG_BIN/ram-xray" || true)"
assert_eq '' "$guardsrc" 'ram-xray never sources lib/guard/*'
# Positive control: the ACTING binary DOES load the guard modules (wall is one-sided).
guardsrc_guard="$(rg -n 'guard/\$_m' "$RG_BIN/ram-guard" || true)"
assert_ne '' "$guardsrc_guard" 'ram-guard DOES source the guard modules (control)'

rg_test_end
