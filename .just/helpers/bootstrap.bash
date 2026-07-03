#!/usr/bin/env bash
# bootstrap.bash -- `make` lands here: install everything, show it live.
#
#   bootstrap.bash             orchestrator: bg installer + live splash + welcome
#   bootstrap.bash --install   the installer itself (runs in the background)
#   bootstrap.bash --welcome   re-render the welcome screen from the last stats
#
# Flow:
#   1. spawn `--install` in the background, logging to .just/state/bootstrap.log
#   2. foreground: a 2 Hz "loading" splash whose DOMINANT panel is the live
#      install log; side rail shows identity, a steps checklist, and hotkeys.
#      NO timeout -- the splash stays until the installer finishes.
#      hotkeys: q abort install · s shell now (installer keeps running) ·
#               l follow the full log in less
#   3. success -> one-time ASCII-art welcome screen (stats + what-next),
#      4.2 s countdown: m menu · f fzf · any other key shell.
#   4. failure -> red summary + log tail, exit 1.
#
# ramgate is BUILD-LESS: the "install" is homebrew tooling + a source sanity
# gate (`bash -n` on every file, then shellcheck) -- there is no compiler.
#
# SCREEN DISCIPLINE (Iron Rule 5): the ONLY in-place redraw in the whole
# harness is this live splash. It uses the ALTERNATE SCREEN BUFFER (tput smcup
# on entry, tput rmcup on EVERY exit incl. traps) + `tput cup 0 0` to home the
# cursor between frames -- exactly like less/fzf/vim. The alt screen fully
# RESTORES the primary screen + scrollback on exit; it never wipes it. The
# welcome + failure screens print INLINE on the primary screen (no redraw).
#
# Pure GNU Bash 5.3+. Colors: terminal defaults via tput only; boxes via gum.

# shellcheck source=lib.bash disable=SC2154
source "$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)/lib.bash"
cd "$REPO_ROOT" || exit 1

LOG="$STATE_DIR/bootstrap.log"
STEPS="$STATE_DIR/bootstrap.steps"     # one line per step: name|state|detail
STATS="$STATE_DIR/bootstrap.stats"     # key=value lines
STATUS="$STATE_DIR/bootstrap.status"   # running | ok | fail

# ── alternate-screen helpers (the ONLY in-place redraw path) ─────────────
_ALT=0
enter_alt() {  # enter once; idempotent
    (( _ALT )) && return 0
    is_tty || return 0
    tput smcup 2>/dev/null; tput civis 2>/dev/null
    _ALT=1
}
leave_alt() {  # restore primary screen + scrollback on EVERY exit path
    (( _ALT )) || { is_tty && tput cnorm 2>/dev/null; return 0; }
    is_tty && { tput rmcup 2>/dev/null; tput cnorm 2>/dev/null; }
    _ALT=0
}

# ── step bookkeeping (installer side) ────────────────────────────────────
step_set() {  # <name> <state> <detail>
    local name="$1" state="$2" detail="${3:-}" line out=''
    while IFS= read -r line; do
        [[ "$line" == "$name|"* ]] || out+="$line"$'\n'
    done < "$STEPS" 2>/dev/null
    printf '%s%s|%s|%s\n' "$out" "$name" "$state" "$detail" > "$STEPS"
}

