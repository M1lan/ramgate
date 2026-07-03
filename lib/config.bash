#!/usr/bin/env bash
# lib/config.bash -- config, precedence, injectable adapters (PURE, read side).
if [ -z "${BASH_VERSINFO+set}" ]; then
  echo >&2 'error: ramgate requires GNU bash'
  exit 78 # EX_CONFIG
fi
((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3))) || {
  printf >&2 'error: bash 5.3+ required (found %s)\n' "$BASH_VERSION"
  exit 78
}
set -uo pipefail
IFS=$' \t\n'
export LC_ALL=C

# This library is PURE (§0): it never sends a signal, never mutates system state,
# never loops, holds no daemon state. It defines functions only -- the defaults
# `: "${VAR:=...}"` seeding lives INSIDE functions (rg_defaults / rg_adapters_init),
# NEVER at source time (§2), so sourcing has zero side effects.

## Bash version guard (§1) ---------------------------------------------------

# Patch-level guard enforced once here; both bins call it first as
# `rg_require_bash || exit $?`. Returns 78 (EX_CONFIG) on any failure so a lib
# source in a test is never terminated by an exit at file scope.
rg_require_bash() {
  if [ -z "${BASH_VERSINFO+set}" ]; then
    printf 'error: ramgate requires GNU bash\n' >&2
    return 78
  fi
  if ((BASH_VERSINFO[0] < 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] < 3))); then
    printf 'error: bash 5.3+ required (found %s)\n' "$BASH_VERSION" >&2
    return 78
  fi
  # When major.minor is exactly 5.3, require patch level >= 15 (BASH_VERSINFO[2]).
  if ((BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] == 3 && BASH_VERSINFO[2] < 15)); then
    printf 'error: bash 5.3.15+ required (found %s)\n' "$BASH_VERSION" >&2
    return 78
  fi
  # Both bins call rg_require_bash FIRST (§1). It is therefore the single shared
  # bootstrap seam, so seed the injectable adapters here (idempotent `:=`). This
  # guarantees RG_PS/RG_VMSTAT/RG_TOP/... are bound under `set -u` for BOTH bins,
  # including the read-only ram-xray, which never calls rg_load_config.
  rg_adapters_init
  return 0
}

## Injectable adapters + clock seam (§4) -------------------------------------

# Every external command that touches the host goes through an overridable var so
# tests inject fixtures. Seeded here (never at source time) with env override via
# `:=`. Call sites use "$RG_PS", "$RG_KILL", rg_now -- never the bare command.
#
# RG_STAT extends §4's injectable-adapter principle: rg_parse_conf must read a
# file's owner/permission bits (a security gate, below), and stat touches the
# host, so it too is made injectable rather than hard-wired.
rg_adapters_init() {
  : "${RG_PS:=ps}"
  : "${RG_SYSCTL:=sysctl}"
  : "${RG_VMSTAT:=vm_stat}"
  : "${RG_TOP:=top}"
  : "${RG_VMMAP:=vmmap}"
  : "${RG_LAUNCHCTL:=launchctl}"
  : "${RG_KILL:=kill}"
  : "${RG_SLEEP:=sleep}"
  : "${RG_OSASCRIPT:=osascript}"
  # Security gate hardening: pin the OS-native BSD stat by ABSOLUTE path. A bare
  # `stat` is (a) ambiguous -- Homebrew's coreutils gnubin shadows it with GNU
  # stat, whose flags differ (`-c '%a'` vs BSD `-f '%Lp'`) -- and (b) unsafe,
  # since a hostile entry earlier in PATH could shim `stat` to fake "safe"
  # perms/ownership and defeat the config gate below. Tests override RG_STAT.
  : "${RG_STAT:=/usr/bin/stat}"
  : "${RG_GAWK:=$(command -v gawk || true)}"
}

# Clock seam: tests pin time by redefining rg_now. Default reads the bash
# builtin (no fork) and echoes epoch seconds.
rg_now() { printf '%(%s)T' -1; }

## Defaults table (§8) -------------------------------------------------------

