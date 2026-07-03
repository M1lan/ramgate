# Security policy

ramgate can **pause and kill processes** on a macOS machine. That makes its trust
boundaries part of its security posture, not an afterthought. This document states
the threat model, the defenses, and how to report a vulnerability.

## Scope and privilege model

- **Same-user only.** `ram-guard` acts exclusively on processes owned by the user
  running it. It never uses `sudo`, never escalates, and is never installed as
  root. The LaunchAgent runs in the user's own session.
- **`ram-xray` is inert.** The introspector sends no signals and mutates no state.
  It is safe to run at any time, including mid-OOM. See the two-binary invariant in
  [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
- **Local, offline.** ramgate makes no network calls. The optional AI commit
  assist is local-first and opt-in (see below).

## Threat model

The primary asset an attacker would want to influence is **which process gets
paused or killed** -- i.e. steering the circuit breaker. The main vectors:

1. **A malicious or tampered config file.** `ramgate.conf` and environment
   overrides can tune thresholds and target selection. A hostile config could try
   to make the guard kill a process the user did not intend, or inject code if the
   config were naively `source`d.
2. **A crafted process name / command line.** Process metadata is attacker-
   influenced input (a process can name itself anything). It must never be
   interpreted as code or as a shell pattern that changes control flow.
3. **The AI-assist path.** `config/hooks/ai.env` sets `HOOKS_AI_CMD`, which the
   hooks execute. A tampered `ai.env` is arbitrary code execution at commit time.

## Defenses

- **Whitelist-parse, never source, untrusted config.** ramgate config that can
  steer the killer is parsed by reading known keys and validating their values --
  it is **not** `source`d as Bash. Unknown keys are ignored; malformed values fall
  back to safe defaults. This denies vector (1) code execution and unintended
  targeting. (Contrast: `config/hooks/ai.env` *is* sourced, and is therefore
  explicitly a trusted, developer-owned file written by the setup wizard with
  `printf %q` -- never paste untrusted content into it.)
- **Process metadata is data, never code.** Names/command lines are always quoted
  and compared as literal strings; they never reach `eval` and never widen a glob.
- **Signal seam is injectable and auditable.** The only signal-sending path lives
  in `lib/guard/breaker.bash`, is loaded only by `ram-guard`, and is injectable so
  tests capture would-be signals instead of sending them. `ram-xray` cannot reach
  it by construction.
- **No root, no cross-user.** Enforced by same-user checks; ramgate refuses to act
  on processes it does not own.
- **Secrets never committed.** A `gitleaks` pre-commit hook scans the staged diff
  and blocks the commit on a hit. `ai.env` is gitignored.

## Reporting a vulnerability

Report privately via GitHub Security Advisories (repository Security tab).
Include a description, affected version (`ram-xray --version` / `ram-guard
--version`), macOS version, and a minimal reproduction if possible. Do not
open a public issue for an unfixed vulnerability.
