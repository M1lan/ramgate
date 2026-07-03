#!/usr/bin/env bash
# llm-run.bash -- local-first LLM stdin->stdout filter for the git hooks and ai-* recipes.
#
# Reads a prompt on stdin, writes the model's completion to stdout. The backend and its
# model/endpoint come from config/hooks/ai.env (written by `just hooks-ai-setup`). Exits
# non-zero on any failure so callers fall back to deterministic behaviour and a flaky
# model can never block a commit.
#
# Backends, local-first by design (a costly frontier coding harness is the last resort):
#   mlx          OpenAI-compatible endpoint -- llama-swap / mlx_lm.server. Preferred.
#   ollama       native `ollama run <model>` on :11434 (generative models only).
#   llamacpp     fully offline `llama-cli -m <gguf>`.
#   gemini-nano  Chrome's built-in Gemini Nano via a Deno CDP driver (optional; the driver
#                script is NOT shipped with ramgate -- this backend no-ops cleanly if absent).
#   harness      a frontier coding CLI (omc/claude/...). Only when explicitly chosen.
#
# HOOKS_AI_FALLBACK_BACKEND (optional): a second backend tried only if the primary fails.
#
# Usage (set by the wizard; the hooks just `eval "$HOOKS_AI_CMD"`):
#   HOOKS_AI_CMD='bash scripts/hooks/lib/llm-run.bash'         # backend from ai.env
#   HOOKS_AI_CMD='bash scripts/hooks/lib/llm-run.bash ollama'  # one-off backend override

set -uo pipefail

root="$(git rev-parse --show-toplevel 2> /dev/null || pwd)"
# shellcheck disable=SC1091
[[ -f "$root/config/hooks/ai.env" ]] && source "$root/config/hooks/ai.env"

backend="${1:-${HOOKS_AI_BACKEND:-mlx}}"

: "${HOOKS_AI_ENDPOINT:=http://127.0.0.1:8080/v1}"
: "${HOOKS_AI_MODEL:=${HOME}/qwen36-mlx}"
: "${HOOKS_AI_OLLAMA_MODEL:=qwen3-coder:latest}"
: "${HOOKS_AI_MAX_TOKENS:=512}"
: "${HOOKS_AI_TIMEOUT:=90}"
[[ "$HOOKS_AI_MAX_TOKENS" =~ ^[0-9]+$ ]] || HOOKS_AI_MAX_TOKENS=512
[[ "$HOOKS_AI_TIMEOUT" =~ ^[0-9]+$ ]] || HOOKS_AI_TIMEOUT=90

prompt="$(cat)"
[[ -n "$prompt" ]] || exit 1

# OpenAI-compatible chat completion. $1 endpoint base (.../v1), $2 model id.
llm::openai() {
  local endpoint="$1" model="$2" body
  command -v jq > /dev/null 2>&1 || return 1
  body="$(jq -n --arg m "$model" --arg p "$prompt" --argjson mt "$HOOKS_AI_MAX_TOKENS" \
    '{model:$m, messages:[{role:"user",content:$p}], max_tokens:$mt, temperature:0, stream:false}')" || return 1
  curl -fsS --max-time "$HOOKS_AI_TIMEOUT" "${endpoint%/}/chat/completions" \
    -H 'Content-Type: application/json' -d "$body" 2> /dev/null |
    jq -r '.choices[0].message.content // empty' 2> /dev/null
}

# Wall-clock bound for the non-curl backends; a no-op if no timeout binary exists.
llm::to() {
  if command -v timeout > /dev/null 2>&1; then
    timeout "$HOOKS_AI_TIMEOUT" "$@"
  elif command -v gtimeout > /dev/null 2>&1; then
    gtimeout "$HOOKS_AI_TIMEOUT" "$@"
  else
    "$@"
  fi
}

# Run one backend; prints its completion on success, returns non-zero on failure.
llm::dispatch() {
  local backend="$1" out=""
  case "$backend" in
    mlx | openai)
      out="$(llm::openai "$HOOKS_AI_ENDPOINT" "$HOOKS_AI_MODEL")" || return 1
      ;;
    ollama)
      command -v ollama > /dev/null 2>&1 || return 1
      case "$HOOKS_AI_OLLAMA_MODEL" in
        *embed*) return 1 ;; # embedding models cannot generate text
      esac
      out="$(printf '%s' "$prompt" | llm::to ollama run "$HOOKS_AI_OLLAMA_MODEL" 2> /dev/null)" || return 1
      ;;
    llamacpp)
      command -v llama-cli > /dev/null 2>&1 || return 1
      [[ -n "${HOOKS_AI_GGUF:-}" && -f "${HOOKS_AI_GGUF:-}" ]] || return 1
      out="$(llm::to llama-cli -m "$HOOKS_AI_GGUF" -p "$prompt" -n "$HOOKS_AI_MAX_TOKENS" \
        -no-cnv --no-display-prompt 2> /dev/null)" || return 1
      ;;
    gemini-nano | nano)
      # Optional local last-resort. The Deno CDP driver is not shipped with ramgate;
      # this backend fails cleanly (missing script -> non-zero) so callers fall through.
      command -v deno > /dev/null 2>&1 || return 1
      [[ -f "$root/scripts/hooks/lib/gemini-nano.ts" ]] || return 1
      export CHROME_BIN CHROME_CDP NANO_PROFILE NANO_ALLOW_DOWNLOAD
      out="$(printf '%s' "$prompt" | llm::to deno run --allow-net --allow-run --allow-read --allow-write --allow-env \
        "$root/scripts/hooks/lib/gemini-nano.ts" 2> /dev/null)" || return 1
      ;;
    harness)
      [[ -n "${HOOKS_AI_HARNESS_CMD:-}" ]] || return 1
      out="$(printf '%s' "$prompt" | llm::to bash -c "$HOOKS_AI_HARNESS_CMD" 2> /dev/null)" || return 1
      ;;
    *)
      return 1
      ;;
  esac
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

# Primary backend first; on failure fall through to the optional last-resort
# fallback. Never escalates to a costly frontier harness unless explicitly configured.
llm::dispatch "$backend" && exit 0
fallback="${HOOKS_AI_FALLBACK_BACKEND:-}"
[[ -n "$fallback" && "$fallback" != "$backend" ]] && { llm::dispatch "$fallback" && exit 0; }
exit 1
