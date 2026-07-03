#!/usr/bin/env bash
# hooklib.bash -- shared helpers for the prek-driven git hooks in ramgate.
# Sourced, never executed. Plain-text output only (no ANSI colour, house rule).
#
# Design contract:
#   * Hooks are guardrails, not the build: fast, deterministic, no heavy analysis.
#     The real "compile" is `bash -n` + `shellcheck` (see `just check`/`just lint`).
#   * Interactive prompts read from /dev/tty (stdin is taken by git/prek) and time
#     out after HOOKS_TIMEOUT seconds. A timeout ABORTS the git action -- it is a
#     soft nudge to improve the message/name, never a silent pass.
#   * Non-interactive contexts (no tty: CI, agent commits) never block on style:
#     deterministic auto-fixes are applied silently, AI is skipped.
#   * AI never fires on its own. It lives behind an explicit [a] choice and needs
#     `just hooks-ai-setup` to have written config/hooks/ai.env first.

# --- locate repo + config ---------------------------------------------------

hook::repo_root() { git rev-parse --show-toplevel 2> /dev/null || pwd; }

hook::load_config() {
  local root
  root="$(hook::repo_root)"
  # shellcheck disable=SC1091
  [[ -f "$root/config/hooks/hooks.env" ]] && source "$root/config/hooks/hooks.env"
  : "${HOOKS_TIMEOUT:=4}"
  : "${HOOKS_BLOCKING:=1}"
  : "${HOOKS_LLM_ASSIST:=1}"
  : "${HOOKS_SUBJECT_MAXLEN:=72}"
  : "${HOOKS_CC_TYPES:=feat fix docs style refactor perf test build ci chore revert}"
  : "${HOOKS_CC_SCOPES:=xray guard sample proc fmt config breaker ledger agent log docs harness}"
  : "${HOOKS_BRANCH_TYPES:=feat fix docs style refactor perf test build ci chore revert release hotfix}"
  : "${HOOKS_BRANCH_PROTECTED:=main master develop}"
}

# --- plain-text output (no colour) ------------------------------------------

hook::say() { printf '%s\n' "$*"; }
hook::info() { printf '[%s] %s\n' "${HOOK_NAME:-hook}" "$*"; }
hook::warn() { printf '[%s] WARN: %s\n' "${HOOK_NAME:-hook}" "$*"; }
hook::ok() { printf '[%s] OK: %s\n' "${HOOK_NAME:-hook}" "$*"; }
hook::rule() { printf -- '---- %s ----\n' "$*"; }

# Install a uniform interrupt trap so Ctrl-C always aborts cleanly (a `|| true`
# plus a loop can otherwise swallow SIGINT into an unkillable loop).
hook::trap_interrupts() {
  trap 'printf "\n[%s] interrupted -- aborting, no changes made\n" "${HOOK_NAME:-hook}"; exit 130' INT TERM HUP
}

# --- interactivity ----------------------------------------------------------

# True only when a controlling terminal can actually be opened (not just present).
hook::interactive() { (: < /dev/tty) 2> /dev/null; }

# hook::ask "<prompt>" "<allowed-chars>"
#   echoes the lowercased single-char answer on stdout.
#   return 0 = got an answer . 3 = timed out . 2 = non-interactive
hook::ask() {
  local prompt="$1" allowed="${2:-yn}" reply
  hook::interactive || return 2
  printf '%s [%s] (%ss -> abort): ' "$prompt" "$allowed" "$HOOKS_TIMEOUT" > /dev/tty
  if IFS= read -r -t "$HOOKS_TIMEOUT" reply < /dev/tty; then
    printf '\n' > /dev/tty
    printf '%s' "${reply:0:1}" | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  printf '\n' > /dev/tty
  return 3
}

# --- AI assist --------------------------------------------------------------

hook::ai_cmd() {
  local root
  root="$(hook::repo_root)"
  # shellcheck disable=SC1091
  [[ -f "$root/config/hooks/ai.env" ]] && source "$root/config/hooks/ai.env"
  [[ -n "${HOOKS_AI_CMD:-}" ]] && printf '%s' "$HOOKS_AI_CMD"
}

hook::ai_available() { [[ "${HOOKS_LLM_ASSIST:-1}" == 1 && -n "$(hook::ai_cmd)" ]]; }

# hook::ai_run "<instruction>" <<<"<payload>"  -> prints de-slopped model output.
# HOOKS_AI_CMD is trusted config (written by the wizard); executed by design.
hook::ai_run() {
  local instruction="$1" cmd payload out
  cmd="$(hook::ai_cmd)" || return 1
  [[ -n "$cmd" ]] || return 1
  payload="$(cat)"
  # shellcheck disable=SC2294
  out="$(printf '%s\n\n%s\n' "$instruction" "$payload" | eval "$cmd" 2> /dev/null)" || return 1
  printf '%s' "$out" | hook::strip_slop
}

# --- slop / co-author / emoji stripping -------------------------------------
# Zero AI-slop, zero co-author trailers, zero emoji may reach a commit message.

hook::strip_slop() {
  # 1) drop co-author / generated-by trailers
  # 2) drop common LLM filler lines
  # 3) strip emoji / pictographs (per-character, never a whole line for one emoji)
  rg -v -i \
    -e '^[[:space:]]*co-authored-by:' \
    -e '^[[:space:]]*(generated|created|written) (with|by) ' \
    -e '^[[:space:]]*(here(.s| is)|sure[,!]|certainly[,!]|i have|i.ve|as an ai|in summary|note that|feel free)' \
    2> /dev/null |
    perl -CSD -pe 's/[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{2190}-\x{21FF}\x{2B00}-\x{2BFF}\x{FE0F}]//g' 2> /dev/null |
    sed -e 's/[[:space:]]*$//'
}

# --- conventional commits ---------------------------------------------------

hook::cc_type_alt() { printf '%s' "${HOOKS_CC_TYPES// /|}"; }

hook::cc_valid() {
  local subject="$1" alt
  alt="$(hook::cc_type_alt)"
  [[ "$subject" =~ ^($alt)(\([a-z0-9._-]+\))?!?:\ .+ ]]
}

# Deterministic best-effort normalisation of a Conventional-Commits subject line.
# Echoes the fixed subject; never invents a type it cannot justify.
hook::cc_autofix_subject() {
  local s="$1" type scope bang rest
  # Split "<type>(scope)?!?: subject". No match (e.g. no colon) => leave untouched:
  # we never invent a type we cannot justify.
  if [[ "$s" =~ ^([A-Za-z]+)(\([^\)]*\))?(!)?:[[:space:]]*(.*)$ ]]; then
    type="${BASH_REMATCH[1],,}" # lowercase the type token
    scope="${BASH_REMATCH[2]}"
    bang="${BASH_REMATCH[3]}"
    rest="${BASH_REMATCH[4]%.}" # strip a trailing period from the subject
    case "$type" in             # canonicalise common synonyms
      feature) type=feat ;;
      bug | bugfix) type=fix ;;
      doc) type=docs ;;
      chores) type=chore ;;
    esac
    s="${type}${scope}${bang}: ${rest}"
  fi
  printf '%s' "$s"
}
