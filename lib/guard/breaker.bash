#!/usr/bin/env bash
# breaker.bash -- ramgate guard target selection and signal state machine

# reset breaker state
# returns: 0
_guard_init_state() {
  declare -gA GUARD_PREV_RSS=()
  declare -gA GUARD_PAUSED_COMM=()
  declare -gA GUARD_PAUSED_UID=()
  declare -gA GUARD_PAUSED_START=()
  declare -gA GUARD_NUDGED_AT=()
  declare -gA GUARD_NUDGED_UID=()
  declare -gA GUARD_NUDGED_START=()
  declare -gi GUARD_WARN_COUNT=0
  declare -gi GUARD_CRIT_COUNT=0
  declare -gi GUARD_NORMAL_COUNT=0
  declare -gi GUARD_LAST_ACTION=0
  declare -gi GUARD_TICK=0
  declare -gi GUARD_KILLS_THIS_EPISODE=0
  declare -g GUARD_PREV_STATE=''
  declare -g GUARD_OWN_PGID=''
  _guard_clear_target
}

# ensure breaker globals exist
# returns: 0
_guard_ensure_state() {
  if ! declare -p GUARD_PREV_RSS > /dev/null 2>&1; then
    _guard_init_state
    return 0
  fi
  declare -p GUARD_PAUSED_COMM > /dev/null 2>&1 || declare -gA GUARD_PAUSED_COMM=()
  declare -p GUARD_PAUSED_UID > /dev/null 2>&1 || declare -gA GUARD_PAUSED_UID=()
  declare -p GUARD_PAUSED_START > /dev/null 2>&1 || declare -gA GUARD_PAUSED_START=()
  declare -p GUARD_NUDGED_AT > /dev/null 2>&1 || declare -gA GUARD_NUDGED_AT=()
  declare -p GUARD_NUDGED_UID > /dev/null 2>&1 || declare -gA GUARD_NUDGED_UID=()
  declare -p GUARD_NUDGED_START > /dev/null 2>&1 || declare -gA GUARD_NUDGED_START=()
  [[ -v GUARD_WARN_COUNT ]] || declare -gi GUARD_WARN_COUNT=0
  [[ -v GUARD_CRIT_COUNT ]] || declare -gi GUARD_CRIT_COUNT=0
  [[ -v GUARD_NORMAL_COUNT ]] || declare -gi GUARD_NORMAL_COUNT=0
  [[ -v GUARD_LAST_ACTION ]] || declare -gi GUARD_LAST_ACTION=0
  [[ -v GUARD_TICK ]] || declare -gi GUARD_TICK=0
  [[ -v GUARD_KILLS_THIS_EPISODE ]] || declare -gi GUARD_KILLS_THIS_EPISODE=0
  [[ -v GUARD_PREV_STATE ]] || declare -g GUARD_PREV_STATE=''
  [[ -v GUARD_OWN_PGID ]] || declare -g GUARD_OWN_PGID=''
}

# clear selected target globals
# returns: 0
_guard_clear_target() {
  declare -g TARGET_PID=''
  declare -g TARGET_RSS_KB='0'
  declare -g TARGET_COMM=''
  declare -g TARGET_UID=''
  declare -g TARGET_START=''
  declare -g TARGET_REASON=''
}

