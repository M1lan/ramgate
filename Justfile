# ── ramgate Justfile -- macOS memory x-ray + OOM guard (two-binary, build-less) ─
# Build system: NONE. ramgate is pure GNU Bash >= 5.3.15, macOS-only. There is
# no compiler: the "compile" is `bash -n` on every file (just check) followed by
# shellcheck (just lint). Facts on the splash are counts of bin/*, lib/**.bash,
# and test files -- never a build tool. TUI/logic lives in .just/helpers/ (pure
# GNU Bash 5.3+, see lib.bash). Do not put large bash blobs here.
#
# Start here: a bare `just` shows the splash (enter/m -> menu, f -> fzf).
# Zero-to-ready from a clean checkout: `make`.   Full CI gate: `just ci`.
set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := false
set positional-arguments := true

helpers := justfile_directory() / ".just" / "helpers"

alias m := menu
alias f := fzf
alias t := test

# bare `just`: full-width splash + countdown (enter/m menu · f fzf · timeout shell)
[private]
[no-exit-message]
default:
    @'{{helpers}}/info-screen.bash'

# ── Umbrella ─────────────────────────────────────────────────────────────────

# The exact gate: syntax check + shellcheck + tests (bundled via deps).
[group('umbrella')]
ci: check lint test

# Full local QA: format, then the CI gate (check + lint + test).
[group('umbrella')]
qa: fmt check lint test

# Everything: dependency audit, then the full QA sweep.
[group('umbrella')]
all: doctor qa

# ── Meta ─────────────────────────────────────────────────────────────────────

# Show available recipes.
[group('meta')]
help:
    @just --list --unsorted

# Static info splash: project facts, inventory, toolbelt (no countdown).
[group('meta')]
info:
    @'{{helpers}}/info-screen.bash' --static

# Guided gum launcher: pick a recipe, fill its params as a form (no fzf).
[group('meta')]
[no-exit-message]
menu:
    @'{{helpers}}/menu.bash'

# fzf power launcher: dense list, live preview, tab multi-select batch.
[group('meta')]
[no-exit-message]
fzf:
    @'{{helpers}}/fzf.bash'

# Audit harness + project dependencies (exits non-zero if required missing).
[group('meta')]
doctor:
    @'{{helpers}}/doctor.bash'

# Interactively install missing dependencies via Homebrew.
[group('meta')]
[no-exit-message]
doctor-install:
    @'{{helpers}}/doctor.bash' --install

# Full project bootstrap with live install splash (same as plain `make`).
[group('meta')]
[no-exit-message]
bootstrap:
    @'{{helpers}}/bootstrap.bash'

# ── Build (build-less: format + the bash -n "compile") ───────────────────────