# ── the installer (background process) ───────────────────────────────────
cmd_install() {
    local t0=$EPOCHSECONDS installed=() failed=()
    # doctor.bash provides PKG/WHY/REQUIRED/RECOMMENDED/OPTIONAL + check_tool
    # shellcheck source=doctor.bash
    source "$LIB_DIR/doctor.bash"

    step_set brew-tools running 'scanning'
    if ! has brew; then
        printf 'FATAL: homebrew not found -- install from https://brew.sh first\n'
        step_set brew-tools fail 'homebrew missing'
        printf 'fail\n' > "$STATUS"; return 1
    fi
    # UI tools first so the splash can upgrade itself mid-install
    local -a order=(just gum jq fzf bat fd rg gawk shellcheck shfmt
                    figlet gdate prek gitleaks git)
    local t n=0 missing=()
    for t in "${order[@]}"; do
        check_tool "$t"; [[ $CHECK_STATE == ok ]] || missing+=("$t")
    done
    local total=${#missing[@]}
    if (( total == 0 )); then
        printf 'tools: all %d already installed -- nothing to do\n' "${#order[@]}"
        step_set brew-tools 'done' 'all present'
    else
        for t in "${missing[@]}"; do
            (( ++n ))
            step_set brew-tools running "$t ($n/$total)"
            printf '>> brew install %s  [%d/%d]\n' "${PKG[$t]:-$t}" "$n" "$total"
            if brew install "${PKG[$t]:-$t}" 2>&1; then
                installed+=("$t")
            else
                failed+=("$t"); printf '!! %s failed\n' "$t"
            fi
        done
        step_set brew-tools 'done' "${#installed[@]} installed, ${#failed[@]} failed"
    fi

    # BUILD-LESS "compile" step 1: bash -n every source file.
    step_set syntax running 'bash -n bin + lib'
    printf '>> bash -n over bin/* + lib/**.bash + .just/helpers/*.bash\n'
    local f syn_ok=1
    for f in "$REPO_ROOT"/bin/* "$REPO_ROOT"/lib/*.bash "$REPO_ROOT"/lib/guard/*.bash "$LIB_DIR"/*.bash; do
        [[ -f $f ]] || continue
        if bash -n "$f" 2>&1; then
            printf 'ok   %s\n' "${f#"$REPO_ROOT"/}"
        else
            syn_ok=0; printf '!! syntax error: %s\n' "${f#"$REPO_ROOT"/}"
        fi
    done
    if (( syn_ok )); then step_set syntax 'done' 'all files parse'
    else step_set syntax fail 'a file failed bash -n'; failed+=(syntax); fi

    # BUILD-LESS "compile" step 2: shellcheck (best-effort; may be absent).
    step_set lint running 'shellcheck'
    if has shellcheck; then
        if shellcheck -x -S warning -P "$LIB_DIR" "$LIB_DIR"/*.bash 2>&1; then
            step_set lint 'done' 'helpers clean'
        else
            step_set lint fail 'shellcheck warnings'
        fi
    else
        printf 'lint: shellcheck not present -- skipped\n'
        step_set lint 'done' 'skipped (no shellcheck)'
    fi

    {
        printf 'duration=%s\n'   "$(( EPOCHSECONDS - t0 ))"
        printf 'installed=%s\n'  "${installed[*]:-}"
        printf 'failed=%s\n'     "${failed[*]:-}"
        printf 'version=%s\n'    "$(fact_version)"
        printf 'bins=%s\n'       "$(fact_bins)"
        printf 'shared=%s\n'     "$(fact_shared_libs)"
        printf 'guard=%s\n'      "$(fact_guard_libs)"
        printf 'tests=%s\n'      "$(fact_tests)"
        printf 'loc=%s\n'        "$(fact_loc)"
        printf 'toolbelt=%s\n'   "$("$LIB_DIR/doctor.bash" --summary 2>/dev/null || true)"
        printf 'finished=%s\n'   "$(has gdate && gdate '+%Y-%m-%d %H:%M:%S' || date '+%Y-%m-%d %H:%M:%S')"
    } > "$STATS"

    if (( ${#failed[@]} > 0 )); then printf 'fail\n' > "$STATUS"; return 1; fi
    printf 'ok\n' > "$STATUS"
}

# ── splash rendering (orchestrator side) ─────────────────────────────────
SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

panel_identity() {
    printf '%s  BOOTSTRAP\n\n' "$I_BOX"
    printf '%s\n' "$PKGNAME"
    printf 'v%s · %s bins\n' "$(fact_version)" "$(fact_bins)"
    printf 'one make -- zero to ready\n'
}

panel_steps() {  # <tick>
    local tick="$1" name state detail mark
    printf '%s  STEPS\n\n' "$I_GEAR"
    while IFS='|' read -r name state detail; do
        case "$state" in
            done)    mark="${C_GREEN}✓${C_RESET}" ;;
            fail)    mark="${C_RED}✗${C_RESET}" ;;
            running) mark="${C_CYAN}${SPIN[tick % ${#SPIN[@]}]}${C_RESET}" ;;
            *)       mark="${C_DIM}·${C_RESET}" ;;
        esac
        printf '%b %-12s %s\n' "$mark" "$name" "$detail"
    done < "$STEPS" 2>/dev/null
}

panel_hotkeys() {
    printf '%sq abort · s shell · l log%s\n' "$C_DIM" "$C_RESET"
}

# log_body <height> <width> -- label + separator + tinted tail of the log
log_body() {
    local h="$1" w="$2" line bar
    printf -v bar '%*s' $(( w - 4 )) ''; bar=${bar// /─}
    printf '%s%s install log — live%s\n' "$C_BOLD" "$I_DOC" "$C_RESET"
    printf '%s%s%s\n' "$C_DIM" "$bar" "$C_RESET"
    while IFS= read -r line; do
        case "$line" in
            *ERROR*|*error:*|*Error*|*FAIL*|*'!!'*|*FATAL*)
                printf '%s%s%s\n' "$C_RED" "$line" "$C_RESET" ;;
            *'ok '*|*installed*|*Pouring*|*'>>'*)
                printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET" ;;
            *)  printf '%s%s%s\n' "$C_DIM" "$line" "$C_RESET" ;;
        esac
    done < <(tail -n $(( h - 3 )) "$LOG" 2>/dev/null)
}

render_splash() {  # <tick> -- homes the cursor on the alt screen; NEVER wipes
    local tick="$1" cols lines_ logh
    cols=$(term_cols); lines_=$(term_lines)
    is_tty && tput cup 0 0 2>/dev/null
    if (( cols >= 130 )); then               # wide: rail left + DOMINANT log right
        local railw=32
        local logw=$(( cols - railw - 8 ))
        logh=$(( lines_ - 5 )); (( logh < 6 )) && logh=6
        local rail log
        rail=$({ panel_identity; printf '\n'; panel_steps "$tick"; printf '\n'; panel_hotkeys; } \
            | gum style --border rounded --border-foreground "$G_ACCENT" --padding "0 1" --width $(( railw - 2 )))
        log=$(log_body "$logh" "$logw" \
            | gum style --border thick --border-foreground "$G_WARN" --padding "0 1" \
                  --width "$logw" --height "$logh")
        gum join --horizontal --align top "$rail" "$log"
    else                                     # medium/portrait: strip + DOMINANT log below
        logh=$(( lines_ - 16 )); (( logh < 5 )) && logh=5
        { panel_identity; printf '\n'; panel_steps "$tick"; printf '\n'; panel_hotkeys; } \
            | gum style --border rounded --border-foreground "$G_ACCENT" --padding "0 1" --width $(( cols - 6 ))
        log_body "$logh" $(( cols - 6 )) \
            | gum style --border thick --border-foreground "$G_WARN" --padding "0 1" \
                  --width $(( cols - 6 )) --height "$logh"
    fi
    printf '  %s%s installing -- the screen stays until everything is ready%s' \
        "$C_DIM" "${SPIN[tick % ${#SPIN[@]}]}" "$C_RESET"
    is_tty && tput el 2>/dev/null   # tidy the tail of the status line (one line only)
    printf '\n'
}

render_plain() {  # minimal output until gum/just exist (or non-tty)
    local last
    last=$(tail -n 1 "$LOG" 2>/dev/null)
    printf '\r%-*s' "$(term_cols)" "bootstrap: ${last:0:100}"
}

# ── welcome screen (one-time, after a successful (re)install) ────────────
# Prints INLINE on the primary screen (we have already left the alt buffer).
welcome_art() {
    local -a art=(
        ' ___ __ _ _ __  __ _ __ _| |_ ___ '
        '| _/ _` |  ` |/ _` / _` |  _/ -_)'
        '|_| \__,_|_|_|_|\__, \__,_|\__\___|'
        '                |___/             '
    )
    local sub='m a c O S   m e m o r y   x - r a y   +   g u a r d'
    local inner=71 line pad
    center() {  # <text> <color>
        local text="$1" color="$2"
        pad=$(( (inner - ${#text}) / 2 ))
        printf '  %s║%s%*s%s%s%s%*s%s║%s\n' "$C_DIM" "$C_RESET" \
            "$pad" '' "$color" "$text" "$C_RESET" "$(( inner - pad - ${#text} ))" '' \
            "$C_DIM" "$C_RESET"
    }
    local bar; printf -v bar '%*s' "$inner" ''; bar=${bar// /═}
    printf '  %s╔%s╗%s\n' "$C_DIM" "$bar" "$C_RESET"
    center '' ''
    local i=0
    for line in "${art[@]}"; do
        if (( i == 1 )); then center "$line" "$C_BOLD$C_CYAN"; else center "$line" "$C_CYAN"; fi
        (( i++ )) || true
    done
    center '' ''
    center "$sub" "$C_BOLD"
    center '' ''
    printf '  %s╚%s╝%s\n' "$C_DIM" "$bar" "$C_RESET"
}

read_stats() {  # populates ST[] from the stats file
    declare -gA ST=()
    local k v
    while IFS='=' read -r k v; do [[ -n "$k" ]] && ST[$k]=$v; done < "$STATS" 2>/dev/null
}

welcome_screen() {
    read_stats
    local cols; cols=$(term_cols)
    welcome_art
    printf '\n'
    local w=$(( (cols - 12) / 2 )); (( w < 36 )) && w=36
    local left right
    left=$({
        printf '%stools installed%s    %s\n'  "$C_DIM" "$C_RESET" "${ST[installed]:-none (all present)}"
        printf '%sinstall time%s       %ss\n' "$C_DIM" "$C_RESET" "${ST[duration]:-?}"
        printf '%sversion%s            %s\n'  "$C_DIM" "$C_RESET" "${ST[version]:-?}"
        printf '%sbinaries%s           %s\n'  "$C_DIM" "$C_RESET" "${ST[bins]:-?}"
    } | gum style --border rounded --border-foreground "$G_ACCENT" --padding "0 3" --width "$w")
    right=$({
        printf '%sshared libs%s        %s\n' "$C_DIM" "$C_RESET" "${ST[shared]:-?}"
        printf '%sguard libs%s         %s\n' "$C_DIM" "$C_RESET" "${ST[guard]:-?}"
        printf '%stests%s              %s file(s)\n' "$C_DIM" "$C_RESET" "${ST[tests]:-?}"
        printf '%sfinished%s           %s\n' "$C_DIM" "$C_RESET" "${ST[finished]:-?}"
    } | gum style --border rounded --border-foreground "$G_ACCENT" --padding "0 3" --width "$w")
    gum join --horizontal --align top "$left" "$right"
    printf '\n'
    # WHAT NEXT: the only thick yellow box on this screen
    {
        printf '%sWHAT NEXT%s\n\n' "$C_BOLD" "$C_RESET"
        printf '%sjust%s              this screen'\''s splash sibling (any time)\n' "$C_BOLD$C_CYAN" "$C_RESET"
        printf '%sjust menu%s         guided command builder\n'                    "$C_BOLD$C_CYAN" "$C_RESET"
        printf '%sjust fzf%s          power launcher (tab multi-select)\n'         "$C_BOLD$C_CYAN" "$C_RESET"
        printf '%sjust ci%s           check + lint + test (the exact gate)\n'      "$C_BOLD$C_CYAN" "$C_RESET"
        printf '%sjust install%s      symlink bins -> ~/.local/bin (no sudo)\n'    "$C_BOLD$C_CYAN" "$C_RESET"
    } | gum style --border thick --border-foreground "$G_WARN" --padding "0 3" --margin "0 2"
    printf '%s\n' "$EPOCHSECONDS" > "$STATE_DIR/welcome-shown"

    # 4.2 s tenths countdown: ⏎/m menu · f fzf · any other key -> shell
    local t key rc
    is_tty && tput civis 2>/dev/null
    drain_tty_input   # gum's terminal-query replies must not count as hotkeys
    local secs="${JUST_WELCOME_SECS:-4.2}" tenths
    if [[ "$secs" == *.* ]]; then tenths=$(( ${secs%.*} * 10 + ${secs#*.} )); else tenths=$(( secs * 10 )); fi
    for (( t = tenths; t > 0; t-- )); do
        printf '\r  %s▌%s  %s%s %s %s  %s⏎/m%s menu   %sf%s fzf   %sany key%s shell ' \
            "$C_BOLD$C_CYAN" "$C_RESET" \
            "$C_BOLD$C_YELLOW" "$C_REV" "$(fmt_tenths "$t")" "$C_RESET" \
            "$C_BOLD$C_GREEN" "$C_RESET" "$C_BOLD$C_GREEN" "$C_RESET" "$C_BOLD" "$C_RESET"
        rc=0; read -rsn1 -t 0.1 key || rc=$?
        if (( rc == 0 )); then
            printf '\r'; is_tty && tput el 2>/dev/null; is_tty && tput cnorm 2>/dev/null
            case "$key" in
                ''|m|M) exec just menu ;;
                f|F)    exec just fzf ;;
                *)      return 0 ;;
            esac
        fi
        (( rc > 128 )) || break
    done
    printf '\r'; is_tty && tput el 2>/dev/null; is_tty && tput cnorm 2>/dev/null
    printf '  %s%s%s just menu anytime\n' "$C_BOLD$C_YELLOW" "$I_BOLT" "$C_RESET"
}

# ── orchestrator ─────────────────────────────────────────────────────────
cmd_bootstrap() {
    mkdir -p "$STATE_DIR"
    : > "$LOG"; : > "$STEPS"; printf 'running\n' > "$STATUS"
    step_set brew-tools pending ''
    step_set syntax     pending ''
    step_set lint       pending ''

    "${BASH_SOURCE[0]}" --install >> "$LOG" 2>&1 &
    local pid=$!
    trap 'leave_alt; exit 130' INT TERM HUP

    local tick=0 key rc status fancy
    while :; do
        status=$(< "$STATUS")
        [[ "$status" != running ]] && break
        kill -0 "$pid" 2>/dev/null || { status=fail; printf 'fail\n' > "$STATUS"; break; }
        fancy=0
        if is_tty && [[ -t 0 ]] && has gum && has just && (( $(term_cols) >= 78 )); then fancy=1; fi
        if (( fancy )); then enter_alt; render_splash "$tick"; else render_plain; fi
        rc=0; read -rsn1 -t 0.5 key || rc=$?
        # stdin at EOF (rc=1, non-tty) returns instantly -> pace the loop by hand
        (( rc == 1 )) && sleep 0.5
        if (( rc == 0 )); then
            case "$key" in
                q|Q) leave_alt
                     printf '\n%saborting -- killing installer (pid %s)%s\n' "$C_RED" "$pid" "$C_RESET"
                     kill "$pid" 2>/dev/null; printf 'fail\n' > "$STATUS"
                     exit 130 ;;
                s|S) leave_alt
                     printf '\n%sinstall continues in the background%s -- follow it: tail -f %s\n' \
                         "$C_BOLD" "$C_RESET" "${LOG#"$REPO_ROOT"/}"
                     exit 0 ;;
                l|L) leave_alt
                     "${PAGER:-less}" +F "$LOG" || true ;;
            esac
        fi
        (( tick++ )) || true
    done
    wait "$pid" 2>/dev/null
    leave_alt

    status=$(< "$STATUS")
    if [[ "$status" == ok ]]; then
        if is_tty && has gum; then
            welcome_screen
        else
            printf 'bootstrap ok -- run: just\n'
        fi
    else
        printf '%s%s bootstrap FAILED%s -- last log lines:\n\n' "$C_BOLD$C_RED" "$I_MISS" "$C_RESET"
        tail -n 15 "$LOG" 2>/dev/null
        printf '\nfull log: %s\nretry: make\n' "${LOG#"$REPO_ROOT"/}"
        exit 1
    fi
}

# ── dispatch ─────────────────────────────────────────────────────────────
case "${1:-}" in
    --install) cmd_install ;;
    --welcome) welcome_screen ;;   # re-render from the last bootstrap stats
    '')        cmd_bootstrap ;;
    *)         die "usage: bootstrap.bash [--install|--welcome]" ;;
esac