# build the runtime protect set
# selfname - current ram-guard executable basename
# label - launchd label
# pid - current ram-guard pid
# result: sets the GUARD_PROTECT_RE / GUARD_SELF_NAME / GUARD_LABEL / GUARD_OWN_PGID
#         globals (consumed by _guard_is_protected). Emits nothing on stdout --
#         the bins call this at top level, so a stray print would pollute output.
guard_build_protect_set() {
  local selfname=${1:-${0##*/}} label=${2:-${LABEL:-}} pid=${3:-$$} pgid=''

  _guard_ensure_state
  if [[ $pid =~ ^[0-9]+$ ]] && pgid=$(_guard_pid_pgid "$pid" 2> /dev/null); then
    GUARD_OWN_PGID=$pgid
  else
    GUARD_OWN_PGID=''
  fi
  declare -g GUARD_SELF_NAME=$selfname
  declare -g GUARD_LABEL=$label
  declare -g GUARD_PROTECT_RE
  GUARD_PROTECT_RE=$(_guard_protect_re "$selfname" "$label")
}

# classify memory pressure
# level - kern.memorystatus_vm_pressure_level
# freep - kern.memorystatus_level percentage
# stdout: NORMAL|WARN|CRIT
guard_severity() {
  local level=$1 freep=$2
  local -i warn_pct=${WARN_PCT:-20}
  local -i crit_pct=${CRIT_PCT:-10}
  local -i warn_pressure=${WARN_PRESSURE:-2}
  local -i crit_pressure=${CRIT_PRESSURE:-4}

  if ((level >= crit_pressure || freep <= crit_pct)); then
    printf 'CRIT'
  elif ((level >= warn_pressure || freep <= warn_pct)); then
    printf 'WARN'
  else
    printf 'NORMAL'
  fi
}

# select the current target
# include_paused - 1 includes already-paused pids as critical kill candidates
# sets: TARGET_PID TARGET_RSS_KB TARGET_COMM TARGET_UID TARGET_START TARGET_REASON
guard_pick_target() {
  local include_paused=${1:-0}
  local pid rss uid start comm prev delta
  local g_pid='' g_rss=0 g_comm='' g_uid='' g_start='' g_delta=0
  local s_pid='' s_rss=0 s_comm='' s_uid='' s_start=''
  local -i own_uid=${RG_UID:-$EUID}
  local -i min_rss_kb=$(((${MIN_RSS_MB:-300}) * 1024))
  declare -A seen=()

  _guard_ensure_state
  _guard_clear_target

  while IFS=$'\t' read -r pid rss uid start comm || [[ -n ${pid:-} ]]; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    [[ $rss =~ ^[0-9]+$ ]] || continue
    [[ $uid =~ ^[0-9]+$ ]] || continue
    [[ $start =~ ^[0-9]+$ ]] || continue
    [[ $uid == "$own_uid" ]] || continue
    ((pid > 1)) || continue
    seen[$pid]=1

    prev=${GUARD_PREV_RSS[$pid]:-0}
    GUARD_PREV_RSS[$pid]=$rss

    ((pid != $$)) || continue
    ((rss >= min_rss_kb)) || continue
    _guard_is_protected "$pid" "$comm" && continue
    if [[ $include_paused != 1 && -n ${GUARD_PAUSED_COMM[$pid]:-} ]]; then
      continue
    fi

    if ((prev > 0)); then
      delta=$((rss - prev))
      if ((delta >= (${GROW_MIN_MB:-20} * 1024) && delta > g_delta)); then
        g_pid=$pid
        g_rss=$rss
        g_comm=$comm
        g_uid=$uid
        g_start=$start
        g_delta=$delta
      fi
    fi

    if ((rss > s_rss)); then
      s_pid=$pid
      s_rss=$rss
      s_comm=$comm
      s_uid=$uid
      s_start=$start
    fi
  done < <(rg_ps_snapshot)

  for pid in "${!GUARD_PREV_RSS[@]}"; do
    [[ -v seen[$pid] ]] || unset 'GUARD_PREV_RSS[$pid]'
  done

  if [[ -n $g_pid ]]; then
    _guard_set_target "$g_pid" "$g_rss" "$g_comm" "$g_uid" "$g_start" "growth+${g_delta}KB"
  elif [[ -n $s_pid ]]; then
    _guard_set_target "$s_pid" "$s_rss" "$s_comm" "$s_uid" "$s_start" 'size'
  fi
}

# run one watchdog evaluation tick
# returns: 0 unless a mandatory sampler fails
guard_tick() {
  local level freep sev now swap_u swap_mb
  local -i heartbeat=${HEARTBEAT_TICKS:-30}

  _guard_ensure_state
  level=$(rg_pressure_level) || return 1
  freep=$(rg_free_pct) || return 1
  read -r swap_u _ < <(rg_swap 2> /dev/null || printf '0 0')
  swap_mb=$((${swap_u:-0} / 1048576))
  sev=$(guard_severity "$level" "$freep")
  now=$(rg_now)
  GUARD_TICK=$((GUARD_TICK + 1))

  _guard_prune_state
  _guard_log_state "$sev" "$level" "$freep" "$swap_mb" "$heartbeat"

  case $sev in
    CRIT) _guard_tick_crit "$now" ;;
    WARN) _guard_tick_warn "$now" ;;
    NORMAL) _guard_tick_normal ;;
  esac
}

