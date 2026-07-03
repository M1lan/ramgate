# ramgate

Two pure GNU Bash ≥ 5.3.15 programs for macOS RAM introspection and proactive OOM protection.
macOS-only: every data source (`vm_stat`, `sysctl kern.memorystatus_*`, `vmmap`, `top -l`, `launchctl`, `osascript`) is Darwin-specific. Tested on macOS 26.5.2.

| binary | role | signals processes? |
|---|---|---|
| `ram-xray` | read-only RAM introspection | never — contains no signal code, never sources `lib/guard/` |
| `ram-guard` | OOM circuit breaker: pauses/kills the growing hog under pressure | yes — own-user only, no root |

Hard wall: only `ram-guard` can act; the LaunchAgent runs only `ram-guard`. `ram-xray` is structurally inert and safe to run mid-OOM.

## Memory model

- macOS "Memory Used" = App (anonymous) + Wired (unpageable) + Compressed. Cached Files is a separate, instantly reclaimable slab.
- `ps`/`top` RSS overcounts: shared library pages are billed to every mapping process. Activity Monitor's "Memory" column = `phys_footprint`; the `pid` drill-down uses `vmmap` for it.
- Stock kernel disables sustained-pressure killing (`kern.memorystatus.kill_on_sustained_pressure_count = 0`): no reclaim until swap thrash. `ram-guard` trips earlier on pressure + growth.

## Install (local, no root)

```bash
make            # bootstrap: checks deps, symlinks bin/ into ~/.local/bin
just install    # equivalent if just is present
```

`~/.local/bin` must be on `PATH`. `ram-xray doctor` / `ram-guard doctor` verify bash patch level, required tools, OS build.

## ram-xray

```text
ram-xray [--json|--tsv|--no-color] <command>

  summary        system breakdown + pressure + compressor + top hogs (default)
  top [N]        top N processes by real memory + app-grouped totals
  pid <pid>      exact phys_footprint of one process + its region map
  app <regex>    sum every process whose command matches <regex>
  why            summary + dominant memory region of the 3 biggest hogs
  watch [secs]   refresh summary every <secs> (default 3)
  doctor         environment preflight
```

`--json` / `--tsv`: colorless, stable, field-delimited records; stdout = data, info to stderr.

## ram-guard

```text
ram-guard [--dry-run|--verbose|--config FILE] <command>

  run          loop forever (what the LaunchAgent calls)
  once         evaluate once (DRY_RUN-forced: never signals)
  status       one-shot reading + the target it would pick right now
  test         loop with aggressive thresholds + DRY_RUN
  install      write + load the per-user LaunchAgent
  uninstall    unload + remove the LaunchAgent
  log          tail the log file
  doctor       environment preflight
```

Escalation ladder:

| state | trigger | action |
|---|---|---|
| WARN | pressure ≥ `WARN_PRESSURE` or free ≤ `WARN_PCT` | `SIGSTOP` fastest-growing hog (recoverable) |
| CRITICAL | pressure ≥ `CRIT_PRESSURE` or free ≤ `CRIT_PCT` | `CRIT_SIGNAL` (default `SIGKILL`) |
| recovery | `RESUME_STREAK` NORMAL ticks, and every daemon start | `SIGCONT` all paused pids |
| Emacs pre-step | before any pause/kill | `SIGUSR2` (trips debug-on-event, breaks runaway Lisp so GC reclaims) |

Safety:

- Same-user only; no root.
- Pre-signal revalidation: pid + uid + start-time re-checked immediately before signalling; recycled PID ⇒ abort + log.
- `KILL_BUDGET` (default 3) caps kills per CRITICAL episode.
- Protect set derived at runtime: `kernel_task`, `launchd`, `WindowServer`, Finder/Dock, terminal/tmux/shell, ram-guard's own binary.
- `once` is DRY_RUN-forced (no growth history on an unprimed tick).
- Config is parsed, never sourced (see below).

## Configuration

`~/.config/ramgate.conf`, override `--config FILE`. Precedence: CLI flag > env var > config file > default.
Strict `KEY=VALUE` whitelist — never `source`d; unknown keys and shell metacharacters rejected; file refused if group/world-writable or not self-owned.

| key | default | meaning |
|---|---|---|
| `POLL_INTERVAL` | `2` | seconds between samples |
| `WARN_PCT` / `CRIT_PCT` | `20` / `10` | free-memory % thresholds |
| `WARN_PRESSURE` / `CRIT_PRESSURE` | `2` / `4` | kernel pressure level thresholds |
| `WARN_STREAK` / `CRIT_STREAK` | `2` / `1` | consecutive ticks before acting |
| `RESUME_STREAK` | `5` | consecutive NORMAL ticks before resuming |
| `MIN_RSS_MB` | `300` | ignore smaller processes as targets |
| `GROW_MIN_MB` | `20` | per-tick RSS growth that counts as leaking |
| `COOLDOWN` | `5` | seconds between actions |
| `KILL_BUDGET` | `3` | max kills per CRITICAL episode |
| `CRIT_SIGNAL` | `KILL` | signal at CRITICAL (`KILL` or `TERM`) |
| `DRY_RUN` | `0` | `1` = log intended actions, send nothing |
| `NOTIFY` | `1` | desktop notifications via `osascript` |
| `EMACS_USR2` | `1` | try `SIGUSR2` to unstick Emacs first |
| `LOG_FILE` | `~/var/log/ramgate.log` | guard log |

## Architecture

```text
bin/ram-xray            read-only entrypoint (never sources lib/guard/*)
bin/ram-guard           acting entrypoint (the only binary that signals)
lib/sample.bash         kernel sampling (vm_stat + sysctl)        — pure, shared
lib/proc.bash           ps/top/vmmap inventory, phys_footprint    — pure, shared
lib/fmt.bash            bytes→human, bars, color, json/tsv        — pure, shared
lib/config.bash         defaults + whitelist config + precedence  — shared
lib/guard/breaker.bash  target selection + signal state machine   — guard-only
lib/guard/ledger.bash   restart-safe paused-PID ledger            — guard-only
lib/guard/agent.bash    launchd install/uninstall                 — guard-only
lib/guard/log.bash      key=value logging + notify                — guard-only
```

Authoritative per-module spec: [`docs/CONTRACT.md`](docs/CONTRACT.md). Pure `lib/*.bash` never signals, never mutates, never loops; the acting state machine lives only under `lib/guard/`.

## Development

```bash
just check     # bash -n every file
just lint      # shellcheck -x
just fmt       # shfmt -w -i 2 -ci -sr
just test      # pure-bash test harness (fixtures, zero real signals)
just ci        # check + lint + test
just doctor    # dependency + environment audit
just hooks-install  # prek git hooks (pre-commit, commit-msg, pre-push)
```

House style: pure GNU Bash ≥ 5.3.15 — builtins and parameter expansion over external commands, `set -uo pipefail`, `[[ ]]`, `printf` over `echo`, everything quoted.
Conventional Commits enforced by the `commit-msg` hook; SemVer via `VERSION` + `scripts/release.bash` (never auto-commits or tags).

## License

AGPL-3.0-or-later. See [LICENSE](LICENSE).
