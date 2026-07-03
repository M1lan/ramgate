# lib.bash -- shared library for .just/helpers/*.bash
#
# GNU Bash >= 5.3 ONLY. This file is SOURCED, never executed (no shebang).
# shellcheck shell=bash disable=SC2034  # exported vars are consumed by the sourcing helpers
# Colors come exclusively from tput DEFAULT terminal colors (setaf 0-7).
# No themes, no hardcoded palettes -- the terminal's own scheme is the theme.
# NEVER wipes the screen or destroys scrollback (house-style Iron Rule 5).

((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3))) || {
  printf 'error: GNU Bash >= 5.3 required, got %s\n' "$BASH_VERSION" >&2
  printf 'hint : brew install bash  (/opt/homebrew/bin must precede /bin in PATH)\n' >&2
  exit 1
}

# re-source guard: bootstrap sources lib.bash AND doctor.bash, which sources
# lib.bash again -- the readonly repo facts below would collide otherwise.
[[ -n "${_JUST_LIB_LOADED:-}" ]] && return 0
_JUST_LIB_LOADED=1

set -o pipefail

# ── repo facts ───────────────────────────────────────────────────────────
LIB_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)
REPO_ROOT=$(cd -- "$LIB_DIR/../.." && pwd)
readonly LIB_DIR REPO_ROOT
PKGNAME="ramgate"
STATE_DIR="$REPO_ROOT/.just/state" # runtime state (gitignored): bootstrap log/stats

# ── tiny utils ───────────────────────────────────────────────────────────
has() { command -v -- "$1" > /dev/null 2>&1; }
die() {
  printf '%s\n' "$*" >&2
  exit 1
}
is_tty() { [[ -t 1 ]]; }