# prune stale paused and nudged state
# returns: 0
_guard_prune_state() {
  local pid uid start

  _guard_ensure_state
  for pid in "${!GUARD_PAUSED_COMM[@]}"; do
    uid=${GUARD_PAUSED_UID[$pid]:-$EUID}
    start=${GUARD_PAUSED_START[$pid]:-0}
    if ! rg_proc_alive "$pid" "$uid" "$start"; then
      _guard_forget_paused "$pid"
    fi
  done

  for pid in "${!GUARD_NUDGED_AT[@]}"; do
    uid=${GUARD_NUDGED_UID[$pid]:-$EUID}
    start=${GUARD_NUDGED_START[$pid]:-0}
    if ! rg_proc_alive "$pid" "$uid" "$start"; then
      _guard_forget_nudged "$pid"
    fi
  done
}

# runtime-derived process protection predicate
# pid - candidate pid
# comm - candidate command path
# returns: 0 if protected
_guard_is_protected() {
  local pid=$1 comm=$2
  local protect_re

  ((pid == $$)) && return 0
  if _guard_same_process_group "$pid"; then
    return 0
  fi

  # guard_build_protect_set prints NOTHING -- it only sets the GUARD_PROTECT_RE
  # global. Call it as a statement, then read the global. An empty protect_re
  # must NOT be used as a regex: `[[ $comm =~ "" ]]` matches EVERYTHING, which
  # would silently protect (spare) every process. GUARD_PROTECT_RE is normally
  # set once at bin startup and is never empty (static_re is always present), so
  # this fallback is defensive; if it is still empty, treat as nothing protected.
  protect_re=${GUARD_PROTECT_RE:-}
  if [[ -z $protect_re ]]; then
    guard_build_protect_set "${0##*/}" "${LABEL:-}" "$$"
    protect_re=${GUARD_PROTECT_RE:-}
  fi
  [[ -n $protect_re ]] || return 1
  [[ $comm =~ $protect_re ]]
}

