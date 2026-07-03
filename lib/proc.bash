#!/usr/bin/env bash
# lib/proc.bash -- process inventory (pure, shared, signal-free)
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

# Read-only process introspection. Never signals, never mutates. Every host
# command goes through a CONTRACT-section-4 adapter var. Functions only; no
# top-level side effects at source time.
#
# START-TIME TOKEN (the anti-PID-recycle key): this macOS `ps` exposes NEITHER
# `lstartsec` NOR `etimes` (both "keyword not found" -- verified on 5.3.15 /
# darwin25), so `lstart` (a human date string, e.g. "Thu Jul  2 16:58:11 2026")
# is the only start-time field available, and the CONTRACT (section 6) mandates
# `-o lstart=`. We convert it in PURE BASH via the days-from-civil algorithm,
# treating the civil time as UTC. The result is NOT wall-clock-accurate (it
# omits the local timezone offset) but that is irrelevant: it is used ONLY as a
# stable, collision-free identity token -- the same process always maps to the
# same integer, and a recycled PID (different start time) maps to a different
# one, which is exactly what the recycle gate needs. Pure bash also avoids one
# date(1) fork PER PROCESS, which matters when this runs under memory pressure.

# Convert a `ps -o lstart=` civil time to an integer start-epoch token (as-UTC).
# nameref out; args: <out> <month-abbr> <day> <HH:MM:SS> <year>
_rg_lstart_to_epoch() {
  local -n _rg_le_out="$1"
  local mon="$2" day="$3" tm="$4" year="$5" mnum
  case "$mon" in
    Jan) mnum=1 ;; Feb) mnum=2 ;; Mar) mnum=3 ;; Apr) mnum=4 ;;
    May) mnum=5 ;; Jun) mnum=6 ;; Jul) mnum=7 ;; Aug) mnum=8 ;;
    Sep) mnum=9 ;; Oct) mnum=10 ;; Nov) mnum=11 ;; Dec) mnum=12 ;;
    *)
      _rg_le_out=0
      return 0
      ;;
  esac
  local hh="${tm%%:*}" rest="${tm#*:}" mm ss
  mm="${rest%%:*}"
  ss="${rest##*:}"
  # 10# guards against octal interpretation of zero-padded fields.
  local y=$((10#$year)) d=$((10#$day)) H=$((10#$hh)) M=$((10#$mm)) S=$((10#$ss))
  # Howard Hinnant days_from_civil: civil date -> days since 1970-01-01.
  local yy=$((mnum <= 2 ? y - 1 : y))
  local era=$(((yy >= 0 ? yy : yy - 399) / 400))
  local yoe=$((yy - era * 400))
  local mp=$((mnum + (mnum > 2 ? -3 : 9)))
  local doy=$(((153 * mp + 2) / 5 + d - 1))
  local doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
  local days=$((era * 146097 + doe - 719468))
  _rg_le_out=$((days * 86400 + H * 3600 + M * 60 + S))
}

# Fixed-point "1.4G" / "2640K" / "1234M+" -> bytes, integer math, rounded.
# nameref out; args: <out> <sized-string>
_rg_mem_to_bytes() {
  local -n _rg_mb_out="$1"
  local s="$2" num unit whole frac centi mult
  num="${s//[^0-9.]/}"   # digits + dot only
  unit="${s//[0-9.+-]/}" # the unit letter(s)
  whole="${num%%.*}"
  if [[ $num == *.* ]]; then frac="${num#*.}"; else frac=""; fi
  frac="${frac}00"
  frac="${frac:0:2}"
  centi=$((10#${whole:-0} * 100 + 10#${frac:-0}))
  case "$unit" in
    G | g) mult=1073741824 ;;
    M | m) mult=1048576 ;;
    K | k) mult=1024 ;;
    *) mult=1 ;;
  esac
  _rg_mb_out=$(((centi * mult + 50) / 100))
}

# Emit TSV: pid<TAB>rss_kb<TAB>uid<TAB>start_epoch<TAB>comm, one row per proc.
# lstart is exactly 5 whitespace fields (weekday month day HH:MM:SS year);
# comm is the rest of the line (may contain spaces). start_epoch is the
# recycle-guard token (see header). Converted fork-free via nameref.
rg_ps_snapshot() {
  local pid rss uid mon day tm year comm epoch
  while read -r pid rss uid _ mon day tm year comm; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    _rg_lstart_to_epoch epoch "$mon" "$day" "$tm" "$year"
    printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$rss" "$uid" "$epoch" "$comm"
  done < <("$RG_PS" -axo pid=,rss=,uid=,lstart=,comm=)
}

# Top N by real memory: mem_bytes<TAB>pid<TAB>cpu<TAB>comm, ranked (top's own
# -o mem ordering). `top`'s MEM column is compressed-aware, closer to real
# footprint than ps RSS. Pure-bash unit conversion; no gawk dependency.
rg_top_by_mem() {
  local n="${1:-10}" seen=0 count=0 pid mem cpu comm bytes
  while read -r pid mem cpu comm; do
    if ((!seen)); then
      [[ $pid == PID ]] && seen=1
      continue
    fi
    [[ $pid =~ ^[0-9]+$ ]] || continue
    _rg_mem_to_bytes bytes "$mem"
    printf '%s\t%s\t%s\t%s\n' "$bytes" "$pid" "$cpu" "$comm"
    ((++count >= n)) && break
  done < <("$RG_TOP" -l 1 -o mem -n "$n" -stats pid,mem,cpu,command 2> /dev/null)
}

