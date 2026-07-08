#!/usr/bin/env bash
# Secret + PII scanner shared by the hk pre-commit hook and CI (GitLab + GitHub).
#
# Usage: scan.bash [--staged] [--pii-only|--secrets-only]
#   --staged        scan only the staged diff / staged files (fast; pre-commit)
#   (default)       scan the whole tracked working tree (CI)
#   --pii-only      run only the PII (email) check, skip gitleaks
#   --secrets-only  run only gitleaks, skip the PII check
#
# Exit: 0 = clean, 1 = findings. Degrades to a no-op for any tool that is absent.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

mode=full
want=all
for arg in "$@"; do
  case "$arg" in
    --staged) mode=staged ;;
    --pii-only) want=pii ;;
    --secrets-only) want=secrets ;;
    *)
      printf 'scan: unknown arg %q\n' "$arg" >&2
      exit 2
      ;;
  esac
done

fail=0

# ── 1. Secrets (gitleaks) ────────────────────────────────────────────────────
# Always use `gitleaks dir` (filesystem scan): reliable and fast (~50ms here).
# `gitleaks git --staged` silently scans 0 bytes on git >= 2.55 (upstream bug),
# so it is NOT used -- a broken staged scan is worse than an honest full scan.
if [[ "$want" != pii ]]; then
  if command -v gitleaks > /dev/null 2>&1; then
    gitleaks dir . --redact --no-banner || fail=1
  else
    printf 'scan: gitleaks not found -- skipping secret scan\n' >&2
  fi
fi

# ── 2. PII: email addresses not on the allowlist ─────────────────────────────
# Allowlist covers placeholder / noreply / example addresses only.
if [[ "$want" != secrets ]]; then
  email='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
  allow='\.invalid|example\.(com|org|net)|users\.noreply\.github\.com|@ramgate\.'

  if [[ "$mode" == staged ]]; then
    mapfile -t files < <(git diff --cached --name-only --diff-filter=ACM)
  else
    mapfile -t files < <(git ls-files)
  fi

  if ((${#files[@]})); then
    if hits=$(grep -InE "$email" -- "${files[@]}" 2> /dev/null | grep -vE "$allow"); then
      printf 'scan: possible PII (email) detected -- remove or allowlist:\n%s\n' "$hits" >&2
      fail=1
    fi
  fi
fi

if ((fail)); then
  printf 'scan: FAILED (secrets or PII found)\n' >&2
  exit 1
fi
printf 'scan: clean (no secrets or PII)\n'
