#!/usr/bin/env bash
# commit-msg hook -- soft-enforce Conventional Commits (conventionalcommits.org).
# Deterministic auto-fix first; interactive nudge (or AI rewrite) when it cannot
# safely repair the line. A timeout aborts the commit (a nudge to do better).
#
# prek invokes:  scripts/hooks/commit-msg.bash <path-to-commit-msg-file>
set -uo pipefail

HOOK_NAME="commit-msg"
# shellcheck source=scripts/hooks/lib/hooklib.bash
source "$(git rev-parse --show-toplevel)/scripts/hooks/lib/hooklib.bash"
hook::load_config
hook::trap_interrupts

MSG_FILE="${1:?commit-msg hook expects the message file path}"
[[ -f "$MSG_FILE" ]] || exit 0

# Skip machine-generated messages we must not rewrite.
first_line="$(rg -v '^\s*#' "$MSG_FILE" | sed -n '1p')"
[[ -z "${first_line//[[:space:]]/}" ]] && exit 0                       # empty
[[ "$first_line" =~ ^(Merge|Revert|fixup!|squash!|amend!) ]] && exit 0 # generated

# --- 1. de-slop the whole message in place (always, silent if no change) -----
orig_all="$(cat "$MSG_FILE")"
clean_all="$(printf '%s' "$orig_all" | hook::strip_slop)"
if [[ "$clean_all" != "$orig_all" ]]; then
  printf '%s\n' "$clean_all" > "$MSG_FILE"
  hook::info "removed co-author/emoji/filler lines from the commit message"
fi

subject="$(rg -v '^\s*#' "$MSG_FILE" | sed -n '1p')"

# --- 2. already valid? warn on long subject, then pass -----------------------
if hook::cc_valid "$subject"; then
  if ((${#subject} > HOOKS_SUBJECT_MAXLEN)); then
    hook::warn "subject is ${#subject} chars (recommended <= ${HOOKS_SUBJECT_MAXLEN}): $subject"
  fi
  exit 0
fi

# --- 3. try a deterministic fix ---------------------------------------------
fixed="$(hook::cc_autofix_subject "$subject")"

apply_fixed() {
  local body
  body="$(rg -v '^\s*#' "$MSG_FILE" | tail -n +2)"
  {
    printf '%s\n' "$fixed"
    [[ -n "${body//[[:space:]]/}" ]] && printf '%s\n' "$body"
  } > "$MSG_FILE"
  hook::ok "rewrote subject"
  hook::rule "before"
  hook::say "$subject"
  hook::rule "after"
  hook::say "$fixed"
}

# Non-interactive (CI, agent): auto-fix when we can, otherwise warn and pass.
if ! hook::interactive; then
  if hook::cc_valid "$fixed"; then
    apply_fixed
  else
    hook::warn "non-conventional subject left as-is (no tty to confirm a rewrite): $subject"
  fi
  exit 0
fi

# --- 4. interactive nudge ----------------------------------------------------
hook::rule "Conventional Commits check failed"
hook::say "subject: $subject"
if hook::cc_valid "$fixed"; then
  hook::say "suggested: $fixed"
  prompt="apply suggestion? y=apply  e=edit  a=AI fix (local)  n=abort"
  allowed="yean"
else
  hook::say "cannot infer a type automatically (expected: <type>(scope)?: subject)"
  hook::say "types:  ${HOOKS_CC_TYPES}"
  hook::say "scopes: ${HOOKS_CC_SCOPES}"
  prompt="fix how? e=edit  a=AI fix (local)  n=abort"
  allowed="ean"
fi

ans="$(hook::ask "$prompt" "$allowed")"
rc=$?
if ((rc == 3)); then
  hook::warn "timed out after ${HOOKS_TIMEOUT}s -- aborting so you can improve the message"
  hook::say "tip: e.g.  feat(guard): reject overlapping kill windows"
  exit 1
fi

case "$ans" in
  y) hook::cc_valid "$fixed" && {
    apply_fixed
    exit 0
  } ;;
  e)
    "${EDITOR:-${VISUAL:-vi}}" "$MSG_FILE" < /dev/tty > /dev/tty 2>&1 || true
    new_subject="$(rg -v '^\s*#' "$MSG_FILE" | sed -n '1p')"
    hook::cc_valid "$new_subject" && {
      hook::ok "edited subject is conventional"
      exit 0
    }
    hook::warn "edited subject still non-conventional: $new_subject"
    exit 1
    ;;
  a)
    if ! hook::ai_available; then
      hook::warn "AI assist is not configured -- run:  just hooks-ai-setup"
      exit 1
    fi
    hook::info "asking the configured local-first AI for a Conventional-Commits rewrite..."
    rewrite="$(printf '%s' "$orig_all" | hook::ai_run \
      "Rewrite as a single Conventional Commits message: '<type>(scope): subject' (subject <= ${HOOKS_SUBJECT_MAXLEN} chars, imperative), optional body explaining why. Output ONLY the commit message. No co-author lines, no emoji, no preamble.")"
    new_subject="$(printf '%s' "$rewrite" | sed -n '1p')"
    if [[ -n "$rewrite" ]] && hook::cc_valid "$new_subject"; then
      printf '%s\n' "$rewrite" > "$MSG_FILE"
      hook::ok "applied AI rewrite"
      hook::rule "before"
      hook::say "$subject"
      hook::rule "after"
      hook::say "$new_subject"
      exit 0
    fi
    hook::warn "AI did not return a valid conventional subject -- aborting"
    exit 1
    ;;
  n | *)
    hook::warn "aborted at your request -- commit message unchanged"
    exit 1
    ;;
esac

exit 0
