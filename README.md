# ramgate

**Look at your Mac's RAM, and gate the hogs before macOS falls over.**

`ramgate` is two small, pure **GNU Bash ≥ 5.3.15** programs for macOS:

| binary | role | touches your processes? |
|---|---|---|
| **`ram-xray`** | read-only RAM introspection — *what* is resident and *why* | **never.** Sends no signals, mutates nothing. |
| **`ram-guard`** | proactive OOM circuit breaker — pauses/kills the growing hog under pressure | **yes**, deliberately. Own-user processes only, no root. |

They are **two separate binaries on purpose.** `ram-xray` physically contains no
signal-sending code and never loads the guard modules, so you can run it blind at
any pressure level — including in the middle of an OOM episode — with a structural
guarantee that it cannot pause or kill anything. Only `ram-guard` can act, and it
is the only thing the LaunchAgent ever runs.

> **macOS-only, by design.** Every data source (`vm_stat`, `sysctl
> kern.memorystatus_*`, `vmmap`, `top -l`, `launchctl`, `osascript`) is
> Darwin-specific. `ramgate` exists *because* macOS only shows its "system has run
> out of application memory" dialog once swap is already thrashing — too late. This
> tool trips much earlier. Tested on **macOS 26.5.2**. There is no Linux build goal;
> the only cross-cutting rule is clean, pure Bash 5.3.15+.

## Why it exists

macOS "Memory Used" is not one number. It is App (anonymous), Wired (unpageable),
and Compressed — and *separately* a big slab of Cached Files the kernel hands back
the instant anything asks. `ps`/`top` RSS **overcounts**, because shared library
pages get billed to every process that maps them. The only figure matching Activity
Monitor's "Memory" column is each process's `phys_footprint`, which is why the
per-process drill-down shells out to `vmmap` for the exact number instead of
trusting RSS.

And on this hardware the kernel ships with sustained-pressure killing disabled
(`kern.memorystatus.kill_on_sustained_pressure_count = 0`), so nothing reclaims RAM
until you hit the wall — then it swaps like crazy, then it stalls. `ram-guard` polls
the kernel's own pressure signals and per-process growth and trips *before* that.

## Install (local, never root)

```bash
git clone <this-repo> ~/projects/ramgate
cd ~/projects/ramgate
make            # bootstrap: checks deps, symlinks bin/ into ~/.local/bin
# or, if you have just:
just install    # symlink ram-xray + ram-guard into ~/.local/bin (LOCAL, no sudo)
```

Ensure `~/.local/bin` is on your `PATH`. Run `ram-xray doctor` / `ram-guard doctor`
to verify the environment (bash patch level, required macOS tools, OS build).

## `ram-xray` — read-only introspection

```text
ram-xray [--json|--tsv|--no-color] <command>

  summary        system breakdown + pressure + compressor + top hogs (default)
  top [N]        top N processes by real memory + app-grouped totals
  pid <pid>      EXACT phys_footprint of one process + its region map
  app <regex>    sum every process whose command matches <regex>
  why            summary + dominant memory region of the 3 biggest hogs
  watch [secs]   refresh summary every <secs> (default 3)
  doctor         environment preflight
```

`--json` / `--tsv` emit colorless, stable, field-delimited records (stdout = data,
info/chrome to stderr) so you can pipe `summary`/`top`/`pid` into other tools.

## `ram-guard` — the circuit breaker

```text
ram-guard [--dry-run|--verbose|--config FILE] <command>

  run          loop forever (what the LaunchAgent calls)
  once         evaluate once (DRY_RUN-forced: never signals)
  status       one-shot reading + the target it would pick right now
  test         loop with aggressive thresholds + DRY_RUN (no signals sent)
  install      write + load the per-user LaunchAgent
  uninstall    unload + remove the LaunchAgent
  log          tail the log file
  doctor       environment preflight
```

Escalation ladder:

- **WARN** (pressure ≥ warn, or free ≤ `WARN_PCT`) → `SIGSTOP` the fastest-growing
  hog. Pausing is fully recoverable and non-destructive — the process is frozen, not
  killed, and you can save/quit.
