# Changelog

Conventional Commits; SemVer. Regenerate with `just changelog` (git-cliff) once tags exist.

## [Unreleased]

### Added

- Developer harness: `prek` hooks — `shfmt` auto-format + re-stage, `shellcheck -x`, `bash -n`, `gitleaks` staged-secret scan, `rumdl`, Conventional-Commits `commit-msg`, branch-name `pre-push`.
- `commit-msg` hook (`scripts/hooks/commit-msg.bash`): de-slop → deterministic autofix → interactive nudge → optional local-first AI rewrite; timeout aborts, never a silent pass.
- Local-first AI engine (`scripts/hooks/lib/llm-run.bash` + `ai-task.bash`): mlx → ollama → llamacpp → gemini-nano → frontier, opt-in only.
- SemVer tooling: `VERSION` single source, `cliff.toml`, `scripts/release.bash` (bumps VERSION, syncs `RG_VERSION`, regenerates changelog).

## [0.1.0] - 2026-07-03

### Added

- Two-binary rewrite, pure GNU Bash ≥ 5.3.15, build-less: `bin/ram-xray` (inert introspection: summary/top/pid/app/why/watch) and `bin/ram-guard` (the only binary that pauses/kills under pressure).
- Library layout: `lib/` (config, fmt, proc, sample) shared + `lib/guard/` (agent, breaker, ledger, log) guard-only.
- Justfile + Makefile + `.just/` harness; "compile" is `bash -n`, lint is `shellcheck -x`.
- `docs/CONTRACT.md` — behavioural contract for both binaries.
