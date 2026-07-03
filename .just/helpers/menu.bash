#!/usr/bin/env bash
# menu.bash -- the GUM launcher: a guided, parameter-aware command builder.
#
#   menu.bash
#
# Identity (vs fzf.bash, the flat power launcher):
#   * `gum filter` IS the menu -- full grouped list visible, narrows live,
#     --no-fuzzy gives word-prefix matching ("ru" hits run-xray, not rerun).
#   * The differentiator: recipes with parameters become fill-in-the-blank
#     forms (gum input per argument, defaults skippable), then gum confirm.
#     menu PROMPTS for params; fzf MULTI-SELECTS. That is the dividing line.
#   * Items self-generate from `just --dump` -- the menu can never go stale.
#   * NO separator/header pseudo-entries -- grouping is a [group] column.
#   * Terminal DEFAULT colors only (gum defaults + ANSI indexes) -- no themes.
#   * SIGINT-safe: trap + rc-capture (never `|| true` around gum).
#   * Uses NO fzf anywhere, by design.
#   * NEVER wipes the screen (Iron Rule 5): a blank-line spacer at each loop
#     top; `gum filter` redraws its own region inline.
#
# Pure GNU Bash 5.3+.

# shellcheck source=lib.bash disable=SC2154
source "$(cd -- "${BASH_SOURCE[0]%/*}" && pwd)/lib.bash"
cd "$REPO_ROOT" || exit 1
trap 'exit 130' INT TERM HUP

for dep in gum jq just; do
  has "$dep" || die "error: $dep required for the menu -- run: just doctor-install"
done

# group display order (anything unknown sorts last, alphabetically)
GROUP_ORDER=(umbrella build run test lint setup clean git util meta)

# ── build the item list from the live recipe inventory ───────────────────
# tab-separated: name <TAB> group <TAB> doc <TAB> params(space-joined)
# param suffixes: `?` = has default (skippable) · `*` = variadic (skippable)
recipe_rows() {
  just --dump --dump-format json | jq -r '
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
        | @tsv'
}

build_items() {
  declare -gA ITEM_PARAMS=()
  ITEMS=()
  local -A by_group=()
  local name group doc params
  while IFS=$'\t' read -r name group doc params; do
    ITEM_PARAMS[$name]=$params
    local tag suffix=''
    [[ -n "$params" ]] && suffix=" ($params)"
    printf -v tag '%-14s %-10s %s%s' "$name" "[$group]" "$doc" "$suffix"
    by_group[$group]+="$tag"$'\n'
  done < <(recipe_rows | LC_ALL=C sort -t $'\t' -k2,2 -k1,1)

  local g line
  for g in "${GROUP_ORDER[@]}"; do
    [[ -n "${by_group[$g]:-}" ]] || continue
    while IFS= read -r line; do [[ -n "$line" ]] && ITEMS+=("$line"); done <<< "${by_group[$g]}"
    unset "by_group[$g]"
  done
  for g in $(printf '%s\n' "${!by_group[@]}" | LC_ALL=C sort); do
    while IFS= read -r line; do [[ -n "$line" ]] && ITEMS+=("$line"); done <<< "${by_group[$g]}"
  done
  # a real, actionable entry -- NOT a separator
  printf -v line '%-14s %-10s %s' 'quit' '[menu]' 'leave the menu'
  ITEMS+=("$line")
}

# ── preview + parameter form + confirm + run ─────────────────────────────
show_recipe() { # <name>
  if has bat; then
    just --show "$1" 2> /dev/null |
      bat --language=make --color=always --style=plain --paging=never 2> /dev/null ||
      just --show "$1"
  else
    just --show "$1"
  fi
}

run_recipe() { # <name>
  local name="$1" args=() p val rc
  printf '\n'
  gum style --border rounded --border-foreground "$G_ACCENT" \
    --padding "0 2" --margin "1 2" \
    "$(printf '%s just %s' "$I_BOLT" "$name")"
  show_recipe "$name"
  printf '\n'
  for p in ${ITEM_PARAMS[$name]:-}; do
    local label="$p" skippable=0 variadic=0
    case "$p" in
      *'?') skippable=1 label="${p%\?} (optional, enter to skip)" ;;
      *'*') skippable=1 variadic=1 label="${p%\*} (variadic, space-separated, enter to skip)" ;;
    esac
    rc=0
    val=$(gum input \
      --header="$(printf '%sparam ›%s %s%s%s' "$C_DIM" "$C_RESET" "$C_BOLD" "$label" "$C_RESET")" \
      --header.foreground="6" \
      --placeholder="value for {{${p%[?*]}}}" \
      --prompt='  ❯ ' \
      --prompt.foreground="6" \
      --cursor.foreground="6") || rc=$?
    ((rc != 0)) && return 0 # cancelled -> back to menu
    # empty value for a skippable param: stop here, let just fill the rest
    if [[ -z "$val" ]]; then
      ((skippable)) && break
      args+=("$val") # required param given empty: pass it through
    elif ((variadic)); then
      read -r -a words <<< "$val"
      args+=("${words[@]+"${words[@]}"}")
    else
      args+=("$val")
    fi
  done
  rc=0
  gum confirm --affirmative=" run" --negative=" back" \
    --prompt.foreground="6" \
    "$(printf 'just %s %s' "$name" "${args[*]:-}")" || rc=$?
  ((rc != 0)) && return 0 # back to menu
  exec just "$name" "${args[@]+"${args[@]}"}"
}

# ── main loop ────────────────────────────────────────────────────────────
build_items
header=$(printf '%s %s · %s recipes · type to filter · esc esc quits' \
  "$I_PKG" "$PKGNAME" "${#ITEMS[@]}")

while true; do
  printf '\n' # loop-top spacer -- append, NEVER wipe scrollback (Iron Rule 5)
  gum style --border rounded --border-foreground "$G_ACCENT" \
    --padding "0 2" --margin "0 1" \
    "$(printf '%s%s %s%s' "$C_BOLD$C_CYAN" "$I_PKG" "$PKGNAME" "$C_RESET")" \
    "$(printf '%sguided builder · params become forms · just fzf = power mode%s' "$C_DIM" "$C_RESET")"

  height=$(($(term_lines) - 12))
  ((height < 8)) && height=8
  rc=0
  choice=$(printf '%s\n' "${ITEMS[@]}" |
    gum filter --no-fuzzy --reverse --height="$height" \
      --placeholder='type a recipe…' --header="$header" \
      --indicator='▌' \
      --indicator.foreground="6" \
      --match.foreground="6" \
      --header.foreground="3" \
      --prompt='  › ' \
      --prompt.foreground="6") || rc=$?
  ((rc != 0)) && exit 0 # esc / ctrl-c
  [[ -z "$choice" ]] && exit 0

  recipe=${choice%%[[:space:]]*}
  case "$recipe" in
    quit) exit 0 ;;
    *) run_recipe "$recipe" ;;
  esac
done