# The single source of truth: default value for every config key. Its key set is
# ALSO the whitelist rg_parse_conf accepts. Populated into a global assoc at
# runtime (idempotent), never at source time.
_rg_defaults_table() {
  declare -gA RG_CONF_DEFAULT=(
    [POLL_INTERVAL]=2
    [WARN_PCT]=20
    [CRIT_PCT]=10
    [WARN_PRESSURE]=2
    [CRIT_PRESSURE]=4
    [WARN_STREAK]=2
    [CRIT_STREAK]=1
    [RESUME_STREAK]=5
    [MIN_RSS_MB]=300
    [GROW_MIN_MB]=20
    [COOLDOWN]=5
    [CRIT_SIGNAL]=KILL
    [AUTO_RESUME]=1
    [DRY_RUN]=0
    [NOTIFY]=1
    [HEARTBEAT_TICKS]=30
    [KILL_BUDGET]=3
    [EMACS_RE]='(/Emacs$|/emacs$)'
    [EMACS_USR2]=1
    [EMACS_USR2_GRACE]=8
    [PROTECT_RE]='(kernel_task|launchd|WindowServer|loginwindow|logind|Dock$|Finder$|SystemUIServer|coreaudiod|cfprefsd|mds|mds_stores|mdworker|distnoted|notifyd|opendirectoryd|securityd|sshd|/ssh$|tmux|/(z|ba)?sh$|Ghostty|iTerm|Terminal|ramgate)'
    [LOG_FILE]="$HOME/var/log/ramgate.log"
  )
}

# Seed every config key to its default value (the lowest precedence layer).
rg_defaults() {
  _rg_defaults_table
  local key
  for key in "${!RG_CONF_DEFAULT[@]}"; do
    printf -v "$key" '%s' "${RG_CONF_DEFAULT[$key]}"
  done
}

## Whitelist conf parser (SECURITY-CRITICAL) ---------------------------------

# THREAT MODEL
# ------------
# This config file steers a PROCESS KILLER: PROTECT_RE decides who is spared,
# CRIT_SIGNAL/KILL_BUDGET decide how hard it hits, DRY_RUN decides whether it
# acts at all. A hostile or careless conf can turn the guard into a weapon
# against the user's own session. It is therefore treated as PRIVILEGED input:
#
#   1. NEVER `source` it. Sourcing executes arbitrary code as the user. Values
#      are only ever read with `read -r`, matched with `[[ =~ ]]`/`case`, and
#      assigned with `printf -v` -- none of which execute their data. A value
#      like `PROTECT_RE=$(rm -rf x)` is inert text at every step and is rejected
#      before assignment; the command substitution is NEVER evaluated.
#   2. Refuse the whole file if it is group- or world-writable, or not owned by
#      the invoking uid. Otherwise another user (or a drop in a world-writable
#      dir) could redirect our kills.
#   3. Whitelist keys (unknown keys rejected) and validate values per type.
#      Anything that could enable command substitution or arithmetic-eval
#      injection ($( ), backticks, ${ }, ; & < > and control chars) is rejected
#      even in regex values -- defence in depth against a downstream careless
#      unquoted expansion (notably `(( $NUMERIC ))`, where an array-subscript
#      command substitution would otherwise be a real RCE vector).

