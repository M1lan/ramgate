# ramgate — internal interface CONTRACT

Authoritative spec every module obeys. Parallel authors: implement **to this**,
not to your taste. Divergence = defect. Target: GNU Bash **>= 5.3.15**, macOS-only.

**Not portable, by design.** Every data source (`vm_stat`, `sysctl kern.memorystatus_*`,
`vmmap`, `top -l`, `launchctl`, `osascript`) is Darwin-only. The tool exists precisely
*because* it fixes/improves macOS OOM behavior. Tested target: **macOS 26.5.2**. There is
NO "runs on Linux" goal — the only cross-cutting rule is clean, pure GNU Bash 5.3.15+.
`doctor` prints the running OS/build and warns (not errors) if it is not 26.x.

## 0. Two binaries, hard wall

- `bin/ram-xray` — **read-only** introspection. Contains ZERO signal-sending code.
  MUST NOT `source` anything under `lib/guard/`. Provably inert.
- `bin/ram-guard` — the **actor** (pressure watchdog, STOP/KILL/USR2/CONT, launchd).
  Only thing the LaunchAgent ever invokes.
- Shared code = **pure** libs only: `lib/sample.bash`, `lib/proc.bash`,
  `lib/fmt.bash`, `lib/config.bash`. These NEVER send a signal, NEVER mutate
  system state, NEVER loop forever, NEVER hold daemon state.
- Acting state machine lives in `lib/guard/{breaker,ledger,agent,log}.bash`,
  sourced **only** by `bin/ram-guard`.

## 1. Every file header (mandatory)

```bash
#!/usr/bin/env bash
# <file> -- <one line>
if [ -z "${BASH_VERSINFO+set}" ]; then
  echo >&2 'error: ramgate requires GNU bash'; exit 78   # EX_CONFIG
fi
((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3))) || {
  printf >&2 'error: bash 5.3+ required (found %s)\n' "$BASH_VERSION"; exit 78; }
set -uo pipefail
IFS=$' \t\n'
export LC_ALL=C
```

Patch-level guard `>= 5.3.15` is enforced once in `lib/config.bash::rg_require_bash`
(checks `BASH_VERSINFO[2] >= 15` when major.minor == 5.3) and both bins call it first.

## 2. Source-guard (every lib AND both bins)

Libs must be sourceable in tests without executing anything:

```bash
# ... definitions ...
# bins only, at very end:
[[ ${BASH_SOURCE[0]} == "${0}" ]] && rg_main "$@"
```

Libs define functions only; NO top-level side effects at source time (no `mkdir`,
no sampling, no `mcb_log`). Constants via `readonly` are fine.

## 3. Naming

- Public functions: prefix `rg_` (shared) / `guard_` (acting) / `xray_` (read cmds).
- Private helpers: leading `_`, e.g. `_rg_bytes`.
- Env/exported/consts: `UPPER_CASE`. Locals: `lower_case`, always `local`.
- Assoc-array sample keys are the RAW `vm_stat` labels (see §5).

## 4. Injectable adapters (testability — REQUIRED)

Every external command that touches the host goes through an overridable var so
tests inject fixtures. Define defaults in `lib/config.bash`, allow env override:

```bash
: "${RG_PS:=ps}"          : "${RG_SYSCTL:=sysctl}"    : "${RG_VMSTAT:=vm_stat}"
: "${RG_TOP:=top}"        : "${RG_VMMAP:=vmmap}"      : "${RG_LAUNCHCTL:=launchctl}"
: "${RG_KILL:=kill}"      : "${RG_SLEEP:=sleep}"      : "${RG_OSASCRIPT:=osascript}"
: "${RG_GAWK:=$(command -v gawk || true)}"
# clock seam (tests pin time): default reads bash builtin
rg_now()  { printf '%(%s)T' -1; }         # override in tests
```

Call sites use `"$RG_PS"`, `"$RG_KILL"`, `rg_now`, never the bare command.
`kill` in guard code ALWAYS via `"$RG_KILL"`.

## 5. lib/sample.bash — kernel sampling (PURE, shared)

Exposes:

- `rg_sample_vm` -> fills `declare -gA RG_PG` (label->page count) + sets `RG_PAGESZ`
  from `vm_stat`'s own reported page size. Keys are raw labels, e.g.
  `RG_PG[Pages free]`, `RG_PG[Pages wired down]`, `RG_PG[Pages occupied by compressor]`,
  `RG_PG[Pages stored in compressor]`, `RG_PG[Anonymous pages]`,
  `RG_PG[File-backed pages]`, `RG_PG[Pages purgeable]`, `RG_PG[Pages speculative]`.
- `rg_pg_bytes <label>` -> echoes `count * RG_PAGESZ`.
- `rg_sysctl_n <name> [default]`.
- `rg_pressure_level` (1/2/4), `rg_free_pct`.
- `rg_swap` -> echoes `used_bytes total_bytes` (SINGLE unified parser; kill the two
  divergent copies from the originals). Pure-bash fixed-point, no bc, no gawk.
- Derived helper `rg_breakdown` -> sets globals: `RG_TOTAL RG_APP RG_WIRED
  RG_COMPRESSED RG_CACHED RG_FREE RG_SWAP_U RG_SWAP_T RG_COMP_RATIO_X RG_COMP_RATIO_D`
  using the Activity-Monitor math: app = anon - purgeable (floor 0);
  used = app+wired+compressed; cached = filebacked+purgeable; free = free+spec.

MUST degrade without gawk (pure-bash path) since it may run DURING OOM when fork
can fail. gawk allowed only where genuinely needed and guarded.

## 6. lib/proc.bash — process inventory (PURE, shared)

- `rg_ps_snapshot` -> emits TSV `pid<TAB>rss_kb<TAB>uid<TAB>start_epoch<TAB>comm`
  via `"$RG_PS" -axo pid=,rss=,uid=,lstart=,comm=` (start time = recycle guard).
- `rg_top_by_mem <n>` -> ranked list, one proc per line, `mem_bytes<TAB>pid<TAB>cpu<TAB>comm`.
- `rg_footprint <pid>` -> exact phys_footprint bytes via `vmmap --summary` (the ONLY
  number matching Activity Monitor). Empty if not permitted.
- `rg_dominant_region <pid>` -> "<region-name>\t<resident_bytes>" (preserve the
  field-from-the-right RESIDENT extraction from ram-xray why-cmd — it is subtle,
  copy its logic exactly, add a fixture test).
- `rg_proc_alive <pid> <expect_uid> <expect_start_epoch>` -> 0 iff pid exists AND
  uid matches AND start-epoch matches (the anti-PID-recycle gate; guard calls this
  immediately before EVERY signal).

## 7. lib/fmt.bash — formatting (PURE, shared)

- `rg_human <bytes>` -> "1.4 GB" style, integer math.
- `rg_bar total used cached free width` -> colored bar (TTY only).
- Color: set `RG_C_*` vars; blanked unless `[[ -t 1 ]]`. Never emit ANSI when
  `RG_JSON`/`RG_TSV` set or stdout not a TTY.
- `rg_emit` helpers for `--json` / `--tsv`: colorless, stable, field-delimited.
  **stdout = data, stderr = info/logs.** Machine modes carry NO ANSI, NO bars.

## 8. lib/config.bash — config + precedence (shared, read side)

- `rg_require_bash` (patch guard §1).
- Defaults table (all guard tunables: POLL_INTERVAL WARN_PCT CRIT_PCT WARN_PRESSURE
  CRIT_PRESSURE WARN_STREAK CRIT_STREAK RESUME_STREAK MIN_RSS_MB GROW_MIN_MB
  COOLDOWN CRIT_SIGNAL AUTO_RESUME DRY_RUN NOTIFY HEARTBEAT_TICKS KILL_BUDGET
  EMACS_RE EMACS_USR2 EMACS_USR2_GRACE PROTECT_RE LOG_FILE).
- `rg_load_config` implements precedence **CLI > env > conf > defaults**:
  1. seed defaults, 2. parse conf via `rg_parse_conf` (WHITELIST KEY=VALUE only —
  NO `source`, reject unknown keys, reject values with shell metachars), 3. apply
  env overrides, 4. caller applies parsed CLI flags LAST.
- `rg_parse_conf <file>`: line-based, `^[A-Z_]+=...$`, key must be in allowlist,
  value assigned via `printf -v`. Refuse if file is group/world-writable or not
  owned by the invoking uid (it can steer a killer — treat as privileged).

