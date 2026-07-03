#!/usr/bin/env bash
# doctor.bash -- dependency audit for the Justfile harness AND the ramgate project.
#
#   doctor.bash             full table; exit 1 if a REQUIRED dep is missing
#   doctor.bash --summary   one-line toolbelt status (used by the info screen)
#   doctor.bash --factoid   single most important fact, frugal wording (splash)
#   doctor.bash --install   interactive multi-select install TUI for missing deps
#
# This audits the DEVELOPER HARNESS deps (what you need to build/test ramgate),
# not ramgate's macOS runtime tools (vm_stat/vmmap/sysctl/...) -- those are
# checked by `ram-xray doctor` / `ram-guard doctor` per docs/CONTRACT.md §15.
#
# Pure GNU Bash 5.3+. Colors: terminal defaults via tput only.

# shellcheck source=lib.bash disable=SC2154
source "$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)/lib.bash"

# ── dependency catalogue ─────────────────────────────────────────────────
# tool -> homebrew formula (only where the tool name differs from the formula).
# NOTE: hyphenated keys MUST be single-quoted in BOTH declaration and lookup --
# shfmt parses the `-` as arithmetic minus inside a subscript and silently
# mangles `[foo-bar]` into `[foo - bar]` (house-style gotcha #24). None of the
# keys below are hyphenated today; the quoting convention is kept ready.
declare -A PKG=(
  [rg]=ripgrep
  [fd]=fd
  [gawk]=gawk
  [gdate]=coreutils
  [shfmt]=shfmt
  [shellcheck]=shellcheck
)
# tool -> one-line purpose
declare -A WHY=(
  [bash]='helper runtime + ramgate interpreter (GNU >= 5.3.15)'
  [just]='the task runner itself'
  [git]='version control + splash facts'
  [gawk]='GNU awk for fact extraction / pure-bash fallbacks'
  [shellcheck]='lint bin + lib + helpers (the build-less compile)'
  [shfmt]='format shell (just fmt: -i 2 -ci -sr)'
  [gum]='TUI: menu, splash, install picker'
  [fzf]='TUI: fzf power launcher'
  [jq]='recipe inventory for the launchers'
  [fd]='file finder for facts (never find)'
  [rg]='search engine (never grep)'
  [bat]='syntax-highlighted recipe previews'
  [figlet]='banner art on the info splash'
  [gdate]='GNU date for timestamps'
  [prek]='pre-commit hook runner'
  [gitleaks]='secret scanning'
)

REQUIRED=(bash just git gawk)
RECOMMENDED=(shellcheck shfmt gum fzf jq fd rg bat)
OPTIONAL=(figlet gdate prek gitleaks)

# ── version probing ──────────────────────────────────────────────────────
# version_of <tool> -- short version string, best effort. EYEBALL every cell in
# real `just doctor` output: shims and multi-line --version formats lie silently
# (house-style gotchas #26/#27). shellcheck prints "version: X" on line 2, so a
# generic `head -1` yields EMPTY -- special-cased below.
version_of() {
  case "$1" in
    bash) printf '%s' "${BASH_VERSION%%(*}" ;;
    just) just --version 2> /dev/null | gawk '{print $2}' ;;
    gum) gum --version 2> /dev/null | gawk '{print $3}' ;;
    fzf) fzf --version 2> /dev/null | gawk '{print $1}' ;;
    shfmt) shfmt --version 2> /dev/null | rg -No '[0-9]+\.[0-9][0-9.]*' | head -1 || true ;;
    shellcheck) shellcheck --version 2> /dev/null | rg -No 'version: ([0-9.]+)' -r '$1' || true ;;
    figlet) figlet -v 2>&1 | rg -No 'Version: ([0-9.]+)' -r '$1' | head -1 || true ;;
    *) "$1" --version 2> /dev/null | head -1 | rg -No '[0-9]+\.[0-9][0-9.]*' | head -1 || true ;;
  esac
}

# check_tool <tool> -> sets CHECK_STATE (ok|missing|outdated) + CHECK_NOTE.
# The bash row enforces the FULL patch-level guard: ramgate requires >= 5.3.15
# (docs/CONTRACT.md §1), not merely 5.3.
check_tool() {
  local t="$1"
  CHECK_STATE=ok CHECK_NOTE=''
  if ! has "$t"; then
    CHECK_STATE=missing
    return
  fi
  case "$t" in
    bash)
      ((BASH_VERSINFO[0] > 5 || (\
      BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] > 3) || (\
      BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] == 3 && BASH_VERSINFO[2] >= 15))) ||
        {
          CHECK_STATE=outdated
          CHECK_NOTE="need GNU >= 5.3.15, got $BASH_VERSION"
        }
      ;;
  esac
}

