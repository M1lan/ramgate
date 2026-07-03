#!/usr/bin/env bash
# ai-task.bash -- task-level wrapper around the local-first LLM engine (llm-run.bash)
# for the `just ai-review` and `just ai-test` recipes.
#
# llm-run.bash is the execution engine: it owns the per-call timeout, the
# primary->fallback backend chain, and "empty output => non-zero". This script
# adds the task-level hardening the recipes need:
#
#   circuit-breaker  a fast (~3s) reachability probe of the configured backend
#                    (and its fallback) BEFORE a large prompt is built, so a dead
#                    endpoint fails in seconds with guidance instead of stalling.
#   capability tier  the active backend+model is classed nano/small/large/frontier;
#                    the input payload is capped to that tier's context budget and
#                    tiny models are asked for terser output.
#   retry            one retry on an empty/failed response (handles a cold MLX
#                    model swap); bounded to one, never an endless loop.
#   provenance       a one-line stderr note (backend / tier / input size) so the
#                    user knows what produced the answer.
#   resolution       ai-review picks a non-empty diff range (base -> upstream ->
#                    HEAD~1 -> staged -> working tree) and reports which; ai-test
#                    targets a bash lib/bin file and proposes test stubs.
#
# ramgate is pure GNU Bash: the reviewer is a senior-Bash reviewer (shellcheck /
# shfmt / bash -n mindset), and ai-test proposes pure-bash test stubs -- there is
# no compiler and no coverage tool, so no JaCoCo equivalent exists here.
#
# Usage:
#   scripts/hooks/lib/ai-task.bash review [base-ref]     # default base origin/main
#   scripts/hooks/lib/ai-task.bash test  [file|name]     # default lib/proc.bash
#   scripts/hooks/lib/ai-task.bash tier  [backend]       # introspection
#   scripts/hooks/lib/ai-task.bash preflight             # print first reachable backend

set -uo pipefail

cd "$(git rev-parse --show-toplevel 2> /dev/null || pwd)" || exit 1
# shellcheck disable=SC1091
[[ -f config/hooks/ai.env ]] && source config/hooks/ai.env

: "${HOOKS_AI_ENDPOINT:=http://127.0.0.1:8080/v1}"
: "${HOOKS_AI_BACKEND:=mlx}"
PROBE_TIMEOUT="${AI_TASK_PROBE_TIMEOUT:-3}"

# --- capability tiers -------------------------------------------------------

# Classify a backend (+ its model) into a capability tier.
ai_task::tier() {
  local b="$1" m ml
  case "$b" in
    gemini-nano | nano) echo nano && return 0 ;;
    harness) echo frontier && return 0 ;;
    ollama) m="${HOOKS_AI_OLLAMA_MODEL:-}" ;;
    llamacpp) m="${HOOKS_AI_GGUF:-}" ;;
    *) m="${HOOKS_AI_MODEL:-}" ;;
  esac
  ml="${m,,}"
  case "$ml" in
    *0.6b* | *-1b* | *1.5b* | *-2b* | *-3b* | *mini* | *small* | *phi* | *tiny* | *gemma2:2b*)
      echo small
      ;;
    *) echo large ;;
  esac
}

# Max input bytes for a tier (the model's usable context budget for our payload).
ai_task::cap() {
  case "$1" in
    nano) echo 4096 ;;
    small) echo 16384 ;;
    large) echo 81920 ;;
    frontier) echo 307200 ;;
    *) echo 16384 ;;
  esac
}

# A terseness nudge appended to the instruction for tiny models (they ramble).
ai_task::focus() {
  case "$1" in
    nano) echo "Be extremely brief: only the single most important item." ;;
    small) echo "Be brief: at most the 3 most important items." ;;
    *) echo "" ;;
  esac
}

# --- circuit breaker --------------------------------------------------------

# Fast reachability probe for one backend. Returns 0 if it looks usable.
ai_task::reachable() {
  case "$1" in
    mlx | openai)
      curl -fsS --max-time "$PROBE_TIMEOUT" "${HOOKS_AI_ENDPOINT%/}/models" > /dev/null 2>&1
      ;;
    ollama)
      command -v ollama > /dev/null 2>&1 || return 1
      case "${HOOKS_AI_OLLAMA_MODEL:-}" in *embed*) return 1 ;; esac
      curl -fsS --max-time "$PROBE_TIMEOUT" "http://127.0.0.1:11434/api/tags" > /dev/null 2>&1
      ;;
    llamacpp)
      command -v llama-cli > /dev/null 2>&1 && [[ -f "${HOOKS_AI_GGUF:-/nonexistent}" ]]
      ;;
    gemini-nano | nano)
      command -v deno > /dev/null 2>&1 && [[ -x "${CHROME_BIN:-/nonexistent}" ]]
      ;;
    harness)
      [[ -n "${HOOKS_AI_HARNESS_CMD:-}" ]]
      ;;
    *) return 1 ;;
  esac
}

# Echo the first reachable backend among {primary, fallback}; non-zero if none.
ai_task::pick_backend() {
  local primary="${HOOKS_AI_BACKEND:-mlx}" fb="${HOOKS_AI_FALLBACK_BACKEND:-}"
  if ai_task::reachable "$primary"; then
    echo "$primary"
    return 0
  fi
  if [[ -n "$fb" && "$fb" != "$primary" ]] && ai_task::reachable "$fb"; then
    echo "$fb"
    return 0
  fi
  return 1
}

# --- run --------------------------------------------------------------------

