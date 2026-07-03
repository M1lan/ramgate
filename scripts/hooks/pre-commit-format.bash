#!/usr/bin/env bash
# pre-commit format hook -- fast, deterministic auto-format of staged files, then
# re-stage what changed so the commit proceeds WITH the fixes (no interruption).
# Heavy static analysis (shellcheck) stays in `just lint` / CI: hooks are guardrails.
#
# Bash toolchain swap (was ktlint): shfmt -w -i 2 -ci -sr on staged *.bash + bin/*.
# Markdown keeps rumdl. prek passes the staged filenames as arguments.
set -uo pipefail

HOOK_NAME="format"
# shellcheck source=scripts/hooks/lib/hooklib.bash
source "$(git rev-parse --show-toplevel)/scripts/hooks/lib/hooklib.bash"
hook::load_config
hook::trap_interrupts

(($# == 0)) && exit 0

sh=()
md=()
for f in "$@"; do
  [[ -f "$f" ]] || continue
  case "$f" in
    *.md) md+=("$f") ;;
    *.bash) sh+=("$f") ;;
    bin/*) sh+=("$f") ;; # the two extensionless binaries
    *)
      # Any other file whose shebang is bash is fair game for shfmt.
      if IFS= read -r firstline < "$f" 2> /dev/null && [[ "$firstline" == '#!'*bash* ]]; then
        sh+=("$f")
      fi
      ;;
  esac
done

changed=()
restage() { for f in "$@"; do git add -- "$f" && changed+=("$f"); done; }

# --- Bash: shfmt auto-format (house style: 2-space, switch indent, redir spacing) ---
sh_unfixed=0
if ((${#sh[@]})) && command -v shfmt > /dev/null 2>&1; then
  before="$(md5sum "${sh[@]}" 2> /dev/null || true)"
  shfmt -w -i 2 -ci -sr "${sh[@]}" > /tmp/shfmt.$$ 2>&1 || sh_unfixed=1
  after="$(md5sum "${sh[@]}" 2> /dev/null || true)"
  [[ "$before" != "$after" ]] && restage "${sh[@]}"
fi

# --- Markdown: rumdl auto-format --------------------------------------------
if ((${#md[@]})) && command -v rumdl > /dev/null 2>&1; then
  before="$(md5sum "${md[@]}" 2> /dev/null || true)"
  rumdl fmt "${md[@]}" > /dev/null 2>&1 || true
  after="$(md5sum "${md[@]}" 2> /dev/null || true)"
  [[ "$before" != "$after" ]] && restage "${md[@]}"
fi

if ((${#changed[@]})); then
  hook::ok "auto-formatted and re-staged ${#changed[@]} file(s):"
  printf '  %s\n' "${changed[@]}"
fi

# --- remaining, non-auto-fixable shfmt problems (e.g. parse errors) ---------
if ((sh_unfixed)); then
  hook::warn "shfmt reported issues it could not auto-fix:"
  sed -n '1,20p' /tmp/shfmt.$$ 2> /dev/null || true
  rm -f /tmp/shfmt.$$

  # Optional, opt-in, never-auto-firing AI triage of the leftovers.
  if hook::interactive && hook::ai_available; then
    ans="$(hook::ask "ask local AI how to fix the remaining format issues? y=yes  n=skip" "yn")"
    rc=$?
    if ((rc == 0)) && [[ "$ans" == y ]]; then
      printf '%s\n' "${sh[@]}" | hook::ai_run \
        "These Bash files failed shfmt. List the smallest concrete fix per issue. Terse, no preamble."
    fi
  elif hook::interactive && [[ "${HOOKS_LLM_ASSIST:-1}" == 1 ]]; then
    hook::say "tip: configure AI format help with  just hooks-ai-setup"
  fi
  # Style issues never hard-block the commit; format fixes are already staged.
fi
rm -f /tmp/shfmt.$$ 2> /dev/null || true
exit 0