- **CRITICAL** (pressure critical, or free ≤ `CRIT_PCT`) → `SIGKILL` it to reclaim
  RAM before the machine stalls.
- **Recovery** → paused processes are `SIGCONT`ed once pressure clears **and** on the
  next daemon start, so a crash or reboot never leaves an app frozen forever.
- **Emacs** gets a `SIGUSR2` (trips debug-on-event, breaks a runaway Lisp loop so GC
  can reclaim) *before* any pause/kill — a non-destructive rescue that keeps your
  session.

### Safety design

- **Same-user only.** Never signals another user's or a system process. No root.
- **Every signal is revalidated.** Immediately before pausing/killing, the target's
  pid + uid + start-time are re-checked; if the PID was recycled between sampling and
  signalling, the action is aborted and logged — an innocent process never eats a
  stray `SIGKILL`.
- **Kill budget.** A per-episode cap (`KILL_BUDGET`, default 3) stops a memory spiral
  from turning into a process massacre.
- **Protected set is runtime-derived.** `kernel_task`, `launchd`, `WindowServer`,
  Finder/Dock, your terminal/tmux/shell, **and ram-guard itself** are never eligible
  — computed at run time from the running binary's own name, so a rename can't make
  the guard kill its own terminal.
- **`once` never signals.** A single unprimed tick has no growth history, so `once` is
  forced into dry-run — it reports what it *would* do, safely.
- **Config is parsed, never sourced.** See below.

## Configuration

`ram-guard` reads `~/.config/ramgate.conf` (override with `--config FILE`).
Precedence, highest wins: **CLI flag > environment variable > config file > built-in
default.**

The config file is a strict `KEY=VALUE` **whitelist** — it is *never* `source`d, so a
poisoned config cannot execute arbitrary shell in a process that can `SIGKILL`. Unknown
keys and values with shell metacharacters are rejected, and the file is refused
outright if it is group/world-writable or not owned by you.

| key | default | meaning |
|---|---|---|
| `POLL_INTERVAL` | `2` | seconds between samples |
| `WARN_PCT` / `CRIT_PCT` | `20` / `10` | free-memory %% thresholds |
| `WARN_PRESSURE` / `CRIT_PRESSURE` | `2` / `4` | kernel pressure level thresholds |
| `WARN_STREAK` / `CRIT_STREAK` | `2` / `1` | consecutive ticks before acting |
| `RESUME_STREAK` | `5` | consecutive NORMAL ticks before resuming |
| `MIN_RSS_MB` | `300` | ignore processes smaller than this as targets |
| `GROW_MIN_MB` | `20` | per-tick RSS growth that counts as "leaking" |
| `COOLDOWN` | `5` | seconds between actions |
| `KILL_BUDGET` | `3` | max kills per CRITICAL episode |
| `CRIT_SIGNAL` | `KILL` | signal at CRITICAL (`KILL` or `TERM`) |
| `DRY_RUN` | `0` | `1` = log intended actions, send no signals |
| `NOTIFY` | `1` | `1` = desktop notifications via `osascript` |
| `EMACS_USR2` | `1` | `1` = try `SIGUSR2` to unstick Emacs first |
| `LOG_FILE` | `~/var/log/ramgate.log` | where the guard logs |

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

The pure `lib/*.bash` modules never send a signal, never mutate state, never loop
forever. The acting state machine lives entirely under `lib/guard/` and is loaded
only by `ram-guard`. Shared *library*, separate *binaries*.

## Development

This repo ships a full [`just`](https://github.com/casey/just) developer harness
(`just` with no arguments shows the menu). Common recipes:

```bash
just check     # bash -n every file
just lint      # shellcheck -x
just fmt       # shfmt -w -i 2 -ci -sr
just test      # the pure-bash test harness (fixtures, zero real signals)
just doctor    # dependency + environment audit
```

House style: pure GNU Bash ≥ 5.3.15, "programming not scripting" — builtins and
parameter expansion over external commands, `set -uo pipefail` (never bare `set -e`),
`[[ ]]`, `printf` over `echo`, everything quoted.

## License

MIT © 2026 Milan Santosi. See [LICENSE](LICENSE).
