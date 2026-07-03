# Changelog

All notable changes to ramgate. Format follows [Keep a Changelog](https://keepachangelog.com/);
this project adheres to [Semantic Versioning](https://semver.org/). Regenerate the factual basis
with `just changelog` (git-cliff) once tags exist.

## [Unreleased]

### Added

- **Developer harness.** `prek` (Rust pre-commit) config with stock hygiene hooks plus local
  Bash-native hooks: `shfmt` auto-format + re-stage, `shellcheck -x`, `bash -n` syntax, `gitleaks`
  staged-secret scan, `rumdl` markdown lint, Conventional-Commits `commit-msg`, and conventional
  branch-name `pre-push`.
- **Intelligent Conventional-Commits `commit-msg` hook** (`scripts/hooks/commit-msg.bash`):
  de-slop -> deterministic autofix -> interactive nudge -> optional local-first AI rewrite, with a
  timeout that aborts (never a silent pass). AI is opt-in and degrades cleanly when unconfigured.
- **Local-first AI engine** (`scripts/hooks/lib/llm-run.bash` + `ai-task.bash`): mlx -> ollama ->
  llamacpp -> gemini-nano -> frontier harness, behind an explicit choice only.
- **SemVer tooling:** `VERSION` single source, `cliff.toml` for git-cliff, and
  `scripts/release.bash` (bumps VERSION, syncs `RG_VERSION` in both binaries, regenerates the
  changelog, prints the tag command).
- **Docs:** `CONTRIBUTING.md`, `SECURITY.md`, `docs/ARCHITECTURE.md`, `.editorconfig`.

## [0.1.0] - 2026-07-03

### Added

- **Two-binary rewrite of ramgate** (macOS memory x-ray + OOM guard), pure GNU Bash >= 5.3.15,
  build-less.
  - `bin/ram-xray` -- the INERT half: read-only RAM introspection (summary/top/pid/app/why/watch).
    Sends no signals, mutates no state, never sources anything under `lib/guard/`.
  - `bin/ram-guard` -- the ACTING half: the only binary that can pause or kill a process under
    memory pressure. Physical separation from ram-xray is the core safety invariant.
- Library layout: `lib/` (config, fmt, proc, sample) and `lib/guard/` (agent, breaker, ledger, log).
- Justfile + Makefile + `.just/` harness (splash, menu, fzf, doctor, bootstrap); build-less "compile"
  is `bash -n`, lint is `shellcheck -x`.
- `docs/CONTRACT.md` -- the behavioural contract for both binaries.