# ── project-level checks (beyond CLI tools) ──────────────────────────────
project_rows=() # "state|name|note"
project_checks() {
  project_rows=()
  local state note
  # homebrew bash: ramgate's launcher re-execs into it (macOS ships bash 3.2).
  if [[ -x /opt/homebrew/bin/bash ]]; then
    local bv
    bv=$(/opt/homebrew/bin/bash -c 'printf %s "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}.${BASH_VERSINFO[2]}"' 2> /dev/null)
    state=ok
    note="/opt/homebrew/bin/bash ($bv) -- re-exec target"
  else
    state=missing
    note='/opt/homebrew/bin/bash absent -- brew install bash'
  fi
  project_rows+=("$state|homebrew bash|$note")
  # macOS build: WARN (never error) if not the tested 26.x target.
  local osv
  osv=$(fact_osver)
  if [[ $osv == 26.* ]]; then
    state=ok
    note="macOS $osv (tested target)"
  else
    state=warn
    note="macOS $osv -- ramgate is tuned for 26.x, YMMV"
  fi
  project_rows+=("$state|macos build|$note")
  # ~/.local/bin on PATH: `just install` symlinks the two bins there.
  # SC2088: the tilde is literal DISPLAY text in the note, never a path to expand.
  # shellcheck disable=SC2088
  if [[ -n "$(fact_localbin_ok)" ]]; then
    state=ok
    note='~/.local/bin on PATH (installed bins resolve)'
  else
    state=warn
    note='~/.local/bin not on PATH -- add it before `just install`'
  fi
  project_rows+=("$state|install path|$note")
  # binaries present (do NOT execute them -- facts are file-parse only).
  local bins_ok=1 b
  for b in ram-xray ram-guard; do [[ -f "$REPO_ROOT/bin/$b" ]] || bins_ok=0; done
  if ((bins_ok)); then
    state=ok
    note='bin/ram-xray + bin/ram-guard present'
  else
    state=missing
    note='a ramgate binary is missing from bin/'
  fi
  project_rows+=("$state|binaries|$note")
}

# ── missing collection ───────────────────────────────────────────────────
collect_missing() {
  MISSING_REQ=() MISSING_OPT=()
  local t
  for t in "${REQUIRED[@]}"; do
    check_tool "$t"
    [[ $CHECK_STATE == ok ]] || MISSING_REQ+=("$t")
  done
  for t in "${RECOMMENDED[@]}" "${OPTIONAL[@]}"; do
    check_tool "$t"
    [[ $CHECK_STATE == ok ]] || MISSING_OPT+=("$t")
  done
}

