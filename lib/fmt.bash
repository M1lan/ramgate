#!/usr/bin/env bash
# lib/fmt.bash -- pure formatting: human sizes, TTY bars, colours, machine emit.
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

# This library is PURE and shared (§0/§7): it never sends a signal, never mutates
# system state, never loops, holds no daemon state. It defines functions only --
# no sampling, no I/O, no colour assignment at source time (§2). Colours are set
# lazily by rg_init_colors so sourcing has zero side effects.

## Colours -------------------------------------------------------------------

# Populate the RG_C_* palette. ANSI is enabled ONLY when stdout is a real TTY AND
# we are not in a machine-output mode: --json / --tsv streams and --no-color must
# carry NO escape sequences (§7). Every colour consumer reads "${RG_C_*:-}" so the
# functions stay safe even if this was never called (set -u friendly).
rg_init_colors() {
  # The RG_C_* palette is public API consumed by sibling render modules (the
  # bins' summary/top output), not only by this file -- hence "unused" here.
  # shellcheck disable=SC2034
  if [[ -t 1 && -z ${RG_JSON:-} && -z ${RG_TSV:-} && -z ${RG_NO_COLOR:-} ]]; then
    RG_C_RESET=$'\033[0m'
    RG_C_DIM=$'\033[2m'
    RG_C_BOLD=$'\033[1m'
    RG_C_GRN=$'\033[32m'
    RG_C_YEL=$'\033[33m'
    RG_C_RED=$'\033[31m'
    RG_C_CYA=$'\033[36m'
  else
    RG_C_RESET="" RG_C_DIM="" RG_C_BOLD=""
    RG_C_GRN="" RG_C_YEL="" RG_C_RED="" RG_C_CYA=""
  fi
}

## Human-readable sizes ------------------------------------------------------

# Bytes -> "1.4 GB" style, one decimal, integer math only (bash is 64-bit; a
# 24GB reading fits comfortably). No bc, no gawk -- safe to call during an OOM
# episode when fork can fail.
rg_human() {
  local b="${1:-0}"
  if ((b >= 1073741824)); then
    printf '%d.%d GB' "$((b / 1073741824))" "$(((b % 1073741824) * 10 / 1073741824))"
  elif ((b >= 1048576)); then
    printf '%d.%d MB' "$((b / 1048576))" "$(((b % 1048576) * 10 / 1048576))"
  elif ((b >= 1024)); then
    printf '%d KB' "$((b / 1024))"
  else
    printf '%d B' "$b"
  fi
}

## Proportional bar (TTY / human mode only) ----------------------------------

# rg_bar <total> <used> <cached> <free> [width]
# Three running segments (used=red, cached=yellow, free=green) filling `width`
# cells. Machine modes carry NO bars (§7): refuse to emit into a data stream so
# --json/--tsv output can never be corrupted.
rg_bar() {
  [[ -n ${RG_JSON:-} || -n ${RG_TSV:-} ]] && return 0
  # `free` is part of the contract signature (§7); the free segment is drawn as
  # the remainder (width-u-c) so the three segments always exactly fill `width`.
  # shellcheck disable=SC2034
  local total="${1:-0}" used="${2:-0}" cached="${3:-0}" free="${4:-0}" width="${5:-46}"
  ((total > 0)) || total=1
  local u=$((used * width / total))
  local c=$((cached * width / total))
  local f=$((width - u - c))
  ((u < 0)) && u=0
  ((c < 0)) && c=0
  ((f < 0)) && f=0
  local bar="" i
  for ((i = 0; i < u; i++)); do bar+="█"; done
  printf '%s%s' "${RG_C_RED:-}" "$bar"
  bar=""
  for ((i = 0; i < c; i++)); do bar+="█"; done
  printf '%s%s' "${RG_C_YEL:-}" "$bar"
  bar=""
  for ((i = 0; i < f; i++)); do bar+="░"; done
  printf '%s%s%s' "${RG_C_GRN:-}" "$bar" "${RG_C_RESET:-}"
}

## Machine emit (colourless, stable, field-delimited) ------------------------
# stdout = data, stderr = info/logs (§7/§14). These carry NO ANSI and NO bars.

# Escape a string for embedding inside a JSON double-quoted scalar.
_rg_json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

# The stable summary field set (order is the machine contract). Every value is
# an RG_* breakdown global set by rg_breakdown (§5/§18); `:-0` keeps this
# set -u-safe even if a caller emits before sampling.
_rg_summary_pairs() {
  printf '%s\n' \
    "total ${RG_TOTAL:-0}" "used ${RG_USED:-0}" "app ${RG_APP:-0}" \
    "wired ${RG_WIRED:-0}" "compressed ${RG_COMPRESSED:-0}" \
    "cached ${RG_CACHED:-0}" "free ${RG_FREE:-0}" \
    "swap_used ${RG_SWAP_U:-0}" "swap_total ${RG_SWAP_T:-0}" \
    "comp_ratio_x ${RG_COMP_RATIO_X:-0}" "comp_ratio_d ${RG_COMP_RATIO_D:-0}" \
    "pagesz ${RG_PAGESZ:-4096}"
}

# rg_emit_json_summary
# Emit ONE stable JSON object of the RG_* breakdown globals on stdout. Integer
# values are emitted bare (numbers); anything else is an escaped JSON string.
# Colourless by design (§7). Reads globals; takes no arguments.
rg_emit_json_summary() {
  local out="{" first=1 key val
  while read -r key val; do
    [[ -n $key ]] || continue
    ((first)) || out+=","
    first=0
    if [[ $val =~ ^-?[0-9]+$ ]]; then
      out+="\"$(_rg_json_escape "$key")\":$val"
    else
      out+="\"$(_rg_json_escape "$key")\":\"$(_rg_json_escape "$val")\""
    fi
  done < <(_rg_summary_pairs)
  out+="}"
  printf '%s\n' "$out"
}

# rg_emit_tsv_summary
# Emit ONE TAB-delimited record of the RG_* breakdown globals on stdout, in the
# same stable field order as the JSON keys. Colourless; takes no arguments.
rg_emit_tsv_summary() {
  local out="" key val first=1
  while read -r key val; do
    [[ -n $key ]] || continue
    ((first)) || out+=$'\t'
    first=0
    out+="$val"
  done < <(_rg_summary_pairs)
  printf '%s\n' "$out"
}

# Info/diagnostic line -> stderr (never pollutes the stdout data stream).
rg_info() { printf '%s\n' "$*" >&2; }
