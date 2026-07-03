#!/usr/bin/env bash
# test/lib.bash -- tiny pure-bash TAP-ish assertion library for ramgate.
# No bats, no external deps. Sourced by every test_*.bash. Each test file is run
# as its OWN bash process by run.bash, so the heavy global mutation the SUT does
# (RG_PG, GUARD_*, TARGET_*, config vars) can never bleed between test files.
#
# API:
#   rg_test_begin <name>
#   assert_eq       <expected> <actual> [desc]
#   assert_ne       <a> <b> [desc]
#   assert_match    <string> <ere> [desc]            # [[ str =~ ere ]]
#   assert_no_match <string> <ere> [desc]
#   assert_contains <haystack> <needle> [desc]       # substring
#   assert_not_contains <haystack> <needle> [desc]
#   assert_rc       <expected_rc> <actual_rc> [desc]
#   assert_true     <rc> [desc]                      # rc == 0
#   assert_false    <rc> [desc]                      # rc != 0
#   assert_file_empty  <path> [desc]
#   assert_file_missing <path> [desc]
#   rg_test_end                                      # prints summary, exits
if [ -z "${BASH_VERSINFO+set}" ]; then
  echo >&2 'error: test/lib.bash requires GNU bash'
  exit 78
fi
((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3))) || {
  printf >&2 'error: bash 5.3+ required (found %s)\n' "$BASH_VERSION"
  exit 78
}
set -uo pipefail
IFS=$' \t\n'
export LC_ALL=C

# Repo root = parent of test/. Exposed so tests can locate lib/ + bin/.
RG_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RG_REPO_ROOT="$(cd "$RG_TEST_DIR/.." && pwd)"
RG_LIB="$RG_REPO_ROOT/lib"
RG_BIN="$RG_REPO_ROOT/bin"
RG_FIX="$RG_TEST_DIR/fixtures"
export RG_TEST_DIR RG_REPO_ROOT RG_LIB RG_BIN RG_FIX

declare -gi RG_T_NUM=0 RG_T_PASS=0 RG_T_FAIL=0
declare -g RG_T_NAME=''

# rg_src <name> -- source a shared lib (config|sample|proc|fmt).
rg_src() { source "$RG_LIB/$1.bash"; }
# rg_src_guard <name> -- source a private guard lib (log|ledger|breaker|agent).
rg_src_guard() { source "$RG_LIB/guard/$1.bash"; }

rg_test_begin() {
  RG_T_NAME="${1:-$(basename "${BASH_SOURCE[1]:-test}")}"
  printf '# TEST FILE: %s\n' "$RG_T_NAME"
}

_rg_pass() {
  RG_T_NUM=$((RG_T_NUM + 1))
  RG_T_PASS=$((RG_T_PASS + 1))
  printf 'ok %d - %s\n' "$RG_T_NUM" "${1:-}"
}
_rg_fail() {
  RG_T_NUM=$((RG_T_NUM + 1))
  RG_T_FAIL=$((RG_T_FAIL + 1))
  printf 'not ok %d - %s\n' "$RG_T_NUM" "${1:-}"
  local d
  for d in "${@:2}"; do printf '#   %s\n' "$d"; done
}

assert_eq() {
  local exp="$1" act="$2" desc="${3:-eq}"
  if [[ $exp == "$act" ]]; then
    _rg_pass "$desc"
  else
    _rg_fail "$desc" "expected: [$exp]" "got:      [$act]"
  fi
}

assert_ne() {
  local a="$1" b="$2" desc="${3:-ne}"
  if [[ $a != "$b" ]]; then
    _rg_pass "$desc"
  else _rg_fail "$desc" "both were: [$a]"; fi
}

assert_match() {
  local str="$1" re="$2" desc="${3:-match}"
  if [[ $str =~ $re ]]; then
    _rg_pass "$desc"
  else _rg_fail "$desc" "string: [$str]" "regex:  [$re]"; fi
}

assert_no_match() {
  local str="$1" re="$2" desc="${3:-no-match}"
  if [[ ! $str =~ $re ]]; then
    _rg_pass "$desc"
  else _rg_fail "$desc" "string unexpectedly matched: [$str]" "regex: [$re]"; fi
}

assert_contains() {
  local hay="$1" needle="$2" desc="${3:-contains}"
  if [[ $hay == *"$needle"* ]]; then
    _rg_pass "$desc"
  else _rg_fail "$desc" "needle: [$needle]" "haystack: [$hay]"; fi
}

assert_not_contains() {
  local hay="$1" needle="$2" desc="${3:-not-contains}"
  if [[ $hay != *"$needle"* ]]; then
    _rg_pass "$desc"
  else _rg_fail "$desc" "unexpected needle present: [$needle]" "haystack: [$hay]"; fi
}

assert_rc() {
  local exp="$1" act="$2" desc="${3:-rc}"
  if [[ $exp == "$act" ]]; then
    _rg_pass "$desc"
  else _rg_fail "$desc" "expected rc: [$exp]" "got rc:      [$act]"; fi
}

assert_true() { assert_rc 0 "$1" "${2:-should succeed}"; }
assert_false() {
  local rc="$1" desc="${2:-should fail}"
  if [[ $rc != 0 ]]; then
    _rg_pass "$desc"
  else _rg_fail "$desc" "expected non-zero rc, got 0"; fi
}

assert_file_empty() {
  local f="$1" desc="${2:-file empty}"
  if [[ ! -s $f ]]; then
    _rg_pass "$desc"
  else _rg_fail "$desc" "file not empty: [$f]" "contents: [$(< "$f")]"; fi
}

assert_file_missing() {
  local f="$1" desc="${2:-file missing}"
  if [[ ! -e $f ]]; then
    _rg_pass "$desc"
  else _rg_fail "$desc" "file unexpectedly exists: [$f]"; fi
}

# Per-test scratch dir under ~/tmp (RULE: never /tmp). Auto-removed at end.
rg_test_scratch() {
  local base="${TMPDIR:-$HOME/tmp}"
  base="${base%/}"
  [[ -d $base ]] || base="$HOME/tmp"
  mkdir -p "$base"
  mktemp -d "$base/ramgate-test.XXXXXX"
}

rg_test_end() {
  printf '# SUMMARY %d %d\n' "$RG_T_PASS" "$RG_T_FAIL"
  ((RG_T_FAIL == 0)) || exit 1
  exit 0
}
