#!/usr/bin/env bash
# info-screen.bash -- the screen-filling welcome shown by a bare `just`.
#
#   info-screen.bash            full splash + countdown (default recipe)
#   info-screen.bash --static   facts only, no countdown (the `info` recipe)
#   info-screen.bash --factoid  print one frugal factoid and exit (delegates)
#
# Countdown contract (the whole point of the bare `just`):
#   enter / m   -> exec just menu     (guided gum builder)
#   f           -> exec just fzf      (flat fzf power launcher)
#   d           -> exec just doctor
#   c           -> exec just check    (the build-less "compile": bash -n)
#   any other   -> back to shell immediately
#   timeout     -> print ONE frugal factoid (missing deps first), exit 0
# Default timeout 6.7 s (tenths-resolution display); JUST_SPLASH_SECS overrides
# (accepts "5" or "4.2").
#
# Layout adapts to the terminal's width:
#   wide      (cols >= 130)          three panel columns
#   square    (96 <= cols < 130)     two panel columns
#   portrait  (78 <= cols < 96)      stacked single column
#   tiny/non-tty/no-gum              degrade to --static (no countdown) --
#                                    NEVER to the bare list (that's `just help`)
#
# Facts are FILE-PARSE ONLY -- this splash never executes a ramgate binary.
# NEVER wipes the screen / destroys scrollback (Iron Rule 5): the splash PRINTS
# INLINE and appends. Only the \r countdown line is rewritten (tput el, one line).
# Pure GNU Bash 5.3+. Colors: terminal defaults via tput only; boxes via gum.

# shellcheck source=lib.bash disable=SC2154
source "$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)/lib.bash"
cd "$REPO_ROOT" || exit 1

# --factoid short-circuit (used by callers that only want the one-liner)
if [[ "${1:-}" == "--factoid" ]]; then
    "$LIB_DIR/doctor.bash" --factoid 2>/dev/null || true
    exit 0
fi

# restore cursor on EVERY exit path (incl. before exec, which skips EXIT traps)
restore() { is_tty && tput cnorm 2>/dev/null; }
trap 'restore; exit 130' INT TERM HUP

STATIC=0
[[ "${1:-}" == "--static" ]] && STATIC=1

# ── degradation: bare `just` ALWAYS shows the info splash ────────────────
if (( ! STATIC )); then
    { is_tty && [[ -t 0 ]]; } || STATIC=1
fi
COLS=$(term_cols); LINES_=$(term_lines)
if ! has gum || (( COLS < 78 || LINES_ < 24 )); then
    STATIC=1
fi

