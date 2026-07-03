#!/usr/bin/env bash
# fzf.bash -- the FZF launcher: a flat, dense, full-screen power surface.
#
#   fzf.bash            interactive launcher
#   fzf.bash --rows     print the menu rows and exit (used by ctrl-r reload)
#
# Identity (vs menu.bash, the guided gum command builder):
#   * Everything on ONE screen: all recipes, fuzzy match across
#     name+group+doc, always-on `just --show` preview pane.
#   * The differentiator: TAB multi-select runs recipes as a batch,
#     in list order, stopping at the first failure.
#     fzf MULTI-SELECTS; menu PROMPTS for params. That is the dividing line.
#   * No parameter prompting -- parametrized recipes run bare; `just`'s own
#     usage error tells you what was missing. Speed is this surface's job.
#   * keymap: tab select · enter run · ctrl-r reload · ctrl-/ preview · esc quit
#   * Items self-generate from `just --dump` -- can never go stale.
#   * NO separator/header pseudo-entries -- grouping is a [group] column.
#   * fzf's alternate screen + default colors -- no themes, no gum, by design.
#     The alt screen restores the primary screen + scrollback on exit; it is
#     not a wipe (Iron Rule 5 allows fzf's own alt-screen, like less/vim).
#
# Pure GNU Bash 5.3+.

# shellcheck source=lib.bash disable=SC2154
source "$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)/lib.bash"
cd "$REPO_ROOT" || exit 1
trap 'exit 130' INT TERM HUP

has fzf || die "error: fzf required for this launcher -- run: just doctor-install"
has jq || die "error: jq required for this launcher -- run: just doctor-install"
has just || die "error: just not on PATH"

# group display order (anything unknown sorts last, alphabetically)
GROUP_ORDER=(umbrella build run test lint setup clean git util meta)

# ── menu rows from the live recipe inventory ─────────────────────────────
# display: name  [group]  doc (params)   -- field 1 is always the recipe name
# semantic group palette (saturated ANSI indexes, red = destructive):
#   green umbrella/build · cyan run · yellow test · magenta lint · blue setup ·
#   red clean · dim git/util/meta
group_tint() { # <group> -> raw ANSI sequence (fzf renders with --ansi)
  case "$1" in
    umbrella | build) printf '\033[32m' ;;
    run) printf '\033[36m' ;;
    test) printf '\033[33m' ;;
    lint) printf '\033[35m' ;;
    setup) printf '\033[34m' ;;
    clean) printf '\033[31m' ;;
    *) printf '\033[2m' ;;
  esac
}

rows() {
  local -A by_group=()
  local name group doc params
  while IFS=$'\t' read -r name group doc params; do
    local tag suffix=''
    [[ -n "$params" ]] && suffix=" ($params)"
    # name column stays ANSI-free: it is the extraction target downstream
    printf -v tag '%-14s %b%-10s\033[0m %s%s' \
      "$name" "$(group_tint "$group")" "[$group]" "$doc" "$suffix"
    by_group[$group]+="$tag"$'\n'
  done < <(just --dump --dump-format json | jq -r '
        .recipes
        | to_entries[]
        | select(.key | startswith("_") | not)
        | select(.key != "default")
        | select([.value.attributes[]? | strings] | index("private") | not)
        | [ .key,
            (([.value.attributes[]? | objects | .group] | first) // "misc"),
            (.value.doc // ""),
            ([.value.parameters[]?
              | .name
                + (if .kind == "star" or .kind == "plus" then "*"
                   elif .default != null then "?"
                   else "" end)
             ] | join(" "))
          ]
        | @tsv' | LC_ALL=C sort -t $'\t' -k2,2 -k1,1)

  local g
  for g in "${GROUP_ORDER[@]}"; do
    [[ -n "${by_group[$g]:-}" ]] && printf '%s' "${by_group[$g]}"
    unset "by_group[$g]"
  done
  for g in $(printf '%s\n' "${!by_group[@]}" | LC_ALL=C sort); do
    printf '%s' "${by_group[$g]}"
  done
}

[[ "${1:-}" == "--rows" ]] && {
  rows
  exit 0
}

# ── preview command (recipe source, make-highlighted when bat exists) ────
preview='just --show {1} 2>/dev/null'
has bat && preview='just --show {1} 2>/dev/null | bat --language=make --color=always --style=plain --paging=never'

# ── the launcher ─────────────────────────────────────────────────────────
# fzf owns the header line's color (header:3) -- plain text only, no ANSI
header='tab select+next · shift-tab deselect · enter run batch · ctrl-r reload · ctrl-/ preview · esc quit'

rc=0
selection=$(rows | fzf \
  --ansi \
  --multi \
  --style=full \
  --reverse \
  --info=inline-right \
  --border=rounded \
  --border-label=" $I_BOLT $PKGNAME · power launcher " \
  --border-label-pos=3 \
  --color='border:6,label:6,header:3,prompt:6,pointer:6,marker:2,spinner:6,info:8,separator:8,scrollbar:8' \
  --color='hl:6,hl+:6,fg+:-1,bg+:-1' \
  --header="$header" \
  --prompt='  ❯ ' \
  --pointer='▌' \
  --marker='✓' \
  --ellipsis='…' \
  --preview="$preview" \
  --preview-window='right,55%,border-left,<70(down,40%,border-top)' \
  --preview-label=" $I_DOC recipe source " \
  --preview-label-pos=3 \
  --input-label=' filter ' \
  --list-label=" $I_PKG $PKGNAME " \
  --bind "ctrl-r:reload(\"${BASH_SOURCE[0]}\" --rows)" \
  --bind 'ctrl-/:toggle-preview' \
  --bind 'tab:toggle+down' \
  --bind 'shift-tab:toggle+up') || rc=$?
# 130 = cancelled, 1 = no match -- both are a clean "do nothing"
((rc != 0)) && exit 0
[[ -z "$selection" ]] && exit 0

# ── run the batch: list order, stop at first failure ─────────────────────
mapfile -t lines <<< "$selection"
names=()
for line in "${lines[@]}"; do
  names+=("${line%%[[:space:]]*}")
done

total=${#names[@]} n=0
for name in "${names[@]}"; do
  ((++n))
  printf '%s▌ [%d/%d] just %s%s\n' "$C_BOLD$C_CYAN" "$n" "$total" "$name" "$C_RESET"
  rc=0
  just "$name" || rc=$?
  if ((rc != 0)); then
    printf '%s▌ just %s failed (rc=%d) -- stopping the batch%s\n' \
      "$C_BOLD$C_RED" "$name" "$rc" "$C_RESET"
    exit "$rc"
  fi
done
((total > 1)) && printf '%s▌ batch ok: %d recipe(s)%s\n' "$C_BOLD$C_GREEN" "$total" "$C_RESET"
exit 0
