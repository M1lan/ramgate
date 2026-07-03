#!/usr/bin/env bash
# lib/sample.bash -- kernel memory sampling (pure, shared, signal-free)
# SC2034: rg_breakdown's RG_* results are this module's OUTPUT interface,
# consumed by lib/fmt.bash / summary -- unused within this file by design.
# shellcheck disable=SC2034
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

# This library ONLY reads the kernel's own counters. It never sends a signal,
# never mutates state, and has NO pure-bash dependency on gawk/bc -- it must
# stay usable DURING an OOM episode, when fork() itself can fail. Every host
# command goes through a CONTRACT-section-4 adapter var so tests inject
# fixtures. Functions only; no top-level side effects at source time.

# Fixed-point scaler shared by the swap parser. Converts a pre-split decimal
# reading (whole, frac, unit) to bytes with explicit rounding -- no bc fork.
# nameref out; args: <out> <whole> <frac> <unit(M|G|K|other=bytes)>
_rg_swap_bytes() {
  local -n _rg_sb_out="$1"
  local whole="$2" frac="$3" unit="$4" centi mult
  frac="${frac}00"
  frac="${frac:0:2}"                              # normalise to 2 digits
  centi=$((10#${whole:-0} * 100 + 10#${frac:-0})) # value * 100 (integer)
  case "$unit" in
    G) mult=1073741824 ;;
    M) mult=1048576 ;;
    K) mult=1024 ;;
    *) mult=1 ;;
  esac
  _rg_sb_out=$(((centi * mult + 50) / 100)) # scale + round
}

# Parse vm_stat into RG_PG (raw label -> page count) and set RG_PAGESZ from
# vm_stat's own reported page size (16384 on Apple Silicon, 4096 on Intel).
# Keys are the RAW vm_stat labels, e.g. RG_PG[Pages free].
rg_sample_vm() {
  declare -gA RG_PG=()
  declare -g RG_PAGESZ=4096
  local line
  while IFS= read -r line; do
    if [[ $line =~ page\ size\ of\ ([0-9]+)\ bytes ]]; then
      RG_PAGESZ="${BASH_REMATCH[1]}"
      continue
    fi
    # "Pages free:    10394."  ->  key="Pages free"  val="10394"
    if [[ $line =~ ^([A-Za-z][^:]*):[[:space:]]+([0-9]+)\.?$ ]]; then
      RG_PG["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done < <("$RG_VMSTAT")
}

# Bytes for one vm_stat label = page count * page size.
rg_pg_bytes() { printf '%s' "$((${RG_PG[$1]:-0} * ${RG_PAGESZ:-4096}))"; }

# sysctl -n <name>, falling back to <default> (or 0) when the key is absent.
rg_sysctl_n() { "$RG_SYSCTL" -n "$1" 2> /dev/null || printf '%s' "${2:-0}"; }

# Kernel pressure level: 1 normal, 2 warn, 4 critical.
rg_pressure_level() { rg_sysctl_n kern.memorystatus_vm_pressure_level 1; }
# Kernel free-memory percentage.
rg_free_pct() { rg_sysctl_n kern.memorystatus_level 100; }

# THE single unified swap parser (replaces the two divergent copies in the
# originals). Echoes "<used_bytes> <total_bytes>". Pure-bash fixed-point: no
# bc, no gawk. macOS vm.swapusage is always "total = X.XXU  used = Y.YYU ...".
rg_swap() {
  local raw u=0 t=0
  raw="$("$RG_SYSCTL" -n vm.swapusage 2> /dev/null || true)"
  if [[ $raw =~ total\ =\ ([0-9]+)\.([0-9]+)([MGK]).*used\ =\ ([0-9]+)\.([0-9]+)([MGK]) ]]; then
    _rg_swap_bytes t "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    _rg_swap_bytes u "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
  fi
  printf '%s %s' "$u" "$t"
}

# Derived Activity-Monitor breakdown. Samples vm_stat, then sets globals:
#   RG_TOTAL RG_APP RG_WIRED RG_COMPRESSED RG_CACHED RG_FREE
#   RG_SWAP_U RG_SWAP_T RG_COMP_RATIO_X RG_COMP_RATIO_D
# Math (Activity Monitor sense): app = anon - purgeable (floor 0);
# used = app + wired + compressed (caller derives); cached = filebacked +
# purgeable; free = free + speculative. Page counts are read straight from
# RG_PG (no per-field subshell) so this stays fork-light under pressure.
rg_breakdown() {
  rg_sample_vm
  declare -g RG_TOTAL RG_USED RG_APP RG_WIRED RG_COMPRESSED RG_CACHED RG_FREE
  declare -g RG_SWAP_U RG_SWAP_T RG_COMP_RATIO_X RG_COMP_RATIO_D
  local pgsz="${RG_PAGESZ:-4096}" anon purgeable filebacked free spec stored occ
  # vm_stat labels contain spaces. shfmt parses ANY [subscript] as arithmetic and
  # rejects a literal space there, so subscript with a variable ($k) -- a single
  # arithmetic-valid token. Keys stay the raw vm_stat labels (CONTRACT §5) and the
  # lookups stay fork-light (parameter expansion, no per-field subshell).
  local k
  k='Anonymous pages' && anon=$((${RG_PG[$k]:-0} * pgsz))
  k='Pages purgeable' && purgeable=$((${RG_PG[$k]:-0} * pgsz))
  k='File-backed pages' && filebacked=$((${RG_PG[$k]:-0} * pgsz))
  k='Pages free' && free=$((${RG_PG[$k]:-0} * pgsz))
  k='Pages speculative' && spec=$((${RG_PG[$k]:-0} * pgsz))
  RG_TOTAL="$(rg_sysctl_n hw.memsize)"
  k='Pages wired down' && RG_WIRED=$((${RG_PG[$k]:-0} * pgsz))
  k='Pages occupied by compressor' && RG_COMPRESSED=$((${RG_PG[$k]:-0} * pgsz))
  RG_APP=$((anon - purgeable))
  ((RG_APP < 0)) && RG_APP=0
  # Activity-Monitor "used" = app + wired + compressed (§5/§18). Consumed by
  # bin/ram-xray and the json/tsv summary emitters.
  RG_USED=$((RG_APP + RG_WIRED + RG_COMPRESSED))
  RG_CACHED=$((filebacked + purgeable))
  RG_FREE=$((free + spec))
  read -r RG_SWAP_U RG_SWAP_T < <(rg_swap)
  # Compressor efficiency: stored / occupied (e.g. 2.4x = squeezed to 41%).
  k='Pages stored in compressor' && stored="${RG_PG[$k]:-0}"
  k='Pages occupied by compressor' && occ="${RG_PG[$k]:-0}"
  ((occ == 0)) && occ=1
  RG_COMP_RATIO_X=$((stored / occ))
  RG_COMP_RATIO_D=$(((stored % occ) * 10 / occ))
}