# Terminal size. GOTCHA: `tput cols` inside $() sees a pipe (not the tty)
# and silently reports 80 -- ask the controlling tty via stty instead.
# Precedence: COLUMNS/LINES env (test override) > stty on /dev/tty > tput > 80x24.
_term_size() { # sets _TERM_COLS _TERM_LINES
  local sz=''
  if [[ -z "${COLUMNS:-}" || -z "${LINES:-}" ]] && [[ -r /dev/tty ]]; then
    # 2>/dev/null BEFORE </dev/tty: redirections apply left-to-right, and on
    # macOS [[ -r /dev/tty ]] passes even without a controlling tty -- the
    # failing open must already have stderr silenced.
    sz=$({ command -v gstty > /dev/null && gstty size || stty size; } 2> /dev/null < /dev/tty) || sz=''
  fi
  # stty reports "0 0" on degenerate ptys (Emacs shell, fresh pty wrappers):
  # right SHAPE, useless VALUES -- treat non-positive as "no answer".
  if [[ $sz == +([0-9])\ +([0-9]) ]] && ((${sz% *} > 0 && ${sz#* } > 0)); then
    _TERM_COLS=${COLUMNS:-${sz#* }}
    _TERM_LINES=${LINES:-${sz% *}}
  else
    _TERM_COLS=${COLUMNS:-$(tput cols 2> /dev/null || printf 80)}
    _TERM_LINES=${LINES:-$(tput lines 2> /dev/null || printf 24)}
  fi
  ((_TERM_COLS > 0)) || _TERM_COLS=80
  ((_TERM_LINES > 0)) || _TERM_LINES=24
}
term_cols() {
  _term_size
  printf '%s' "$_TERM_COLS"
}
term_lines() {
  _term_size
  printf '%s' "$_TERM_LINES"
}

# fmt_tenths <tenths> -> "6.7" (fractional countdowns tick in 0.1s units)
fmt_tenths() { printf '%d.%d' "$(($1 / 10))" "$(($1 % 10))"; }

# drain_tty_input -- swallow pending stdin bytes before a hotkey read loop.
# gum/lipgloss QUERIES the terminal while styling (DSR ESC[6n, OSC 11 bg) when
# its stdout is the tty; the terminal's REPLIES land in our stdin, and the
# first `read -rsn1` would eat the reply's ESC -> "any key -> shell" -> the
# countdown exits instantly. Burst-drain until the line is quiet for 100ms.
drain_tty_input() {
  local _junk
  while read -rsn1 -t 0.1 _junk; do
    while read -rsn1 -t 0.02 _junk; do :; done
  done
}

# ── colors: terminal DEFAULT colors via tput only (themes are abolished) ─
_ncolors=0
if is_tty && [[ -z "${NO_COLOR:-}" ]]; then
  _ncolors=$(tput colors 2> /dev/null || printf 0)
fi

if ((_ncolors >= 8)); then
  C_RESET=$(tput sgr0) C_BOLD=$(tput bold) C_DIM=$(tput dim)
  C_RED=$(tput setaf 1) C_GREEN=$(tput setaf 2) C_YELLOW=$(tput setaf 3)
  C_BLUE=$(tput setaf 4) C_MAGENTA=$(tput setaf 5) C_CYAN=$(tput setaf 6)
  C_ACCENT=$C_CYAN C_HEAD=$C_BLUE C_MUTED=$C_DIM
  C_REV=$(tput rev 2> /dev/null) # reverse video -- tput is $TERM-only, so
  # it MUST live behind this tty/color gate
else
  C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW=''
  C_BLUE='' C_MAGENTA='' C_CYAN='' C_ACCENT='' C_HEAD='' C_MUTED='' C_REV=''
fi
# ANSI palette indexes for gum/fzf flags (resolved against the terminal's
# own scheme -- default colors, not hex).
G_ACCENT=6 # cyan
G_OK=2     # green
G_WARN=3   # yellow
# banner gradient cycles the default ANSI colors (cyan/blue/green)
BANNER_RAMP=(6 4 2 6 4 2)

# ── icons (nerdfont, with plain-ascii fallback via NO_NERDFONT=1) ────────
if [[ -n "${NO_NERDFONT:-}" ]]; then
  I_OK='[ok]' I_MISS='[--]' I_WARN='[!]' I_GEAR='*' I_ROCKET='>' I_TEST='#'
  I_PKG='R' I_GIT='Y' I_BOX='=' I_DOC='~' I_BOLT='!' I_SEARCH='?' I_WEB='@'
else
  I_OK='' I_MISS='' I_WARN='' I_GEAR='' I_ROCKET='󱓞' I_TEST='󰙨'
  I_PKG='󰍛' I_GIT='' I_BOX='󰏗' I_DOC='󰈙' I_BOLT='󱐋' I_SEARCH='' I_WEB='󰖟'
fi

# ── fast project facts (file parsing / counting only -- never runs a bin) ─
# ramgate is BUILD-LESS: there is no compiler. "Facts" are counts of the
# two binaries, the shared + guard libraries, the test files, and the parsed
# version string. The build-less "compile" is `bash -n` + shellcheck (see
# the Justfile check/lint recipes), never a build tool.

# fact_version -- parse RG_VERSION='x.y.z' out of bin/ram-xray (pure bash).
fact_version() {
  local f="$REPO_ROOT/bin/ram-xray" line
  [[ -f $f ]] || {
    printf '?'
    return
  }
  while IFS= read -r line; do
    if [[ $line =~ RG_VERSION=\'([0-9][0-9.]*)\' ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return
    fi
  done < "$f"
  printf '?'
}

# fact_bins -- number of files in bin/ (the two-binary hard wall: expect 2).
fact_bins() {
  local d="$REPO_ROOT/bin" n=0 f
  [[ -d $d ]] || {
    printf 0
    return
  }
  for f in "$d"/*; do [[ -f $f ]] && ((n++)); done
  printf '%s' "$n"
}

# fact_shared_libs -- pure shared libs: lib/*.bash (non-recursive).
fact_shared_libs() {
  local d="$REPO_ROOT/lib" n=0 f
  [[ -d $d ]] || {
    printf 0
    return
  }
  for f in "$d"/*.bash; do [[ -f $f ]] && ((n++)); done
  printf '%s' "$n"
}

# fact_guard_libs -- acting state machine: lib/guard/*.bash.
fact_guard_libs() {
  local d="$REPO_ROOT/lib/guard" n=0 f
  [[ -d $d ]] || {
    printf 0
    return
  }
  for f in "$d"/*.bash; do [[ -f $f ]] && ((n++)); done
  printf '%s' "$n"
}

# fact_tests -- number of *.bash FILES under test/ (file count = pipe, no -X:
# `-X gawk END{NR}` would hand the whole list to one gawk that reads their
# CONTENTS and print total LINES instead -- house-style gotcha #28).
fact_tests() {
  local d="$REPO_ROOT/test" n
  [[ -d $d ]] || {
    printf 0
    return
  }
  if has fd && has gawk; then
    n=$(fd -e bash . "$d" 2> /dev/null | gawk 'END { print NR }') || n=0
  else
    local f
    n=0
    for f in "$d"/*.bash "$d"/**/*.bash; do [[ -f $f ]] && ((n++)); done
  fi
  printf '%s' "${n:-0}"
}

# fact_loc -- summed lines of shell across bin/ + lib/ (the whole codebase).
# `-X gawk END{NR}` here is CORRECT: we WANT the total line count.
fact_loc() {
  local n
  if has fd && has gawk; then
    n=$(fd -t f . "$REPO_ROOT/bin" "$REPO_ROOT/lib" -X gawk 'END { print NR }' 2> /dev/null) || n=''
    printf '%s' "${n:-?}"
  else
    printf '?'
  fi
}

# fact_branch -- current branch name. Handles the UNBORN branch (fresh repo,
# no commits yet): `rev-parse --abbrev-ref HEAD` there exits 128 while still
# echoing a bogus "HEAD", so use symbolic-ref (works pre-first-commit) and fall
# back to a short sha only when genuinely detached.
fact_branch() {
  local b
  b=$(git -C "$REPO_ROOT" symbolic-ref --short -q HEAD 2> /dev/null) ||
    b=$(git -C "$REPO_ROOT" rev-parse --short HEAD 2> /dev/null)
  printf '%s' "${b:-(no git)}"
}

fact_dirty() {
  git -C "$REPO_ROOT" status --porcelain 2> /dev/null | gawk 'END { print NR }'
}

# fact_last_commit -- keyed off captured OUTPUT, not exit code: an unborn branch
# makes `git log` exit 128, and `|| printf` would then append a spurious line.
fact_last_commit() {
  local c
  c=$(git -C "$REPO_ROOT" log -1 --format='%h %s' 2> /dev/null)
  printf '%s' "${c:-(none)}"
}

# fact_mtime <relpath> -- "YYYY-mm-dd HH:MM" mtime, or empty when absent.
fact_mtime() {
  local f="$REPO_ROOT/$1"
  [[ -f $f ]] || return 0
  if has gdate; then
    gdate -r "$f" '+%Y-%m-%d %H:%M'
  else
    date -r "$f" '+%Y-%m-%d %H:%M' 2> /dev/null || true
  fi
}

# fact_osver -- macOS product version (the tool is tuned for 26.x).
fact_osver() { sw_vers -productVersion 2> /dev/null || printf '?'; }

# fact_localbin_ok -- "ok" if ~/.local/bin is on PATH (install target visible).
fact_localbin_ok() {
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) printf 'ok' ;;
    *) : ;;
  esac
}