## 9. lib/guard/breaker.bash — target selection + state machine (PRIVATE)

- Streak globals, severity classifier `guard_severity level freep -> NORMAL|WARN|CRIT`.
- `guard_pick_target include_paused` -> sets TARGET_{PID,RSS_KB,COMM,UID,START,REASON}.
  Fastest grower above MIN_RSS else biggest. Uses `rg_ps_snapshot`. Excludes:
  `$$`, own pgid, and anything matching the RUNTIME-derived protect set (§10).
- Emacs SIGUSR2-first ladder preserved verbatim in spirit (USR2 -> grace -> pause ->
  kill), re-armed when pressure clears.
- **Before every signal**: `rg_proc_alive TARGET_PID TARGET_UID TARGET_START` MUST
  pass or the action aborts with a logged `action=SKIP reason=pid-revalidate-failed`.
- **KILL_BUDGET**: max kills per CRIT episode (default 3). Episode resets on NORMAL
  streak. Exceeding it logs `action=BUDGET-EXHAUSTED` and takes no further kill.
- `once` subcommand is **DRY_RUN-forced** (never signals from a single unprimed tick).

## 10. Runtime self/terminal protection (PRIVATE, breaker+agent)

Protect set built AT RUNTIME, not a hardcoded literal:
`_guard_protect_re` = static essentials (kernel_task launchd WindowServer loginwindow
Dock$ Finder$ ... tmux Ghostty Terminal /(z|ba)?sh$ sshd) PLUS injected
`${BASH_SOURCE##*/}` basename, `$LABEL`, and the process-group of `$$`. A rename must
never make the guard eligible to pause/kill itself or the user's terminal. Test asserts
the running binary's own basename matches.

## 11. lib/guard/ledger.bash — restart-safe pause ledger (PRIVATE)

- Paused victims persisted to `${RG_STATE:-$HOME/var/run}/ramgate.paused` as
  `pid<TAB>start_epoch<TAB>comm` lines.
- `guard_ledger_add/remove/load`. On `ram-guard run` STARTUP, `guard_ledger_resume`
  SIGCONTs every still-live ledger PID whose start-epoch still matches (recycle-safe),
  then clears stale lines. Fixes the orphaned-frozen-app-across-restart bug.

## 12. lib/guard/agent.bash — launchd (PRIVATE)

- plist invokes `bin/ram-guard run` by ABSOLUTE path. `ThrottleInterval` set
  explicitly (>=10) so a crash-on-bad-conf can't respawn-spam. Preserve the
  bootout-then-poll install race fix from the original. `KeepAlive` true.

## 13. lib/guard/log.bash — logging + notify (PRIVATE)

- `guard_log k=v ...` flat key=value + ISO ts; append to LOG_FILE; echo to stdout
  only when `[[ -t 1 ]]`. `guard_notify title msg` via `"$RG_OSASCRIPT"`, best-effort.

## 14. CLI / exit codes (both bins, GNU baseline)

- Global flags: `--help -h`, `--version -V`, `--json`, `--tsv`, `--no-color`,
  `--dry-run` (guard), `--verbose`, `--config FILE`. `--` ends option parsing.
- Exit: 0 ok; 2 usage error (EX_USAGE=64 acceptable too — pick 2 for usage, document);
  69 (EX_UNAVAILABLE) missing macOS tool; 78 (EX_CONFIG) bad bash/config. Document the table.
- stdout = data only; all human chrome/info/logs to stderr in machine modes.

## 15. Subcommands

- `ram-xray`: `summary`(default) `top [N]` `pid <pid>` `app <regex>` `why` `watch [secs]`
  `doctor` `--help/--version`.
- `ram-guard`: `run` `status` `once`(dry-run) `test` `install` `uninstall` `log`
  `doctor` `--help/--version`.
- `doctor`: preflight — bash patch level, `/opt/homebrew/bin/bash`, each required
  macOS tool present, gawk optional, GNU sort/head, launchd reachable. Non-zero if any hard dep missing.

## 16. Behaviors to PRESERVE (no silent regression)