# Compose instruction + (capped) stdin payload, run via llm-run.bash on the first
# reachable backend, retry once, strip co-author lines, report provenance.
ai_task::run() {
  local instruction="$1" backend tier cap payload bytes focus full out rc attempt
  backend="$(ai_task::pick_backend)" || {
    printf 'ai: no reachable LLM backend (primary=%s, fallback=%s).\n' \
      "${HOOKS_AI_BACKEND:-mlx}" "${HOOKS_AI_FALLBACK_BACKEND:-none}" >&2
    printf '    diagnose with "just ai-doctor"; (re)configure with "just hooks-ai-setup".\n' >&2
    return 3
  }
  tier="$(ai_task::tier "$backend")"
  cap="$(ai_task::cap "$tier")"
  payload="$(cat)"
  bytes=${#payload}
  if ((bytes > cap)); then
    payload="${payload:0:cap}"$'\n'"[...truncated $((bytes - cap)) bytes to fit the '$tier' model context...]"
  fi
  focus="$(ai_task::focus "$tier")"
  full="$instruction"
  [[ -n "$focus" ]] && full="$full $focus"
  full="$full"$'\n\n'"$payload"
  printf 'ai: backend=%s tier=%s input=%dB%s\n' \
    "$backend" "$tier" "${#payload}" "$( ((bytes > cap)) && echo ' (capped)')" >&2
  for attempt in 1 2; do
    # shellcheck disable=SC2294
    out="$(printf '%s' "$full" | eval "${HOOKS_AI_CMD} $backend" 2> /dev/null)"
    rc=$?
    if [[ $rc -eq 0 && -n "$out" ]]; then
      printf '%s\n' "$out" | rg -v -i '^co-authored-by:'
      return 0
    fi
    [[ $attempt -eq 1 ]] && {
      printf 'ai: empty/failed response -- retrying once...\n' >&2
      sleep 1
    }
  done
  printf 'ai: the model returned nothing after a retry (backend=%s). Try "just ai-doctor".\n' "$backend" >&2
  return 4
}

# --- subcommands ------------------------------------------------------------

ai_task::cmd_review() {
  local base="${1:-origin/main}" up r diff="" used="" stat
  local -a ranges=("$base...HEAD")
  up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2> /dev/null || true)"
  [[ -n "$up" ]] && ranges+=("$up...HEAD")
  ranges+=("HEAD~1...HEAD")
  for r in "${ranges[@]}"; do
    git rev-parse "${r%%...*}" > /dev/null 2>&1 || continue
    diff="$(git --no-pager diff "$r" 2> /dev/null)"
    [[ -n "$diff" ]] && {
      used="$r"
      break
    }
  done
  if [[ -z "$used" ]]; then
    diff="$(git --no-pager diff --staged 2> /dev/null)"
    [[ -n "$diff" ]] && used="staged"
  fi
  if [[ -z "$used" ]]; then
    diff="$(git --no-pager diff 2> /dev/null)"
    [[ -n "$diff" ]] && used="working-tree"
  fi
  if [[ -z "$used" ]]; then
    echo "ai-review: nothing to review (clean tree; no diff vs '$base', upstream, or HEAD~1)."
    return 0
  fi
  case "$used" in
    staged) stat="$(git --no-pager diff --staged --stat 2> /dev/null)" ;;
    working-tree) stat="$(git --no-pager diff --stat 2> /dev/null)" ;;
    *) stat="$(git --no-pager diff "$used" --stat 2> /dev/null)" ;;
  esac
  printf 'ai-review: reviewing %s\n' "$used" >&2
  {
    printf 'Changed files:\n%s\n\n' "$stat"
    printf '%s' "$diff"
  } | ai_task::run "Review as a senior GNU Bash 5.3+ reviewer: correctness, quoting/word-splitting, set -e/pipefail pitfalls, shellcheck findings, unsafe subshells, and -- for ramgate specifically -- the two-binary safety invariant (ram-xray must never signal or source lib/guard). Cite file and hunk. Terse, no preamble, no praise-padding."
}

ai_task::cmd_test() {
  local target="${1:-}" src
  [[ -z "$target" ]] && target="lib/proc.bash"
  if [[ -f "$target" ]]; then
    src="$target"
  else
    src="$(fd -t f "$target" bin lib 2> /dev/null | head -1)"
  fi
  if [[ -z "$src" || ! -f "$src" ]]; then
    printf 'ai-test: no file matching %s under bin/ or lib/. Available:\n' "$target" >&2
    fd -t f . bin lib 2> /dev/null | sed 's/^/  - /' >&2
    return 1
  fi
  {
    printf 'Target file: %s\n\nSource:\n' "$src"
    cat "$src"
  } | ai_task::run "Propose missing pure-Bash test cases (edge + failure paths) for this ramgate file, matching the test/*.bash harness style (a function per case; assert on exit status and captured stdout/stderr; no external test framework). Output test-function stubs only (descriptive name + Arrange/Act/Assert comments), no preamble, no co-author lines, no emoji."
}

# --- entrypoint -------------------------------------------------------------

main() {
  local sub="${1:-}"
  case "$sub" in
    tier)
      shift
      ai_task::tier "${1:-${HOOKS_AI_BACKEND:-mlx}}"
      return 0
      ;;
    preflight)
      ai_task::pick_backend || {
        echo "no reachable backend" >&2
        return 3
      }
      return 0
      ;;
  esac
  if [[ -z "${HOOKS_AI_CMD:-}" ]]; then
    echo "AI not configured -- run:  just hooks-ai-setup" >&2
    return 2
  fi
  case "$sub" in
    review)
      shift
      ai_task::cmd_review "$@"
      ;;
    test)
      shift
      ai_task::cmd_test "$@"
      ;;
    *)
      echo "usage: ai-task.bash {review [base] | test [file] | tier [backend] | preflight}" >&2
      return 64
      ;;
  esac
}

main "$@"