# Reject values carrying shell-execution constructs, then apply a per-key type
# check. Returns 0 iff the value is safe to assign to <key>.
_rg_conf_validate() {
  local key="$1" val="$2"
  # Universally forbidden in ANY value: command substitution, parameter
  # expansion, statement separators, redirection, control/newline chars.
  case "$val" in
    *'$('* | *'`'* | *'${'* | *';'* | *'&'* | *'<'* | *'>'* | *$'\n'* | *$'\r'*)
      return 1
      ;;
  esac
  case "$key" in
    AUTO_RESUME | DRY_RUN | NOTIFY | EMACS_USR2)
      [[ $val =~ ^[01]$ ]]
      ;;
    POLL_INTERVAL | WARN_PCT | CRIT_PCT | WARN_PRESSURE | CRIT_PRESSURE | \
      WARN_STREAK | CRIT_STREAK | RESUME_STREAK | MIN_RSS_MB | GROW_MIN_MB | \
      COOLDOWN | HEARTBEAT_TICKS | KILL_BUDGET | EMACS_USR2_GRACE)
      [[ $val =~ ^[0-9]+$ ]]
      ;;
    CRIT_SIGNAL)
      [[ $val =~ ^(KILL|TERM)$ ]]
      ;;
    LOG_FILE)
      # A path: no whitespace/quotes/backslash (exec constructs already filtered),
      # and no `..` traversal component (path-traversal / symlink-clobber defense;
      # self-inflicted-only, so a simple `..` reject is sufficient).
      case "$val" in
        '' | *[[:space:]]* | *\'* | *\"* | *\\* | *..*) return 1 ;;
      esac
      return 0
      ;;
    EMACS_RE | PROTECT_RE)
      # Regex: all ERE metachars ( ( ) | ? + * . ^ $ [ ] ) are allowed; only
      # forbid whitespace, quotes, backslash (exec constructs already filtered).
      case "$val" in
        '' | *[[:space:]]* | *\'* | *\"* | *\\*) return 1 ;;
      esac
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# rg_parse_conf <file>
# Line-based WHITELIST KEY=VALUE parser. A missing file is fine (returns 0). A
# permission/ownership failure refuses the whole file (returns 1). Individual
# malformed lines, unknown keys, and invalid values are rejected (warned to
# stderr, skipped) without ever being assigned or evaluated.
rg_parse_conf() {
  local file="${1:?rg_parse_conf: file argument required}"
  [[ -e $file ]] || return 0
  if [[ ! -f $file ]]; then
    printf 'ramgate: config is not a regular file, refusing: %s\n' "$file" >&2
    return 1
  fi

  rg_adapters_init   # ensure RG_STAT is available for the perm gate
  _rg_defaults_table # ensure RG_CONF_DEFAULT (the whitelist) is populated

  # Ownership + permission gate (refuse the whole file on failure).
  local owner perm
  owner="$("$RG_STAT" -f '%u' "$file" 2> /dev/null)" || owner=""
  perm="$("$RG_STAT" -f '%Lp' "$file" 2> /dev/null)" || perm=""
  if [[ -z $owner || -z $perm ]]; then
    printf 'ramgate: cannot stat config, refusing: %s\n' "$file" >&2
    return 1
  fi
  if [[ $owner != "$EUID" ]]; then
    printf 'ramgate: config not owned by uid %s (owner %s), refusing: %s\n' \
      "$EUID" "$owner" "$file" >&2
    return 1
  fi
  # perm is octal permission bits (e.g. 644). Reject group-write (020) or
  # other-write (002): 8#022 = 18.
  if ((8#$perm & 8#022)); then
    printf 'ramgate: config is group/world-writable (mode %s), refusing: %s\n' \
      "$perm" "$file" >&2
    return 1
  fi

  local line key val
  while IFS= read -r line || [[ -n $line ]]; do
    [[ -z $line ]] && continue
    [[ $line == '#'* ]] && continue # comment
    # Must be KEY=VALUE with KEY drawn from [A-Z_]+. `.*` captures the value as
    # literal text; nothing here expands or executes it.
    if [[ ! $line =~ ^([A-Z_]+)=(.*)$ ]]; then
      printf 'ramgate: ignoring malformed config line: %s\n' "$line" >&2
      continue
    fi
    key="${BASH_REMATCH[1]}"
    val="${BASH_REMATCH[2]}"
    if [[ -z ${RG_CONF_DEFAULT[$key]+set} ]]; then
      printf 'ramgate: ignoring unknown config key: %s\n' "$key" >&2
      continue
    fi
    if ! _rg_conf_validate "$key" "$val"; then
      printf 'ramgate: rejecting unsafe value for %s\n' "$key" >&2
      continue
    fi
    printf -v "$key" '%s' "$val" # only reached AFTER validation
  done < "$file"
  return 0
}

## Precedence loader (§8): CLI > env > conf > defaults ------------------------

# rg_load_config [conf_file]
# Applies layers low -> high so the final value follows CLI > env > conf >
# defaults. The caller applies parsed CLI flags LAST, after this returns.
rg_load_config() {
  local conf="${1:-}"
  rg_adapters_init
  _rg_defaults_table

  # Snapshot env-provided overrides BEFORE seeding defaults, so they can be
  # re-applied on top of conf (env must outrank conf).
  local -A _rg_env=()
  local key
  for key in "${!RG_CONF_DEFAULT[@]}"; do
    [[ -n ${!key+set} ]] && _rg_env[$key]="${!key}"
  done

  rg_defaults                                     # 1. defaults (base)
  [[ -n $conf ]] && rg_parse_conf "$conf" || true # 2. conf overrides defaults
  for key in "${!_rg_env[@]}"; do                 # 3. env overrides conf (validated)
    # Defense-in-depth: env overrides steer the same PROCESS KILLER as the conf
    # file, so run them through the SAME whitelist validator. Without this a
    # value like WARN_PCT='x[$(cmd)]' would reach `local -i`/`(( ))` and execute
    # via arithmetic. On rejection, keep the safe default rg_defaults just set.
    if _rg_conf_validate "$key" "${_rg_env[$key]}"; then
      printf -v "$key" '%s' "${_rg_env[$key]}"
    else
      printf 'ramgate: rejecting unsafe env override for %s\n' "$key" >&2
    fi
  done
  # 4. CLI flags applied by the caller AFTER return (highest precedence).
  return 0
}

## Doctor / preflight (§15) --------------------------------------------------

# rg_doctor <xray|guard>
# Host preflight for the requested binary. Verifies the bash patch level, the
# Homebrew bash, and every required Darwin tool (gawk is optional -- warn only),
# prints the running OS build (warns, never fails, if it is not 26.x), and for
# `guard` notes whether ~/.local/bin is on PATH. Prints a tidy report and returns
# 69 (EX_UNAVAILABLE) if ANY hard dependency is missing, else 0. Colour via RG_C_*
# when fmt.bash is loaded (blank/safe otherwise).
rg_doctor() {
  local role="${1:-xray}"
  rg_adapters_init
  command -v rg_init_colors > /dev/null 2>&1 && rg_init_colors
  local ok="${RG_C_GRN:-}" warn="${RG_C_YEL:-}" bad="${RG_C_RED:-}"
  local dim="${RG_C_DIM:-}" bold="${RG_C_BOLD:-}" rst="${RG_C_RESET:-}"
  local hard_missing=0

  printf '%sramgate doctor%s -- %s preflight\n' "$bold" "$rst" "$role"

  # Bash patch level (>= 5.3.15) -- hard.
  if rg_require_bash 2> /dev/null; then
    printf '  %s[ok]%s   bash %s (>= 5.3.15)\n' "$ok" "$rst" "$BASH_VERSION"
  else
    printf '  %s[FAIL]%s bash %s (need >= 5.3.15)\n' "$bad" "$rst" "$BASH_VERSION"
    hard_missing=$((hard_missing + 1))
  fi

  # Homebrew bash present -- hard.
  if [[ -x /opt/homebrew/bin/bash ]]; then
    printf '  %s[ok]%s   /opt/homebrew/bin/bash\n' "$ok" "$rst"
  else
    printf '  %s[FAIL]%s /opt/homebrew/bin/bash not found\n' "$bad" "$rst"
    hard_missing=$((hard_missing + 1))
  fi

  # Required Darwin tools -- hard. guard additionally needs launchctl + osascript.
  local -a tools=(vm_stat sysctl ps top vmmap)
  [[ $role == guard ]] && tools+=(launchctl osascript)
  local t
  for t in "${tools[@]}"; do
    if command -v "$t" > /dev/null 2>&1; then
      printf '  %s[ok]%s   %s\n' "$ok" "$rst" "$t"
    else
      printf '  %s[FAIL]%s %s missing (required)\n' "$bad" "$rst" "$t"
      hard_missing=$((hard_missing + 1))
    fi
  done

  # gawk -- optional (region drill-downs degrade without it).
  if [[ -n ${RG_GAWK:-} ]] && command -v "$RG_GAWK" > /dev/null 2>&1; then
    printf '  %s[ok]%s   gawk (%s)\n' "$ok" "$rst" "$RG_GAWK"
  else
    printf '  %s[warn]%s gawk not found -- region drill-downs degrade\n' "$warn" "$rst"
  fi

  # OS build -- warn (never fail) if not the tested 26.x target.
  local osver
  osver="$(sw_vers -productVersion 2> /dev/null || true)"
  if [[ $osver == 26.* ]]; then
    printf '  %s[ok]%s   macOS %s\n' "$ok" "$rst" "$osver"
  else
    printf '  %s[warn]%s macOS %s (tested target: 26.x)\n' "$warn" "$rst" "${osver:-unknown}"
  fi

  # guard-only: note whether ~/.local/bin is on PATH (note, not a failure).
  if [[ $role == guard ]]; then
    case ":$PATH:" in
      *":$HOME/.local/bin:"*) printf '  %s[ok]%s   ~/.local/bin on PATH\n' "$ok" "$rst" ;;
      *) printf '  %s[note]%s ~/.local/bin not on PATH\n' "$dim" "$rst" ;;
    esac
  fi

  if ((hard_missing > 0)); then
    printf '%s%d hard dependency(ies) missing%s\n' "$bad" "$hard_missing" "$rst"
    return 69 # EX_UNAVAILABLE
  fi
  printf '%sall hard dependencies present%s\n' "$ok" "$rst"
  return 0
}