1. Emacs SIGUSR2-first rescue ladder + re-arm on clear.
2. launchd bootout-then-poll install race fix.
3. phys_footprint via `vmmap --summary` = the exact Activity Monitor number.
4. why-cmd dominant-region field-from-the-right RESIDENT extraction.
5. Activity-Monitor breakdown math (app = anon - purgeable, etc.).
6. Colour only on TTY; plain when piped.
7. Same-user-only signalling (no root ever).

## 17. Tests (test/, pure bash, source-guarded)

Each lib unit-tested by sourcing it and injecting adapters via fixtures in
`test/fixtures/` (canned `vm_stat`, `ps`, `vmmap`, `sysctl` output). MUST include:
protect-set-covers-self test, pick-target-on-fixture test (zero real signals),
config-precedence test, pid-revalidate-recycle test, swap-parser table test.

## 18. Consumed-function surface (integration checklist — bins call THESE)

The two dispatchers in `bin/` are authored by the leader/integrator. They call the
functions below; each module MUST export exactly these names (leader reconciles any
gap during integration). If a name here is missing from your module, it is a defect.

### lib/config.bash

`rg_require_bash` · `rg_load_config <conffile>` · `rg_parse_conf <file>` ·
`rg_init_colors` (sets `RG_C_*`, honours `RG_NO_COLOR`/`RG_JSON`/`RG_TSV`/TTY) ·
`rg_doctor <xray|guard>` (preflight; prints OS build via `sw_vers`, warns if not 26.x;
non-zero on missing hard dep). Defines adapter vars (§4) + all guard defaults (§8) as
shell vars in the current scope after `rg_load_config`.

### lib/sample.bash

`rg_sample_vm` (fills `RG_PG`,`RG_PAGESZ`) · `rg_pg_bytes` · `rg_sysctl_n` ·
`rg_pressure_level` · `rg_free_pct` · `rg_swap` (echoes `used total` bytes) ·
`rg_breakdown` (sets `RG_TOTAL RG_USED RG_APP RG_WIRED RG_COMPRESSED RG_CACHED RG_FREE
RG_SWAP_U RG_SWAP_T RG_COMP_RATIO_X RG_COMP_RATIO_D`).

### lib/proc.bash

`rg_ps_snapshot` · `rg_top_by_mem <n>` (TSV `mem_bytes\tpid\tcpu\tcomm`) ·
`rg_top_pids <n>` (TSV `pid\tcomm`) · `rg_footprint <pid>` (bytes) ·
`rg_dominant_region <pid>` · `rg_proc_alive <pid> <uid> <start>` ·
`rg_pid_exists <pid>` · `rg_pid_comm <pid>` · `rg_pid_ps_line <pid>` (human RSS/VSZ/%mem) ·
`rg_pid_regions <pid>` (vmmap region rows) · `rg_app_match <regex>` (matched procs + total) ·
`rg_app_grouped <n>` (RSS summed by leaf command name).

### lib/fmt.bash

`rg_human <bytes>` · `rg_bar total used cached free width` · `rg_emit_json_summary` ·
`rg_emit_tsv_summary` (both read the `RG_*` breakdown globals). `RG_C_*` color vars.

### lib/guard/log.bash

`guard_log k=v...` · `guard_notify title msg`.

### lib/guard/ledger.bash

`guard_ledger_resume` (startup un-pause) · `guard_ledger_add/remove` ·
`guard_ledger_count`.

### lib/guard/agent.bash

`guard_install <script_path> <label>` · `guard_uninstall <label>` · `guard_plist_path <label>`.

### lib/guard/breaker.bash (OMX)

`guard_build_protect_set <selfname> <label> <pid>` (runtime protect set §10) ·
`guard_severity <level> <freep>` · `guard_pick_target <include_paused>` (sets
`TARGET_PID TARGET_RSS_KB TARGET_COMM TARGET_UID TARGET_START TARGET_REASON`) ·
**`guard_tick`** (the per-poll orchestration: sample -> severity -> streak state ->
WARN pause / CRIT kill with `rg_proc_alive` revalidation + `KILL_BUDGET` + Emacs USR2
ladder + NORMAL-streak resume via `guard_ledger`/`guard_resume_all`). guard_tick ties
the state machine together and is called by `ram-guard run/once/test`.
