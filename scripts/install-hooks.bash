#!/usr/bin/env bash
# install-hooks.bash -- LOCAL git-hook installer for ramgate (developer machine only).
#
# Verifies `hk` (the pkl-based hook runner) is on PATH, offers to `brew install` it if
# not, makes the hook scripts executable, and runs `hk install` (which wires up every
# stage declared in hk.pkl: pre-commit, commit-msg, pre-push). Never touches anything
# outside this repo; never uses sudo. Safe and idempotent to re-run.
#
# Usage:  bash scripts/install-hooks.bash        (or: just hooks-install)
set -uo pipefail
trap 'exit 130' INT TERM HUP

if [ -z "${BASH_VERSINFO+set}" ] || ((BASH_VERSINFO[0] < 5)); then
  printf 'error: install-hooks requires GNU bash >= 5\n' >&2
  exit 1
fi

repo_root="$(git rev-parse --show-toplevel 2> /dev/null)" || {
  printf 'error: not inside a git repository\n' >&2
  exit 1
}
cd "$repo_root" || exit 1

log() { printf '[install-hooks] %s\n' "$*"; }

# --- 1. ensure hk is available ----------------------------------------------
if ! command -v hk > /dev/null 2>&1; then
  log "hk not found on PATH."
  log "hk is the pkl-based git-hook runner. Install options:"
  log "  brew install hk          (Homebrew)"
  log "  cargo install hk         (Rust toolchain)"
  if command -v brew > /dev/null 2>&1 && [[ -t 0 ]]; then
    read -r -p "[install-hooks] run 'brew install hk' now? [y/N]: " ans
    if [[ "${ans:-n}" == [yY] ]]; then
      brew install hk || {
        log "brew install hk failed -- install it manually and re-run."
        exit 1
      }
    else
      log "skipped -- install hk manually and re-run."
      exit 1
    fi
  else
    log "install hk and re-run this script."
    exit 1
  fi
fi
log "hk: $(command -v hk) ($(hk version 2> /dev/null || echo '?'))"

# --- 2. make the hook scripts executable ------------------------------------
count=0
while IFS= read -r -d '' f; do
  chmod +x "$f" && count=$((count + 1))
done < <(fd -0 -t f -e bash . scripts/hooks 2> /dev/null || find scripts/hooks -type f -name '*.bash' -print0)
chmod +x scripts/install-hooks.bash 2> /dev/null || true
log "made $count hook script(s) executable"

# --- 3. install the git hooks (all stages declared in hk.pkl) ----------------
log "installing hk hooks (pre-commit, commit-msg, pre-push)..."
if hk install; then
  log "OK -- hooks installed. Sweep everything with:  just hooks"
  log "Optional AI-assist for commit rewrites:  just hooks-ai-setup"
else
  log "hk install failed -- check 'hk.pkl' with: hk validate"
  exit 1
fi