# print the runtime process protect regex
# selfname - current ram-guard executable basename
# label - launchd label
# stdout: extended regular expression
_guard_protect_re() {
  local selfname=${1:-${GUARD_SELF_NAME:-${0##*/}}}
  local label=${2:-${GUARD_LABEL:-${LABEL:-}}}
  local static_re extra_re source_name zero_name root_name
  local -a names=()
  local -i last_index

  static_re='(kernel_task|launchd|WindowServer|loginwindow|logind|Dock$|Finder$|SystemUIServer|coreaudiod|cfprefsd|mds|mds_stores|mdworker|distnoted|notifyd|opendirectoryd|securityd|sshd|/ssh$|tmux|Ghostty|iTerm|Terminal|/(z|ba)?sh$)'
  extra_re=${PROTECT_RE:-}
  zero_name=${0##*/}
  source_name=${BASH_SOURCE[0]##*/}
  last_index=$((${#BASH_SOURCE[@]} - 1))
  root_name=${BASH_SOURCE[$last_index]##*/}

  names=("$selfname" "$zero_name" "$source_name" "$root_name" 'ram-guard' 'ramgate')
  [[ -n $label ]] && names+=("$label")

  local name escaped dynamic_re=''
  for name in "${names[@]}"; do
    [[ -n $name ]] || continue
    escaped=$(_guard_regex_escape "$name")
    if [[ -z $dynamic_re ]]; then
      dynamic_re=$escaped
    else
      dynamic_re="${dynamic_re}|${escaped}"
    fi
  done

  if [[ -n $extra_re && -n $dynamic_re ]]; then
    printf '(%s|%s|%s)' "$static_re" "$extra_re" "$dynamic_re"
  elif [[ -n $extra_re ]]; then
    printf '(%s|%s)' "$static_re" "$extra_re"
  else
    printf '(%s|%s)' "$static_re" "$dynamic_re"
  fi
}

# escape literal text for use in an extended regular expression
# value - literal string
# stdout: escaped regex fragment
_guard_regex_escape() {
  local value=$1 out='' ch
  local -i i

  for ((i = 0; i < ${#value}; i++)); do
    ch=${value:i:1}
    case $ch in
      [[:alnum:]_/:-]) out+=$ch ;;
      *) out+="\\$ch" ;;
    esac
  done
  printf '%s' "$out"
}

# set selected target globals
# returns: 0
_guard_set_target() {
  declare -g TARGET_PID=$1
  declare -g TARGET_RSS_KB=$2
  declare -g TARGET_COMM=$3
  declare -g TARGET_UID=$4
  declare -g TARGET_START=$5
  declare -g TARGET_REASON=$6
}

# critical-state transition
# now - epoch seconds
# returns: 0
_guard_tick_crit() {
  local now=$1
  local -i crit_streak=${CRIT_STREAK:-1}
  local -i cooldown=${COOLDOWN:-5}

  GUARD_CRIT_COUNT=$((GUARD_CRIT_COUNT + 1))
  GUARD_WARN_COUNT=0
  GUARD_NORMAL_COUNT=0

  ((GUARD_CRIT_COUNT >= crit_streak)) || return 0
  ((now - GUARD_LAST_ACTION >= cooldown)) || return 0

  guard_pick_target 1
  [[ -n $TARGET_PID ]] || return 0

  if _guard_is_emacs "$TARGET_COMM" && [[ -z ${GUARD_NUDGED_AT[$TARGET_PID]:-} ]]; then
    _guard_usr2_target CRIT && GUARD_LAST_ACTION=$now
  else
    _guard_kill_target && GUARD_LAST_ACTION=$now
  fi
}

# warning-state transition
# now - epoch seconds
# returns: 0
_guard_tick_warn() {
  local now=$1 nudged_at
  local -i warn_streak=${WARN_STREAK:-2}
  local -i cooldown=${COOLDOWN:-5}
  local -i grace=${EMACS_USR2_GRACE:-8}

  GUARD_WARN_COUNT=$((GUARD_WARN_COUNT + 1))
  GUARD_CRIT_COUNT=0
  GUARD_NORMAL_COUNT=0

  ((GUARD_WARN_COUNT >= warn_streak)) || return 0
  ((now - GUARD_LAST_ACTION >= cooldown)) || return 0

  guard_pick_target 0
  [[ -n $TARGET_PID ]] || return 0

  if ! _guard_is_emacs "$TARGET_COMM"; then
    _guard_pause_target && GUARD_LAST_ACTION=$now
    return 0
  fi

  [[ $TARGET_REASON == growth* ]] || return 0
  nudged_at=${GUARD_NUDGED_AT[$TARGET_PID]:-0}
  if ((nudged_at == 0)); then
    _guard_usr2_target WARN && GUARD_LAST_ACTION=$now
  elif ((now - nudged_at >= grace)); then
    _guard_pause_target && GUARD_LAST_ACTION=$now
  fi
}

# normal-state transition
# returns: 0
_guard_tick_normal() {
  local -i resume_streak=${RESUME_STREAK:-5}

  GUARD_NORMAL_COUNT=$((GUARD_NORMAL_COUNT + 1))
  GUARD_WARN_COUNT=0
  GUARD_CRIT_COUNT=0
  guard_pick_target 0

  if ((${AUTO_RESUME:-1})) &&
    ((GUARD_NORMAL_COUNT >= resume_streak)) &&
    ((${#GUARD_PAUSED_COMM[@]} > 0)); then
    _guard_resume_all
  fi

  if ((GUARD_NORMAL_COUNT >= resume_streak)); then
    GUARD_NUDGED_AT=()
    GUARD_NUDGED_UID=()
    GUARD_NUDGED_START=()
    GUARD_KILLS_THIS_EPISODE=0
  fi
}

# emit state-change or heartbeat logs
# returns: 0
_guard_log_state() {
  local sev=$1 level=$2 freep=$3 swap_mb=$4 heartbeat=$5

  if [[ $sev != "$GUARD_PREV_STATE" ]]; then
    _guard_log "event=state-change" "from=${GUARD_PREV_STATE:-init}" "to=$sev" \
      "pressure=$level" "free_pct=$freep" "swap_mb=$swap_mb" \
      "paused=${#GUARD_PAUSED_COMM[@]}"
    GUARD_PREV_STATE=$sev
  elif ((heartbeat > 0 && GUARD_TICK % heartbeat == 0)); then
    _guard_log "event=heartbeat" "state=$sev" "pressure=$level" "free_pct=$freep" \
      "swap_mb=$swap_mb" "paused=${#GUARD_PAUSED_COMM[@]}"
  fi
}

# true if command is the protected emacs target
# comm - command path
# returns: 0 if emacs rescue applies
_guard_is_emacs() {
  local comm=$1
  ((${EMACS_USR2:-1})) || return 1
  [[ $comm =~ ${EMACS_RE:-(/Emacs$|/emacs$)} ]]
}

# send usr2 to selected target
# level - WARN|CRIT
# returns: signal status
_guard_usr2_target() {
  local level=${1:-WARN}
  _guard_usr2 "$TARGET_PID" "$TARGET_UID" "$TARGET_START" "$TARGET_RSS_KB" \
    "$TARGET_COMM" "$TARGET_REASON" "$level"
}

# pause selected target
# returns: signal status
_guard_pause_target() {
  _guard_pause "$TARGET_PID" "$TARGET_UID" "$TARGET_START" "$TARGET_RSS_KB" \
    "$TARGET_COMM" "$TARGET_REASON"
}

# kill selected target
# returns: signal status
_guard_kill_target() {
  _guard_kill "$TARGET_PID" "$TARGET_UID" "$TARGET_START" "$TARGET_RSS_KB" \
    "$TARGET_COMM" "$TARGET_REASON"
}

# send SIGUSR2 to a target after pid revalidation
# returns: 0 if signal sent or dry-run logged
_guard_usr2() {
  local pid=$1 uid=$2 start=$3 rss_kb=$4 comm=$5 reason=$6 level=${7:-WARN}
  local now name

  _guard_signal 'USR2' 'USR2' "$level" "$pid" "$uid" "$start" "$rss_kb" "$comm" \
    "$reason" || return 1

  now=$(rg_now)
  GUARD_NUDGED_AT[$pid]=$now
  GUARD_NUDGED_UID[$pid]=$uid
  GUARD_NUDGED_START[$pid]=$start
  name=$(_guard_basename "$comm")
  _guard_notify "Memory guard: nudged $name" \
    "Sent SIGUSR2 to pid $pid to break a runaway Emacs."
}

# send SIGSTOP to a target after pid revalidation
# returns: 0 if signal sent or dry-run logged
_guard_pause() {
  local pid=$1 uid=$2 start=$3 rss_kb=$4 comm=$5 reason=$6
  local name

  _guard_signal 'STOP' 'STOP' 'WARN' "$pid" "$uid" "$start" "$rss_kb" "$comm" \
    "$reason" || return 1

  if ((!${DRY_RUN:-0})); then
    GUARD_PAUSED_COMM[$pid]=$comm
    GUARD_PAUSED_UID[$pid]=$uid
    GUARD_PAUSED_START[$pid]=$start
    guard_ledger_add "$pid" "$start" "$comm" || true
  fi

  name=$(_guard_basename "$comm")
  _guard_notify "Memory guard: paused $name" \
    "Froze pid $pid ($((rss_kb / 1024))MB) to stop a memory leak."
}

# send critical signal to a target after pid revalidation
# returns: 0 if signal sent or dry-run logged
_guard_kill() {
  local pid=$1 uid=$2 start=$3 rss_kb=$4 comm=$5 reason=$6
  local signal=${CRIT_SIGNAL:-KILL}
  local name
  local -i budget=${KILL_BUDGET:-3}

  case $signal in
    KILL | TERM) ;;
    *)
      _guard_log "level=CRIT" "action=SKIP" "reason=invalid-signal" \
        "signal=$(_guard_log_token "$signal")" "pid=$pid"
      return 1
      ;;
  esac

  if ((!${DRY_RUN:-0} && GUARD_KILLS_THIS_EPISODE >= budget)); then
    _guard_log "level=CRIT" "action=BUDGET-EXHAUSTED" "pid=$pid" \
      "budget=$budget" "kills=$GUARD_KILLS_THIS_EPISODE"
    # _guard_kill returns 1 here, so _guard_tick_crit will NOT advance
    # GUARD_LAST_ACTION and would re-pick + re-log this on every subsequent CRIT
    # tick. Advance it ourselves so the cooldown gates the log to at most one
    # BUDGET-EXHAUSTED line per cooldown window instead of once per poll.
    GUARD_LAST_ACTION=$(rg_now)
    return 1
  fi

  if [[ -n ${GUARD_PAUSED_COMM[$pid]:-} ]]; then
    _guard_signal 'CONT' 'CONT' 'CRIT' "$pid" "$uid" "$start" "$rss_kb" "$comm" \
      'pre-kill-resume' || return 1
  fi

  _guard_signal "$signal" "$signal" 'CRIT' "$pid" "$uid" "$start" "$rss_kb" "$comm" \
    "$reason" || return 1

  if ((!${DRY_RUN:-0})); then
    GUARD_KILLS_THIS_EPISODE=$((GUARD_KILLS_THIS_EPISODE + 1))
    _guard_forget_paused "$pid"
    _guard_forget_nudged "$pid"
  fi

  name=$(_guard_basename "$comm")
  _guard_notify "Memory guard: killed $name" \
    "Killed pid $pid ($((rss_kb / 1024))MB) to prevent a system stall."
}

# resume every tracked paused target
# returns: 0
_guard_resume_all() {
  local pid uid start rss_kb comm

  for pid in "${!GUARD_PAUSED_COMM[@]}"; do
    uid=${GUARD_PAUSED_UID[$pid]:-$EUID}
    start=${GUARD_PAUSED_START[$pid]:-0}
    comm=${GUARD_PAUSED_COMM[$pid]}
    rss_kb=${GUARD_PREV_RSS[$pid]:-0}
    _guard_cont "$pid" "$uid" "$start" "$rss_kb" "$comm" 'pressure-cleared' ||
      _guard_forget_paused "$pid"
  done
}

# send SIGCONT to a target after pid revalidation
# returns: 0 if signal sent or dry-run logged
_guard_cont() {
  local pid=$1 uid=$2 start=$3 rss_kb=$4 comm=$5 reason=${6:-resume}
  local name

  _guard_signal 'CONT' 'CONT' 'NORMAL' "$pid" "$uid" "$start" "$rss_kb" "$comm" \
    "$reason" || return 1

  if ((!${DRY_RUN:-0})); then
    _guard_forget_paused "$pid"
  fi

  name=$(_guard_basename "$comm")
  _guard_notify "Memory guard: resumed $name" "Pressure cleared; un-paused pid $pid."
}

# send one signal through the injectable kill adapter after pid revalidation
# returns: 0 if sent or dry-run logged
_guard_signal() {
  local signal=$1 action=$2 level=$3 pid=$4 uid=$5 start=$6 rss_kb=$7 comm=$8 reason=$9
  local name rss_mb kill_cmd

  case $signal in
    STOP | KILL | TERM | USR2 | CONT) ;;
    *)
      _guard_log "level=$level" "action=SKIP" "reason=invalid-signal" \
        "signal=$(_guard_log_token "$signal")" "pid=$pid"
      return 1
      ;;
  esac

  if ! rg_proc_alive "$pid" "$uid" "$start"; then
    _guard_log "level=$level" "action=SKIP" "reason=pid-revalidate-failed" \
      "pid=$pid" "uid=$uid" "start=$start" "signal=$signal"
    return 1
  fi

  name=$(_guard_log_token "$(_guard_basename "$comm")")
  rss_mb=$((rss_kb / 1024))

  if ((${DRY_RUN:-0})); then
    _guard_log "level=$level" "action=DRYRUN-$action" "pid=$pid" "rss_mb=$rss_mb" \
      "reason=$(_guard_log_token "$reason")" "comm=$name"
    return 0
  fi

  if [[ -z ${RG_KILL:-} ]]; then
    _guard_log "level=$level" "action=${action}-FAILED" "pid=$pid" \
      "reason=missing-RG_KILL-adapter"
    return 1
  fi
  kill_cmd=$RG_KILL
  if "$kill_cmd" "-$signal" "$pid" 2> /dev/null; then
    _guard_log "level=$level" "action=$action" "pid=$pid" "rss_mb=$rss_mb" \
      "reason=$(_guard_log_token "$reason")" "comm=$name"
    return 0
  fi

  _guard_log "level=$level" "action=${action}-FAILED" "pid=$pid" "rss_mb=$rss_mb" \
    "comm=$name"
  return 1
}

# remove paused state for pid
# returns: 0
_guard_forget_paused() {
  local pid=$1

  unset 'GUARD_PAUSED_COMM[$pid]' 'GUARD_PAUSED_UID[$pid]' 'GUARD_PAUSED_START[$pid]'
  guard_ledger_remove "$pid" || true
}

# remove emacs nudge state for pid
# returns: 0
_guard_forget_nudged() {
  local pid=$1

  unset 'GUARD_NUDGED_AT[$pid]' 'GUARD_NUDGED_UID[$pid]' 'GUARD_NUDGED_START[$pid]'
}

# compare a pid's process group with this guard's process group
# pid - candidate pid
# returns: 0 if same process group
_guard_same_process_group() {
  local pid=$1 own_pgid pid_pgid

  own_pgid=$(_guard_own_pgid) || return 1
  pid_pgid=$(_guard_pid_pgid "$pid") || return 1
  [[ -n $own_pgid && $pid_pgid == "$own_pgid" ]]
}

# print this guard process group
# stdout: pgid
_guard_own_pgid() {
  local pgid

  if [[ -n ${GUARD_OWN_PGID:-} ]]; then
    printf '%s' "$GUARD_OWN_PGID"
    return 0
  fi

  pgid=$(_guard_pid_pgid "$$") || return 1
  GUARD_OWN_PGID=$pgid
  printf '%s' "$pgid"
}

# print a pid's process group through the ps adapter
# pid - process id
# stdout: pgid
_guard_pid_pgid() {
  local pid=$1 raw

  [[ -n ${RG_PS:-} ]] || return 1
  raw=$("$RG_PS" -o pgid= -p "$pid" 2> /dev/null) || return 1
  if [[ $raw =~ ([0-9]+) ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

# basename via parameter expansion
# path - command path
# stdout: final path component
_guard_basename() {
  local path=$1
  printf '%s' "${path##*/}"
}

# make a value safe as one flat log token
# value - raw log value
# stdout: token
_guard_log_token() {
  local value=$1
  value=${value//$'\t'/_}
  value=${value//$'\n'/_}
  value=${value// /_}
  printf '%s' "$value"
}

# log through guard_log
# returns: 0
_guard_log() {
  guard_log "$@"
}

# notify through guard_notify
# returns: 0
_guard_notify() {
  guard_notify "$@"
}