# Exact phys_footprint in BYTES via `vmmap --summary` -- the ONLY number that
# matches Activity Monitor's "Memory" column. Empty output if not permitted
# (vmmap needs same-user or sudo). The "(peak)" line is deliberately skipped.
rg_footprint() {
  local pid="${1:?usage: rg_footprint <pid>}" line val bytes=""
  while IFS= read -r line; do
    [[ $line == 'Physical footprint:'* ]] || continue
    val="${line##* }"
    _rg_mem_to_bytes bytes "$val"
    printf '%s' "$bytes"
    return 0
  done < <("$RG_VMMAP" --summary "$pid" 2> /dev/null)
  return 0
}

# Dominant memory region of a process: "<region-name>\t<resident_bytes>".
# The RESIDENT extraction is PRESERVED EXACTLY from ram-xray's why-cmd: vmmap
# region rows are NOT pre-sorted and REGION TYPE contains spaces, so the numeric
# block is located FROM THE RIGHT -- the rightmost pure integer is REGION COUNT,
# the 7 unit columns precede it (VIRTUAL RESIDENT DIRTY ...), so RESIDENT is
# field (count_idx - 6) and the name is fields 1..(count_idx - 8). Only the
# emit format is changed (TAB + bytes) per CONTRACT section 6. Empty if gawk is
# unavailable or vmmap is not permitted.
rg_dominant_region() {
  local pid="${1:?usage: rg_dominant_region <pid>}"
  [[ -n ${RG_GAWK:-} ]] || return 0
  "$RG_VMMAP" --summary "$pid" 2> /dev/null |
    "$RG_GAWK" '
        function tobytes(s,   v,u){
          u=s; gsub(/[0-9.]/,"",u); v=s; gsub(/[^0-9.]/,"",v)
          if(u=="G")return v*1073741824; if(u=="M")return v*1048576
          if(u=="K")return v*1024; return v+0 }
        /REGION TYPE/ {hdr=1; next}
        /^=======/ && hdr==1 {hdr=2; next}
        hdr==2 && $1 ~ /^TOTAL/ {exit}
        hdr==2 {
          ri=0; for(i=NF;i>=1;i--) if($i ~ /^[0-9]+$/){ri=i; break}
          if(ri<9) next
          resb=tobytes($(ri-6))
          name=""; for(i=1;i<=ri-8;i++) name=name (i>1?" ":"") $i
          if(resb>best){best=resb; bestn=name}
        }
        END{ if(bestn!="") printf "%s\t%d", bestn, best }
      '
}

# Anti-PID-recycle gate: returns 0 iff pid exists AND its uid matches AND its
# start-epoch token matches. The guard calls this immediately before EVERY
# signal so a recycled PID (same number, different process) is never hit.
rg_proc_alive() {
  local pid="${1:?}" expect_uid="${2:?}" expect_start="${3:?}"
  local out uid mon day tm year epoch
  out="$("$RG_PS" -o uid=,lstart= -p "$pid" 2> /dev/null)" || return 1
  [[ -n $out ]] || return 1
  read -r uid _ mon day tm year _ <<< "$out"
  [[ $uid == "$expect_uid" ]] || return 1
  _rg_lstart_to_epoch epoch "$mon" "$day" "$tm" "$year"
  [[ $epoch == "$expect_start" ]] || return 1
  return 0
}

## Per-PID drill-down helpers (ported from ram-xray's cmd_pid, signal-free) ---

# rg_pid_exists <pid> -- return 0 iff the process exists. Uses `ps -p` (read-only)
# via the RG_PS adapter; never signals, so it is safe in the inert ram-xray.
rg_pid_exists() {
  local pid="${1:?usage: rg_pid_exists <pid>}"
  "$RG_PS" -p "$pid" -o pid= > /dev/null 2>&1
}

# rg_pid_comm <pid> -- echo the process command (ps -o comm=). Empty if gone.
rg_pid_comm() {
  local pid="${1:?usage: rg_pid_comm <pid>}"
  "$RG_PS" -p "$pid" -o comm= 2> /dev/null
}

# rg_pid_ps_line <pid> -- the human ps view line contrasting RSS/VSZ/%mem:
#   "  ps RSS x MB (overcounts shared)   VSZ y GB   %mem z"
# Ported from cmd_pid but rendered in PURE bash (rss/vsz are KB) -- no gawk, so it
# stays usable under pressure. Prints nothing if the process is gone.
rg_pid_ps_line() {
  local pid="${1:?usage: rg_pid_ps_line <pid>}" rss vsz pmem
  read -r rss vsz pmem < <("$RG_PS" -p "$pid" -o rss=,vsz=,pmem= 2> /dev/null)
  [[ ${rss:-} =~ ^[0-9]+$ ]] || return 0
  [[ ${vsz:-} =~ ^[0-9]+$ ]] || vsz=0
  printf '  ps RSS %d.%d MB (overcounts shared)   VSZ %d.%d GB   %%mem %s\n' \
    "$((rss / 1024))" "$(((rss % 1024) * 10 / 1024))" \
    "$((vsz / 1048576))" "$(((vsz % 1048576) * 10 / 1048576))" \
    "${pmem:-0}"
}