# ── output: summary (one line, splash toolbelt) ──────────────────────────
cmd_summary() {
  collect_missing
  local total=$((${#REQUIRED[@]} + ${#RECOMMENDED[@]} + ${#OPTIONAL[@]}))
  local bad=$((${#MISSING_REQ[@]} + ${#MISSING_OPT[@]}))
  local ok=$((total - bad))
  if ((bad == 0)); then
    printf '%s %d/%d tools ready\n' "$I_OK" "$ok" "$total"
  else
    local -a all_missing=("${MISSING_REQ[@]+"${MISSING_REQ[@]}"}" "${MISSING_OPT[@]+"${MISSING_OPT[@]}"}")
    printf '%s %d/%d ready -- missing: %s\n' "$I_WARN" "$ok" "$total" "${all_missing[*]}"
  fi
  ((${#MISSING_REQ[@]} == 0))
}

# ── output: factoid (ONE frugal line for the splash exit) ────────────────
# priority: missing required > missing optional > not macOS 26 > no PATH > dirty > tip
cmd_factoid() {
  collect_missing
  if ((${#MISSING_REQ[@]} > 0)); then
    printf 'missing required tools: %s -- just doctor-install\n' "${MISSING_REQ[*]}"
    return 0
  fi
  if ((${#MISSING_OPT[@]} > 0)); then
    printf 'missing optional tools: %s -- just doctor-install\n' "${MISSING_OPT[*]}"
    return 0
  fi
  local osv
  osv=$(fact_osver)
  if [[ $osv != 26.* ]]; then
    printf 'macOS %s -- ramgate is tuned for 26.x; behavior may differ\n' "$osv"
    return 0
  fi
  if [[ -z "$(fact_localbin_ok)" ]]; then
    # SC2088: literal display text, not a path -- tilde must stay verbatim.
    # shellcheck disable=SC2088
    printf '~/.local/bin not on PATH -- add it so `just install` bins resolve\n'
    return 0
  fi
  local dirty
  dirty=$(fact_dirty)
  if ((dirty > 0)); then
    printf '%s uncommitted file(s) on %s\n' "$dirty" "$(fact_branch)"
    return 0
  fi
  printf 'all green -- `just ci` is the exact gate (check + lint + test)\n'
}

# ── output: full table ───────────────────────────────────────────────────
print_row() { # <state> <name> <version> <note>
  local mark color
  case "$1" in
    ok) mark="$I_OK" color="$C_GREEN" ;;
    warn) mark="$I_WARN" color="$C_YELLOW" ;;
    outdated) mark="$I_WARN" color="$C_YELLOW" ;;
    *) mark="$I_MISS" color="$C_RED" ;;
  esac
  printf '  %s%s%s  %-16s %-12s %s%s%s\n' \
    "$color" "$mark" "$C_RESET" "$2" "${3:-}" "$C_MUTED" "${4:-}" "$C_RESET"
}

print_tier() { # <title> <tools...>
  local title="$1"
  shift
  printf '\n%s%s-- %s --%s\n' "$C_BOLD" "$C_HEAD" "$title" "$C_RESET"
  local t v
  for t in "$@"; do
    check_tool "$t"
    v=''
    [[ $CHECK_STATE != missing ]] && v=$(version_of "$t")
    case "$CHECK_STATE" in
      ok) print_row ok "$t" "$v" "${WHY[$t]:-}" ;;
      outdated) print_row outdated "$t" "$v" "$CHECK_NOTE" ;;
      missing) print_row missing "$t" '' "${WHY[$t]:-} -- brew install ${PKG[$t]:-$t}" ;;
    esac
  done
}

cmd_table() {
  printf '%s%s%s doctor %s-- %s (developer harness)%s\n' \
    "$C_BOLD" "$C_ACCENT" "$I_GEAR" "$C_RESET$C_MUTED" "$PKGNAME" "$C_RESET"
  print_tier 'required' "${REQUIRED[@]}"
  print_tier 'recommended' "${RECOMMENDED[@]}"
  print_tier 'optional' "${OPTIONAL[@]}"

  printf '\n%s%s-- project --%s\n' "$C_BOLD" "$C_HEAD" "$C_RESET"
  project_checks
  local row state name note
  for row in "${project_rows[@]}"; do
    IFS='|' read -r state name note <<< "$row"
    print_row "$state" "$name" '' "$note"
  done

  collect_missing
  printf '\n'
  if ((${#MISSING_REQ[@]} > 0)); then
    printf '%s%s required deps missing:%s %s\n' "$C_RED" "$I_MISS" "$C_RESET" "${MISSING_REQ[*]}"
    printf '%sfix interactively:%s just doctor-install\n' "$C_MUTED" "$C_RESET"
    return 1
  fi
  if ((${#MISSING_OPT[@]} > 0)); then
    printf '%s%s optional deps missing:%s %s  %s(just doctor-install)%s\n' \
      "$C_YELLOW" "$I_WARN" "$C_RESET" "${MISSING_OPT[*]}" "$C_MUTED" "$C_RESET"
  else
    printf '%s%s all dependencies satisfied%s\n' "$C_GREEN" "$I_OK" "$C_RESET"
  fi
  return 0
}

# ── output: interactive install TUI ──────────────────────────────────────
cmd_install() {
  trap 'exit 130' INT TERM HUP
  has brew || die 'error: homebrew not found -- install from https://brew.sh first'
  collect_missing
  local -a missing=("${MISSING_REQ[@]+"${MISSING_REQ[@]}"}" "${MISSING_OPT[@]+"${MISSING_OPT[@]}"}")
  if ((${#missing[@]} == 0)); then
    printf '%s%s nothing to install -- everything is already there%s\n' "$C_GREEN" "$I_OK" "$C_RESET"
    return 0
  fi

  # label each candidate "tool -- formula -- why" (NO separators / headers!)
  local -a items=() chosen=()
  local t
  for t in "${missing[@]}"; do
    items+=("$(printf '%-14s brew:%-14s %s' "$t" "${PKG[$t]:-$t}" "${WHY[$t]:-}")")
  done

  if has gum && [[ -t 0 && -t 1 ]]; then
    local sel rc=0
    sel=$(printf '%s\n' "${items[@]}" |
      gum choose --no-limit --selected='*' \
        --header="$I_BOX select deps to install (space toggles, enter confirms)" \
        --cursor='> ') || rc=$?
    ((rc != 0)) && {
      printf 'aborted\n'
      return 130
    }
    [[ -z "$sel" ]] && {
      printf 'nothing selected\n'
      return 0
    }
    mapfile -t chosen <<< "$sel"
  else
    # non-interactive / no gum: print the one-liner and bail
    local -a formulas=()
    for t in "${missing[@]}"; do formulas+=("${PKG[$t]:-$t}"); done
    printf 'run:\n  brew install %s\n' "${formulas[*]}"
    return 0
  fi

  local line tool formula failed=0
  for line in "${chosen[@]}"; do
    tool=${line%% *}
    formula=${PKG[$tool]:-$tool}
    printf '%s%s installing %s%s (%s)\n' "$C_ACCENT" "$I_BOX" "$C_RESET$C_BOLD" "$formula$C_RESET" "$tool"
    if has gum; then
      gum spin --spinner=dot --title="brew install $formula" -- brew install "$formula" || failed=1
    else
      brew install "$formula" || failed=1
    fi
  done
  ((failed)) && {
    printf '%s%s some installs failed -- re-run: just doctor%s\n' "$C_RED" "$I_MISS" "$C_RESET"
    return 1
  }
  printf '%s%s done -- re-checking:%s\n' "$C_GREEN" "$I_OK" "$C_RESET"
  cmd_table
}

# ── dispatch (only when executed directly, not when sourced) ─────────────
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --summary) cmd_summary ;;
    --factoid) cmd_factoid ;;
    --install) cmd_install ;;
    '') cmd_table ;;
    *) die "usage: doctor.bash [--summary|--factoid|--install]" ;;
  esac
fi
