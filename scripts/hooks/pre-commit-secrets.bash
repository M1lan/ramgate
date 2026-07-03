#!/usr/bin/env bash
# pre-commit secret scan -- a SAFETY hook: it blocks the commit when a secret is
# found in the staged diff (exit non-zero). No prompts, no auto-fix: leaked
# credentials must be removed by a human. Degrades to a no-op if gitleaks absent.
set -uo pipefail

HOOK_NAME="secrets"
# shellcheck source=scripts/hooks/lib/hooklib.bash
source "$(git rev-parse --show-toplevel)/scripts/hooks/lib/hooklib.bash"
hook::load_config

if ! command -v gitleaks > /dev/null 2>&1; then
  hook::warn "gitleaks not installed -- skipping secret scan (install: brew install gitleaks)"
  exit 0
fi

# gitleaks 8.19+ : `git --staged`; older builds expose `protect --staged`.
if gitleaks git --help > /dev/null 2>&1; then
  scan=(gitleaks git --staged --redact --no-banner)
else
  scan=(gitleaks protect --staged --redact --no-banner)
fi

if "${scan[@]}"; then
  exit 0
fi

hook::warn "potential secret detected in the staged diff (above) -- commit blocked"
hook::say "remove the secret (or add a reviewed allowlist entry) and re-stage"
exit 1
