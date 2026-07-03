# Contributing to ramgate

ramgate is pure **GNU Bash >= 5.3.15**, macOS-only, build-less. There is no
compiler and no package step: the "compile" is `bash -n`, the linter is
`shellcheck -x`, the formatter is `shfmt`. Keep it that way.

## Quick start

```bash
make                 # zero-to-ready bootstrap from a clean checkout
just                 # splash -> menu (enter/m) or fzf (f)
just hooks-install   # install the prek git hooks (LOCAL, no sudo)
just ci              # the exact gate: check + lint + test
```

## Dev workflow (just recipes)

| recipe                 | what it does                                              |
| ---------------------- | -------------------------------------------------------- |
| `just fmt`             | `shfmt -w -i 2 -ci -sr` on every shell file              |
| `just check`           | the build-less compile: `bash -n` on every file          |
| `just lint`            | `shellcheck -x` on bin/lib/test (helpers at `-S warning`) |
| `just test`            | pure-bash test harness (`test/*.bash`)                    |
| `just ci`              | check + lint + test (the gate)                            |
| `just qa`              | fmt + ci                                                  |
| `just hooks-install`   | install prek hooks for all 3 stages                      |
| `just hooks`           | `prek run --all-files` (full sweep)                      |
| `just hooks-ai-setup`  | configure the optional local-first AI commit assist      |
| `just commit`          | stage-aware commit through the intelligent commit-msg flow|
| `just changelog`       | regenerate `CHANGELOG.md` via git-cliff                  |
| `just release <part>`  | bump VERSION (major\|minor\|patch), sync binaries, changelog |

## Bash house style (5.3.15+)

- `#!/usr/bin/env bash`; guard with `BASH_VERSINFO`. Modern GNU Homebrew tools only
  (`gsed`, `ggrep`, `rg`, `fd`) -- never BSD.
- `set -uo pipefail` + explicit per-command checks in standalone scripts; short
  helpers may use `set -euo pipefail`. `trap 'exit 130' INT TERM HUP` in interactive
  scripts.
- `printf` over `echo`; `[[ ]]` over `[ ]`; `(( ))` over `let`/`expr`; `$()` over
  backticks. Parameter expansion over `sed`/`awk`/`cut` for string ops.
- Always quote variables. Typed declarations (`declare -A/-i/-n/-r/-a`). Functions
  <= 30 lines, always `local`. 2-space indent, <= 99 cols.
- Info to stderr, data to stdout. No `eval` (except the trusted, wizard-written
  `HOOKS_AI_CMD`), no `function` keyword.
- Format with `shfmt -w -i 2 -ci -sr`; lint with `shellcheck -x`. Both run in the
  pre-commit hook.

## Conventional Commits (enforced)

Every commit message must be a [Conventional Commit](https://www.conventionalcommits.org/):

```text
<type>(<scope>): <subject>       # subject imperative, <= 72 chars
```

- **types:** `feat fix docs style refactor perf test build ci chore revert`
- **scopes (ramgate):** `xray guard sample proc fmt config breaker ledger agent log docs harness`
- **branches:** `<type>/<kebab-slug>` (e.g. `feat/guard-cooldown`).

The `commit-msg` hook de-slops the message (strips co-author/emoji/filler),
deterministically auto-fixes what it safely can, then interactively nudges you (or
offers a local-first AI rewrite). A non-answer times out after 4s and aborts -- a
soft nudge, never a silent pass. Non-interactive contexts (CI, agents) get the
deterministic fix only; AI never fires on its own.

## SemVer policy

ramgate follows [SemVer](https://semver.org/). `VERSION` is the single source of
truth; `scripts/release.bash` mirrors it into the `readonly RG_VERSION` line of
both binaries.

- **patch** -- bug fixes, no behaviour change to the CLI/contract.
- **minor** -- new backwards-compatible subcommands/flags/behaviour.
- **major** -- any breaking change to the CLI surface or `docs/CONTRACT.md`.

Cut a release locally (never auto-commits or tags):

```bash
just release patch          # bump, sync binaries, regenerate CHANGELOG
git add VERSION CHANGELOG.md bin/ram-xray bin/ram-guard
git commit -m 'chore(release): vX.Y.Z'
git tag vX.Y.Z
```

## Running tests

```bash
just test                   # runs test/run.bash if present, else each test/*.bash
```

Tests are pure Bash, source-guarded, and use injectable seams (clock, process
listing, signal sender) so they never send a real signal -- see
[`docs/CONTRACT.md` §4, §17](docs/CONTRACT.md).

## The two-binary safety invariant (do not break)

`ram-xray` is the **inert** half: it must never gain signal-sending code and must
never source anything under `lib/guard/`. Only `ram-guard` may pause or kill a
process, own-user only, no root. This physical separation is the entire safety
story -- any change that blurs the wall is a defect. See
[`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) and
[`docs/CONTRACT.md` §0](docs/CONTRACT.md).