# Format every shell file in place (shfmt: 2-space, switch indent, redir spacing).
[group('build')]
fmt:
    shfmt -w -i 2 -ci -sr bin/* lib/*.bash lib/guard/*.bash .just/helpers/*.bash

# The build-less "compile": bash -n on every bin, lib, and helper.
[group('build')]
check:
    @set -euo pipefail; \
     bad=0; \
     for f in bin/* lib/*.bash lib/guard/*.bash .just/helpers/*.bash; do \
       [[ -f "$f" ]] || continue; \
       if bash -n "$f"; then printf '  ok   %s\n' "$f"; else bad=1; fi; \
     done; \
     if compgen -G 'test/*.bash' >/dev/null 2>&1; then \
       for f in test/*.bash; do if bash -n "$f"; then printf '  ok   %s\n' "$f"; else bad=1; fi; done; \
     fi; \
     if (( bad )); then printf 'check: syntax errors above\n' >&2; exit 1; fi; \
     printf 'check: all files parse (bash -n)\n'

# ── Run ──────────────────────────────────────────────────────────────────────

# Run the read-only introspector (summary|top|pid|app|why|watch|doctor).
[group('run')]
[no-exit-message]
run-xray *args:
    @bin/ram-xray "$@"

# Run the pressure watchdog (run|status|once|test|install|uninstall|log|doctor).
[group('run')]
[no-exit-message]
run-guard *args:
    @bin/ram-guard "$@"

# ── Test ─────────────────────────────────────────────────────────────────────

# Run the pure-bash test harness (test/run.bash, else each test/*.bash).
[group('test')]
test:
    @set -euo pipefail; \
     if [[ -x test/run.bash ]]; then exec test/run.bash; fi; \
     shopt -s nullglob; files=(test/*.bash); \
     if (( ${#files[@]} == 0 )); then \
       printf 'no test harness yet -- add test/*.bash (see docs/CONTRACT.md §17)\n' >&2; exit 0; \
     fi; \
     fail=0; \
     for f in "${files[@]}"; do printf '%s▸ %s%s\n' "$(tput bold 2>/dev/null||true)" "$f" "$(tput sgr0 2>/dev/null||true)"; bash "$f" || fail=1; done; \
     exit "$fail"

# ── Lint ─────────────────────────────────────────────────────────────────────

# Static-check all shell (shellcheck -x; helpers at -S warning). Skipped if absent.
[group('lint')]
lint:
    @if ! command -v shellcheck >/dev/null 2>&1; then printf 'shellcheck not installed -- skipping\n' >&2; exit 0; fi; \
     shellcheck -x bin/* lib/*.bash lib/guard/*.bash; \
     if compgen -G 'test/*.bash' >/dev/null 2>&1; then shellcheck -x test/*.bash; fi; \
     shellcheck -x -S warning -P .just/helpers .just/helpers/*.bash

# ── Setup (LOCAL to $HOME -- never root, never sudo) ─────────────────────────

# Symlink bin/ram-xray + bin/ram-guard into ~/.local/bin (no root, no sudo).
[group('setup')]
install:
    @set -euo pipefail; \
     dest="$HOME/.local/bin"; mkdir -p "$dest"; \
     for b in ram-xray ram-guard; do \
       src="{{justfile_directory()}}/bin/$b"; \
       [[ -f "$src" ]] || { printf 'missing %s\n' "$src" >&2; exit 1; }; \
       ln -sf "$src" "$dest/$b"; \
       printf 'linked %s -> %s\n' "$dest/$b" "$src"; \
     done; \
     case ":$PATH:" in *":$dest:"*) : ;; *) printf 'note: %s is not on PATH -- add it to use the commands\n' "$dest" >&2 ;; esac

# Remove the ~/.local/bin symlinks created by `just install`.
[group('setup')]
uninstall:
    @set -euo pipefail; \
     dest="$HOME/.local/bin"; \
     for b in ram-xray ram-guard; do \
       if [[ -L "$dest/$b" ]]; then rm -f "$dest/$b"; printf 'removed %s\n' "$dest/$b"; \
       else printf 'skip %s (not a symlink)\n' "$dest/$b"; fi; \
     done

# ── Clean ────────────────────────────────────────────────────────────────────

# Remove harness runtime state (.just/state: bootstrap log/steps/stats).
[group('clean')]
clean:
    rm -rf .just/state

# ── Git ──────────────────────────────────────────────────────────────────────

# Working-tree status, short + branch header.
[group('git')]
git-status:
    @git status --short --branch

# Recent history as a decorated graph (last 20).
[group('git')]
git-log:
    @git log --oneline --graph --decorate -20

# Diffstat of the working tree against HEAD.
[group('git')]
git-diff:
    @git diff --stat

# ── Git hooks (prek harness · LOCAL) ─────────────────────────────────────────

# Install the prek git hooks for all 3 stages (pre-commit, commit-msg, pre-push).
[group('git')]
[no-exit-message]
hooks-install:
    @bash scripts/install-hooks.bash

# Run every prek hook against all files (full sweep).
[group('git')]
[no-exit-message]
hooks:
    @if command -v prek >/dev/null 2>&1; then prek run --all-files; \
     else printf 'prek not installed -- run: just hooks-install\n' >&2; exit 1; fi

# Seed config/hooks/ai.env from the sample for the optional local-first AI assist.
[group('git')]
[no-exit-message]
hooks-ai-setup:
    @set -euo pipefail; \
     dst=config/hooks/ai.env; \
     if [[ -f "$dst" ]]; then printf '%s already exists -- edit it to configure the AI backend\n' "$dst"; \
     else cp config/hooks/ai.env.sample "$dst"; printf 'wrote %s -- edit HOOKS_AI_CMD/HOOKS_AI_BACKEND to enable AI assist (local-first, opt-in)\n' "$dst"; fi; \
     printf 'AI never fires on its own; it is only offered behind the commit-msg [a] choice.\n'

# Commit staged changes through the intelligent Conventional-Commits commit-msg flow.
[group('git')]
[no-exit-message]
commit *args:
    @git commit "$@"

# ── Release (SemVer · git-cliff) ─────────────────────────────────────────────

# Regenerate CHANGELOG.md from Conventional Commits via git-cliff.
[group('release')]
[no-exit-message]
changelog:
    @if command -v git-cliff >/dev/null 2>&1; then git-cliff -o CHANGELOG.md && printf 'regenerated CHANGELOG.md\n'; \
     else printf 'git-cliff not installed (brew install git-cliff) -- use: bash scripts/release.bash <part>\n' >&2; exit 1; fi

# Cut a release: bump VERSION (major|minor|patch), sync binaries, regen CHANGELOG.
[group('release')]
[no-exit-message]
release part:
    @bash scripts/release.bash "{{part}}"

# ── Utilities ────────────────────────────────────────────────────────────────

# Count lines of shell across bin/ + lib/ (tokei/scc if present, else wc).
[group('util')]
loc:
    @if command -v tokei >/dev/null 2>&1; then tokei bin lib; \
     elif command -v scc >/dev/null 2>&1; then scc bin lib; \
     else fd -t f . bin lib -X wc -l | tail -1; fi
