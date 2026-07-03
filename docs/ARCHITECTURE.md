# ramgate architecture

ramgate is two small, pure **GNU Bash >= 5.3.15** programs for macOS. There is no
build system: the "compile" is `bash -n`, the linter is `shellcheck -x`, the
formatter is `shfmt`. This document describes the layout and the single safety
design that shapes everything. The precise per-file interface is in
[`docs/CONTRACT.md`](CONTRACT.md); this is the map, that is the contract.

## The two-binary safety invariant

The whole safety story is *physical separation*, not runtime flags:

| binary          | half   | may signal/mutate?      | loads `lib/guard/`? |
| --------------- | ------ | ----------------------- | ------------------- |
| `bin/ram-xray`  | INERT  | never                   | never               |
| `bin/ram-guard` | ACTING | yes (own-user, no root) | yes                 |

`ram-xray` contains **no signal-sending code** and **never sources anything under
`lib/guard/`**. You can run it at any pressure level -- including mid-OOM -- with a
structural guarantee that it cannot pause or kill anything. Only `ram-guard` can
act, and the LaunchAgent only ever runs `ram-guard`.

> **Invariant (do not regress):** `ram-xray` must never gain signal code and must
> never source `lib/guard/*`. Any change that blurs this wall is a defect, not a
> feature. See [`docs/CONTRACT.md` §0](CONTRACT.md) ("Two binaries, hard wall").

## Library layout

```text
bin/
  ram-xray          INERT introspector (summary|top|pid|app|why|watch|doctor)
  ram-guard         ACTING watchdog (run|status|once|test|install|uninstall|log|doctor)
lib/                PURE, shared, signal-free -- safe for BOTH binaries
  config.bash       config + precedence (read side)
  sample.bash       kernel sampling (vm_stat, sysctl kern.memorystatus_*)
  proc.bash         process inventory
  fmt.bash          formatting
lib/guard/          PRIVATE to ram-guard -- ram-xray must never source these
  breaker.bash      target selection + signal state machine
  ledger.bash       restart-safe pause ledger
  agent.bash        launchd LaunchAgent management
  log.bash          logging + notify
```

Every `lib/` module is pure and signal-free, so both binaries may source it. The
`lib/guard/` modules are the only ones that decide on or send signals, and only
`ram-guard` loads them. Each file carries a source-guard (see CONTRACT §2) so a
module cannot be executed directly or sourced into the wrong context.

## Injectable seams (testability)

Adapters (clock, process listing, signal sender) are injectable so tests can pin
time and capture would-be signals instead of sending them (CONTRACT §4, §17). The
test harness is pure Bash under `test/*.bash`, source-guarded like the libs.

## Developer harness

The repository ships a `prek`-driven git-hook harness (see
[`CONTRIBUTING.md`](../CONTRIBUTING.md)):

- **pre-commit:** `shfmt` auto-format + re-stage, `shellcheck -x`, `bash -n`,
  `gitleaks` staged-secret scan, `rumdl` markdown lint.
- **commit-msg:** intelligent Conventional-Commits enforcement (de-slop ->
  deterministic autofix -> interactive nudge -> optional local-first AI rewrite).
- **pre-push:** conventional branch-name enforcement.

Releases are SemVer, driven by `scripts/release.bash` + `cliff.toml` (git-cliff).
The single source of version truth is the `VERSION` file, mirrored into the
`readonly RG_VERSION` line of each binary by the release script.