# ── gather facts (file parsing only -- instant) ──────────────────────────
branch=$(fact_branch)
dirty=$(fact_dirty)
last=$(fact_last_commit)
(( ${#last} > 26 )) && last="${last:0:25}…"
app_v=$(fact_version)
bins=$(fact_bins)
shared=$(fact_shared_libs)
guard=$(fact_guard_libs)
tests=$(fact_tests)
loc=$(fact_loc)
osver=$(fact_osver)
toolbelt=$("$LIB_DIR/doctor.bash" --summary 2>/dev/null || true)

dirty_str="clean"
(( dirty > 0 )) && dirty_str="${dirty} dirty file(s)"

# ── banner ───────────────────────────────────────────────────────────────
banner() {
    if has figlet; then
        local art line i=0 n=${#BANNER_RAMP[@]}
        art=$(figlet -f smslant -w "$COLS" "$PKGNAME" 2>/dev/null) \
            || art=$(figlet -f slant -w "$COLS" "$PKGNAME" 2>/dev/null) \
            || art=$(figlet -w "$COLS" "$PKGNAME")
        while IFS= read -r line; do
            local tint=''
            (( _ncolors >= 8 )) && tint=$(tput setaf "${BANNER_RAMP[i % n]}" 2>/dev/null)
            printf '  %s%s%s\n' "$tint" "$line" "$C_RESET"
            (( i++ )) || true
        done <<<"$art"
    else
        printf '\n  %s%s◢◤◢◤ %s ◥◣◥◣%s\n' "$C_BOLD" "$C_ACCENT" "${PKGNAME^^}" "$C_RESET"
    fi
    printf '  %smacOS memory x-ray + OOM guard -- two binaries, one hard wall%s\n' "$C_BOLD" "$C_RESET"
    printf '  %s%s v%s · %s bins · %s+%s libs · %s tests · macOS %s%s\n' \
        "$C_MUTED" "$I_PKG" "$app_v" "$bins" "$shared" "$guard" "$tests" "$osver" "$C_RESET"
}

# ── panel bodies (plain text; gum draws the boxes) ───────────────────────
panel_project() {
    printf '%s  PROJECT\n\n' "$I_GIT"
    printf 'branch    %s\n' "$branch"
    printf 'tree      %s\n' "$dirty_str"
    printf 'last      %s\n' "$last"
    printf 'version   %s\n' "$app_v"
}

panel_inventory() {
    printf '%s  INVENTORY\n\n' "$I_BOX"
    printf 'binaries  %s (ram-xray, ram-guard)\n' "$bins"
    printf 'shared    %s pure libs\n' "$shared"
    printf 'guard     %s acting libs\n' "$guard"
    printf 'tests     %s file(s)\n' "$tests"
    printf 'shell loc %s\n' "$loc"
}

panel_quickstart() {
    printf '%s  QUICK START\n\n' "$I_ROCKET"
    printf 'just %-11s guided launcher\n' 'menu'
    printf 'just %-11s power launcher\n' 'fzf'
    printf 'just %-11s ram-xray summary\n' 'run-xray'
    printf 'just %-11s run pressure guard\n' 'run-guard'
    printf 'just %-11s format shell\n' 'fmt'
    printf 'just %-11s dependency audit\n' 'doctor'
}

panel_umbrella() {
    printf '%s  UMBRELLA\n\n' "$I_WEB"
    printf 'just %-10s check + lint + test\n' 'ci'
    printf 'just %-10s fmt + the CI gate\n' 'qa'
    printf 'just %-10s doctor + qa\n' 'all'
    printf 'just %-10s bash -n every file\n' 'check'
    printf 'just %-10s shellcheck -x\n' 'lint'
}

panel_status() {
    printf '%s  TOOLBELT & SETUP\n\n' "$I_GEAR"
    printf '%s\n\n' "${toolbelt:-doctor unavailable}"
    printf '%-14s %s\n' 'install' 'symlink bins -> ~/.local/bin'
    printf '%-14s %s\n' 'uninstall' 'remove those symlinks'
    printf '%-14s %s\n' 'CONTRACT.md' 'the authoritative spec'
}

# ── the hi-viz KEYS box (vertical rail / horizontal bar) ─────────────────
panel_keys_vertical() {
    printf '%s  KEYS\n\n' "$I_BOLT"
    printf '⏎ m   menu\n'
    printf 'f     fzf\n'
    printf 'd     doctor\n'
    printf 'c     check\n'
    printf 'q     shell\n'
}

keys_bar_text() {
    printf '%s  ⏎/m menu · f fzf · d doctor · c check · q shell' "$I_BOLT"
}

# ── compose with gum (boxes + horizontal join) ───────────────────────────
render_panels() {
    local style=(--border rounded --border-foreground "$G_ACCENT" --padding "0 2" --margin "0 1")
    local keystyle=(--border thick --border-foreground "$G_WARN" --padding "0 2" --margin "0 1" --bold)
    local p1 p2 p3 rail
    if (( COLS >= 144 )); then          # very wide: hi-viz KEYS rail LEFT + 3 columns
        local railw=16
        local w=$(( (COLS - railw - 16) / 3 ))
        rail=$(panel_keys_vertical | gum style "${keystyle[@]}" --width "$railw")
        p1=$({ panel_project; printf '\n'; panel_inventory; }  | gum style "${style[@]}" --width "$w")
        p2=$(panel_quickstart | gum style "${style[@]}" --width "$w")
        p3=$({ panel_umbrella; printf '\n'; panel_status; }    | gum style "${style[@]}" --width "$w")
        gum join --horizontal --align top "$rail" "$p1" "$p2" "$p3"
    elif (( COLS >= 130 )); then        # landscape: 3 columns + KEYS bar at the BOTTOM
        local w=$(( (COLS - 12) / 3 ))
        p1=$({ panel_project; printf '\n'; panel_inventory; }  | gum style "${style[@]}" --width "$w")
        p2=$(panel_quickstart | gum style "${style[@]}" --width "$w")
        p3=$({ panel_umbrella; printf '\n'; panel_status; }    | gum style "${style[@]}" --width "$w")
        gum join --horizontal --align top "$p1" "$p2" "$p3"
        keys_bar_text | gum style "${keystyle[@]}" --width $(( COLS - 6 ))
    elif (( COLS >= 96 )); then         # squarish: 2 columns + KEYS bar at the BOTTOM
        local w=$(( (COLS - 10) / 2 ))
        p1=$({ panel_project; printf '\n'; panel_inventory; }  | gum style "${style[@]}" --width "$w")
        p2=$({ panel_quickstart; printf '\n'; panel_umbrella; printf '\n'; panel_status; } | gum style "${style[@]}" --width "$w")
        gum join --horizontal --align top "$p1" "$p2"
        keys_bar_text | gum style "${keystyle[@]}" --width $(( COLS - 6 ))
    else                                # portrait: stacked + KEYS bar at the BOTTOM
        local w=$(( COLS - 6 )) body
        for body in panel_project panel_inventory panel_quickstart panel_umbrella panel_status; do
            "$body" | gum style "${style[@]}" --width "$w"
        done
        keys_bar_text | gum style "${keystyle[@]}" --width "$w"
    fi
}

# ── countdown footer ─────────────────────────────────────────────────────
splash_tenths() {
    local s="${JUST_SPLASH_SECS:-6.7}"
    if [[ "$s" == *.* ]]; then
        printf '%s' "$(( ${s%.*} * 10 + ${s#*.} ))"
    else
        printf '%s' "$(( s * 10 ))"
    fi
}

countdown() {
    local t key rc
    tput civis 2>/dev/null
    drain_tty_input   # gum's terminal-query replies must not count as hotkeys
    for (( t = $(splash_tenths); t > 0; t-- )); do
        printf '\r  %s▌%s  %s%s %s %s  %s⏎/m%s menu · %sf%s fzf · %sd%s doctor · %sc%s check · %sq%s shell ' \
            "$C_BOLD$C_CYAN" "$C_RESET" \
            "$C_BOLD$C_YELLOW" "$C_REV" "$(fmt_tenths "$t")" "$C_RESET" \
            "$C_BOLD$C_GREEN" "$C_RESET" "$C_BOLD$C_GREEN" "$C_RESET" \
            "$C_BOLD$C_GREEN" "$C_RESET" "$C_BOLD$C_GREEN" "$C_RESET" \
            "$C_BOLD" "$C_RESET"
        rc=0
        read -rsn1 -t 0.1 key || rc=$?
        if (( rc == 0 )); then
            printf '\r'; is_tty && tput el 2>/dev/null
            restore
            case "$key" in
                ''|m|M) exec just menu ;;
                f|F)    exec just fzf ;;
                d|D)    exec just doctor ;;
                c|C)    exec just check ;;
                *)      return 0 ;;          # q / esc / arrows / anything -> shell
            esac
        fi
        (( rc > 128 )) || break   # rc 1 = EOF (stdin gone)
    done
    printf '\r'; is_tty && tput el 2>/dev/null
    restore
    # timeout: ONE frugal factoid, then nothing
    local factoid
    factoid=$("$LIB_DIR/doctor.bash" --factoid 2>/dev/null || true)
    printf '  %s%s%s %s\n' "$C_BOLD$C_YELLOW" "$I_BOLT" "$C_RESET" "${factoid:-just menu anytime · just help for the plain list}"
}

# ── main (append inline -- Iron Rule 5: never wipe the scrollback) ────────
banner
printf '\n'
if has gum; then
    render_panels
else
    panel_project; printf '\n'; panel_inventory; printf '\n'; panel_quickstart; printf '\n'; panel_umbrella
fi
printf '\n'
(( STATIC )) || countdown
restore
exit 0
