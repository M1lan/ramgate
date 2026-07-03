#!/usr/bin/env bash
# test/run.bash -- ramgate test runner. Executes every test/test_*.bash in its
# OWN bash process (isolation: the SUT mutates many globals -- RG_PG, GUARD_*,
# TARGET_*, config vars -- so per-file subprocesses prevent cross-file bleed),
# streams each file's TAP-ish output, aggregates pass/fail from the per-file
# `# SUMMARY <pass> <fail>` line, prints a grand total, and exits non-zero if
# any assertion in any file failed. This is what `just test` calls.
set -uo pipefail
IFS=$' \t\n'
export LC_ALL=C

((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3))) || {
  printf >&2 'error: bash 5.3+ required (found %s)\n' "$BASH_VERSION"
  exit 78
}

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASH_BIN="${BASH:-/opt/homebrew/bin/bash}"
[[ -x $BASH_BIN ]] || BASH_BIN="$(command -v bash)"

# Collect test files (sorted, deterministic order).
declare -a files=()
for f in "$TEST_DIR"/test_*.bash; do
  [[ -e $f ]] || continue
  files+=("$f")
done
((${#files[@]} > 0)) || {
  printf >&2 'run.bash: no test_*.bash files found in %s\n' "$TEST_DIR"
  exit 1
}

declare -i total_pass=0 total_fail=0 files_failed=0
declare -a failed_files=()
sep='--------------------------------------------------------------------------'

for f in "${files[@]}"; do
  name="${f##*/}"
  printf '%s\n== %s\n' "$sep" "$name"
  # Run the file; capture output so we can parse its summary while still showing it.
  out="$("$BASH_BIN" "$f" 2>&1)"
  rc=$?
  printf '%s\n' "$out"

  # Parse the machine-readable summary line the file emits at the end.
  summary="$(printf '%s\n' "$out" | rg '^# SUMMARY ' | tail -1)"
  if [[ $summary =~ ^\#\ SUMMARY\ ([0-9]+)\ ([0-9]+)$ ]]; then
    total_pass=$((total_pass + BASH_REMATCH[1]))
    total_fail=$((total_fail + BASH_REMATCH[2]))
  else
    # No summary => the file crashed before finishing. Count as a failure.
    printf '   (no SUMMARY emitted -- file aborted)\n'
    total_fail=$((total_fail + 1))
  fi

  if ((rc != 0)); then
    files_failed=$((files_failed + 1))
    failed_files+=("$name")
  fi
done

printf '%s\n' "$sep"
printf 'RESULT: %d passed, %d failed  (across %d files)\n' \
  "$total_pass" "$total_fail" "${#files[@]}"
if ((files_failed > 0)); then
  printf 'FAILED FILES: %s\n' "${failed_files[*]}"
  exit 1
fi
printf 'ALL GREEN\n'
exit 0