# rg_pid_regions <pid> -- the vmmap --summary region table (header + heaviest
# rows). Ported VERBATIM from cmd_pid's gawk block (unchanged extraction). Needs
# gawk; degrades to a note when RG_GAWK is empty or vmmap is not permitted.
rg_pid_regions() {
  local pid="${1:?usage: rg_pid_regions <pid>}"
  if [[ -z ${RG_GAWK:-} ]]; then
    printf '  (vmmap region table needs gawk)\n'
    return 0
  fi
  "$RG_VMMAP" --summary "$pid" 2> /dev/null |
    "$RG_GAWK" '
        /REGION TYPE/ {hdr=1}
        hdr && /SWAPPED/ {print "  " $0; next}
        hdr==2 && $1 ~ /^TOTAL/ {print "  " $0; exit}
        hdr==2 && NF>=4 && $0 !~ /^=/ {print "  " $0; c++; if(c>=18) exit}
        /^=======/ && hdr {hdr=2}
      ' ||
    printf '  (vmmap unavailable for this pid)\n'
}

## Aggregate helpers (feed `why`, `top`, `app`) ------------------------------

# rg_top_pids <n> -- emit TSV `pid<TAB>comm` for the top N processes by memory.
# Feeds `why`. Reuses rg_top_by_mem (top's compressed-aware -o mem ranking) and
# projects out the pid + comm columns; no extra host fork.
rg_top_pids() {
  local n="${1:-3}" mem pid cpu comm
  while IFS=$'\t' read -r mem pid cpu comm; do
    [[ -n $pid ]] || continue
    printf '%s\t%s\n' "$pid" "$comm"
  done < <(rg_top_by_mem "$n")
}

# rg_app_match <regex> -- every process whose comm matches <regex>, one per line
# as `  <human rss>  pid <pid> <comm>`, then a total-RSS line across N matches.
# Ported from cmd_app; sources procs from rg_ps_snapshot (pid rss uid epoch comm).
# RSS overcounts shared pages (upper bound). Returns 1 if nothing matched.
rg_app_match() {
  local re="${1:?usage: rg_app_match <regex>}"
  local found=0 total_kb=0 pid rss uid epoch comm
  printf '%sProcesses matching /%s/:%s\n' "${RG_C_BOLD:-}" "$re" "${RG_C_RESET:-}"
  while IFS=$'\t' read -r pid rss uid epoch comm; do
    [[ $rss =~ ^[0-9]+$ ]] || continue
    [[ $comm =~ $re ]] || continue
    found=$((found + 1))
    total_kb=$((total_kb + rss))
    printf '  %s%9s%s  pid %-7s %s\n' \
      "${RG_C_CYA:-}" "$(rg_human "$((rss * 1024))")" "${RG_C_RESET:-}" "$pid" "$comm"
  done < <(rg_ps_snapshot)
  if ((found == 0)); then
    printf '  (no match)\n'
    return 1
  fi
  printf '  %s-----%s\n' "${RG_C_DIM:-}" "${RG_C_RESET:-}"
  printf '  %s%9s%s  total RSS across %d process(es) %s(shared mem overcounted)%s\n' \
    "${RG_C_BOLD:-}" "$(rg_human "$((total_kb * 1024))")" "${RG_C_RESET:-}" \
    "$found" "${RG_C_DIM:-}" "${RG_C_RESET:-}"
}

# rg_app_grouped <n> -- RSS summed by LEAF command name, top N, as
# `  <human>  <name>`. Ported from cmd_top's ps|gawk grouping but done in PURE
# bash (assoc array) + `sort -rn`/`head` -- no gawk dependency. RSS (KB) sums
# double-count shared pages, so this is a per-app UPPER bound (spots browsers).
rg_app_grouped() {
  local n="${1:-12}" pid rss uid epoch comm name key
  local -A totals=()
  while IFS=$'\t' read -r pid rss uid epoch comm; do
    [[ $rss =~ ^[0-9]+$ ]] || continue
    name="${comm##*/}"
    [[ -n $name ]] || continue
    totals["$name"]=$((${totals["$name"]:-0} + rss))
  done < <(rg_ps_snapshot)
  for key in "${!totals[@]}"; do
    printf '%s\t%s\n' "${totals[$key]}" "$key"
  done | sort -rn | head -n "$n" | while IFS=$'\t' read -r rss name; do
    printf '  %s%9s%s  %s\n' \
      "${RG_C_CYA:-}" "$(rg_human "$((rss * 1024))")" "${RG_C_RESET:-}" "$name"
  done
}
