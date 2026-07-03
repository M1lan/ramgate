#!/usr/bin/env bash
# install-hooks.bash -- LOCAL git-hook installer for ramgate (developer machine only).
#
# Verifies `prek` (the Rust pre-commit) is on PATH, offers to `brew install` it if not,
# makes the hook scripts executable, and runs `prek install` for all three stages
# (pre-commit, commit-msg, pre-push). Never touches anything outside this repo; never
# uses sudo. Safe and idempotent to re-run.
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

# --- 1. ensure prek is available --------------------------------------------
if ! command -v prek > /dev/null 2>&1; then
  log "prek not found on PATH."
  log "prek is the Rust pre-commit runner. Install options:"
  log "  brew install prek        (Homebrew)"
  log "  cargo install prek       (Rust toolchain)"
  if command -v brew > /dev/null 2>&1 && [[ -t 0 ]]; then
    read -r -p "[install-hooks] run 'brew install prek' now? [y/N]: " ans
    if [[ "${ans:-n}" == [yY] ]]; then
      brew install prek || {
        log "brew install prek failed -- install it manually and re-run."
        exit 1
      }
    else
      log "skipped -- install prek manually and re-run."
      exit 1
    fi
  else
    log "install prek and re-run this script."
    exit 1
  fi
fi
log "prek: $(command -v prek) ($(prek --version 2> /dev/null || echo '?'))"

# --- 2. make the hook scripts executable ------------------------------------
count=0
while IFS= read -r -d '' f; do
  chmod +x "$f" && count=$((count + 1))
done < <(fd -0 -t f -e bash . scripts/hooks 2> /dev/null || find scripts/hooks -type f -name '*.bash' -print0)
chmod +x scripts/install-hooks.bash 2> /dev/null || true
log "made $count hook script(s) executable"

# --- 3. install all three stages --------------------------------------------
log "installing prek hooks (pre-commit, commit-msg, pre-push)..."
if prek install --install-hooks -t pre-commit -t commit-msg -t pre-push; then
  log "OK -- hooks installed. Sweep everything with:  just hooks"
  log "Optional AI-assist for commit rewrites:  just hooks-ai-setup"
else
  log "prek install failed -- check '.pre-commit-config.yaml' with: prek validate-config"
  exit 1
fi
