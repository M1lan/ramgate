# Security

## Privilege model

- Same-user only: signals only processes owned by the invoking user. No sudo, no root install. LaunchAgent runs in the user session.
- `ram-xray` is inert: sends no signals, mutates no state, never sources `lib/guard/`.
- Offline: no network calls. AI commit assist is local-first and opt-in.

## Threat vectors and defenses

| vector | defense |
|---|---|
| tampered `ramgate.conf` (steer the killer, inject code) | whitelist-parsed, never `source`d; unknown keys ignored; malformed values fall back to defaults; file refused if group/world-writable or not self-owned |
| crafted process name / command line | metadata is data: quoted literal comparison, never `eval`, never widens a glob |
| tampered `config/hooks/ai.env` (`HOOKS_AI_CMD` is executed) | trusted developer-owned file, written by the setup wizard with `printf %q`, gitignored |
| guard targets itself / the terminal | protect set derived at runtime: `kernel_task`, `launchd`, `WindowServer`, Finder/Dock, terminal/tmux/shell, ram-guard's own binary |
| stray real signal from tests | single signal path in `lib/guard/breaker.bash`, injectable seam; tests capture would-be signals |
| committed secrets | `gitleaks` pre-commit scan blocks on hit; `ai.env` gitignored |

## Reporting

Report privately via GitHub Security Advisories (repository Security tab): description, affected version (`ram-xray --version` / `ram-guard --version`), macOS version, minimal repro.
No public issues for unfixed vulnerabilities.
