#!/usr/bin/env bash
# pre-push hook -- soft-enforce conventional branch names (<type>/<kebab-slug>).
# Offers a deterministic rename or an AI suggestion. A timeout aborts the push
# (a nudge to rename), so a non-answer never blocks I/O indefinitely.
#
# prek invokes this with no useful args on the pre-push stage.
set -uo pipefail

HOOK_NAME="branch-name"
# shellcheck source=scripts/hooks/lib/hooklib.bash
source "$(git rev-parse --show-toplevel)/scripts/hooks/lib/hooklib.bash"
hook::load_config
hook::trap_interrupts

branch="$(git rev-parse --abbrev-ref HEAD 2> /dev/null || true)"
[[ -z "$branch" || "$branch" == HEAD ]] && exit 0 # detached HEAD: nothing to check

# Protected branches pass untouched.
for p in $HOOKS_BRANCH_PROTECTED; do
  [[ "$branch" == "$p" ]] && exit 0
done

alt="${HOOKS_BRANCH_TYPES// /|}"
[[ "$branch" =~ ^(${alt})/[a-z0-9][a-z0-9._-]*$ ]] && exit 0 # already valid

# --- build a deterministic suggestion ---------------------------------------
slug="$(printf '%s' "$branch" |
  tr '[:upper:]' '[:lower:]' |
  sed -E 's#^[a-z]+/##; s/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
type_guess="$(printf '%s' "$branch" | sed -nE "s#^(${alt})[/_-].*#\1#p")"
[[ -z "$type_guess" ]] && type_guess="feat"
suggestion="${type_guess}/${slug:-change}"

hook::rule "branch name is not conventional"
hook::say "current:   $branch"
hook::say "expected:  <type>/<kebab-slug>   types: ${HOOKS_BRANCH_TYPES}"
hook::say "suggested: $suggestion"

# Non-interactive: warn and allow the push (no human to nudge).
if ! hook::interactive; then
  hook::warn "pushing non-conventional branch (no tty to confirm a rename): $branch"
  exit 0
fi

ans="$(hook::ask "rename branch? r=rename to suggestion  a=AI suggest (local)  n=abort push" "ran")"
rc=$?
if ((rc == 3)); then
  hook::warn "timed out after ${HOOKS_TIMEOUT}s -- aborting push so you can rename"
  hook::say "tip:  git branch -m '$suggestion'  &&  git push -u origin '$suggestion'"
  exit 1
fi

case "$ans" in
  r)
    git branch -m "$suggestion"
    hook::ok "renamed: $branch -> $suggestion"
    hook::warn "re-run your push for the new branch:  git push -u origin '$suggestion'"
    exit 1
    ;; # stop this push: the old ref/branch is gone
  a)
    if ! hook::ai_available; then
      hook::warn "AI assist is not configured -- run:  just hooks-ai-setup"
      exit 1
    fi
    hook::info "asking the configured local-first AI for a branch name..."
    ai_name="$(git --no-pager log --oneline -10 | hook::ai_run \
      "Suggest ONE git branch name as '<type>/<kebab-slug>' summarising these commits. type in {${HOOKS_BRANCH_TYPES// /, }}. Output only the name.")"
    ai_name="$(printf '%s' "$ai_name" | sed -n '1p' | tr -dc 'a-z0-9/._-')"
    if [[ "$ai_name" =~ ^(${alt})/[a-z0-9][a-z0-9._-]*$ ]]; then
      git branch -m "$ai_name"
      hook::ok "renamed: $branch -> $ai_name"
      hook::warn "re-run your push:  git push -u origin '$ai_name'"
    else
      hook::warn "AI did not return a valid branch name -- aborting push"
    fi
    exit 1
    ;;
  n | *)
    hook::warn "aborted push at your request -- branch unchanged"
    exit 1
    ;;
esac
