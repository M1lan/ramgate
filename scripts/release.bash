#!/usr/bin/env bash
# release.bash -- cut a SemVer release for ramgate (LOCAL, no network, no auto-commit).
#
# What it does:
#   1. reads VERSION, bumps it by the requested part (major|minor|patch);
#   2. writes the new VERSION file;
#   3. syncs the readonly RG_VERSION='x.y.z' line in BOTH bin/ram-xray and bin/ram-guard
#      (that one line only -- nothing else in the binaries is touched);
#   4. regenerates CHANGELOG.md via git-cliff (falls back to a pure-bash Conventional-
#      Commits generator, and SAYS SO, if git-cliff is absent);
#   5. prints the `git tag vX.Y.Z` command for you to run.
#
# It NEVER commits and NEVER tags -- that stays a deliberate human step.
#
# Usage:
#   bash scripts/release.bash <major|minor|patch> [--dry-run]
#   just release patch
set -uo pipefail
trap 'exit 130' INT TERM HUP

if [ -z "${BASH_VERSINFO+set}" ] || ((BASH_VERSINFO[0] < 5)); then
  printf 'error: release.bash requires GNU bash >= 5\n' >&2
  exit 1
fi

part=""
dry_run=0
for arg in "$@"; do
  case "$arg" in
    major | minor | patch) part="$arg" ;;
    --dry-run) dry_run=1 ;;
    -h | --help)
      printf 'usage: release.bash <major|minor|patch> [--dry-run]\n'
      exit 0
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$arg" >&2
      exit 64
      ;;
  esac
done

if [[ -z "$part" ]]; then
  printf 'usage: release.bash <major|minor|patch> [--dry-run]\n' >&2
  exit 64
fi

repo_root="$(git rev-parse --show-toplevel 2> /dev/null)" || {
  printf 'error: not inside a git repository\n' >&2
  exit 1
}
cd "$repo_root" || exit 1

log() { printf '[release] %s\n' "$*"; }

# --- 1. read + bump VERSION -------------------------------------------------
[[ -f VERSION ]] || {
  printf 'error: no VERSION file at repo root\n' >&2
  exit 1
}
cur="$(tr -d '[:space:]' < VERSION)"
if [[ ! "$cur" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  printf 'error: VERSION is not a bare X.Y.Z: %q\n' "$cur" >&2
  exit 1
fi
major="${BASH_REMATCH[1]}"
minor="${BASH_REMATCH[2]}"
patch="${BASH_REMATCH[3]}"
case "$part" in
  major)
    major=$((major + 1))
    minor=0
    patch=0
    ;;
  minor)
    minor=$((minor + 1))
    patch=0
    ;;
  patch) patch=$((patch + 1)) ;;
esac
new="${major}.${minor}.${patch}"
log "version: ${cur} -> ${new} (${part})"

# --- 2. write VERSION -------------------------------------------------------
if ((dry_run)); then
  log "(dry-run) would write VERSION=${new}"
else
  printf '%s\n' "$new" > VERSION
  log "wrote VERSION=${new}"
fi

# --- 3. sync RG_VERSION in both binaries (that line only) -------------------
sync_binary() {
  local bin="$1"
  [[ -f "$bin" ]] || {
    printf 'error: missing %s\n' "$bin" >&2
    return 1
  }
  if ! rg -q "^readonly RG_VERSION='[^']*'" "$bin"; then
    printf 'error: no readonly RG_VERSION line in %s\n' "$bin" >&2
    return 1
  fi
  if ((dry_run)); then
    log "(dry-run) would set RG_VERSION='${new}' in ${bin}"
    return 0
  fi
  # GNU sed (Homebrew): replace only the pinned readonly line.
  local sed_bin
  sed_bin="$(command -v gsed || command -v sed)"
  "$sed_bin" -i -E "s/^readonly RG_VERSION='[^']*'/readonly RG_VERSION='${new}'/" "$bin"
  log "synced RG_VERSION='${new}' in ${bin}"
}
sync_binary bin/ram-xray || exit 1
sync_binary bin/ram-guard || exit 1

# --- 4. regenerate CHANGELOG.md ---------------------------------------------
regen_changelog_cliff() {
  # --tag makes cliff treat the (as-yet-untagged) HEAD as the new release.
  if ((dry_run)); then
    log "(dry-run) would run: git-cliff --tag v${new} -o CHANGELOG.md"
    return 0
  fi
  git-cliff --tag "v${new}" -o CHANGELOG.md 2> /dev/null
}

regen_changelog_fallback() {
  # Pure-bash Conventional-Commits changelog since the last tag. Degraded output:
  # flat, no perfect grouping -- but never blocks a release when git-cliff is absent.
  log "git-cliff not installed -- using the pure-bash fallback generator (DEGRADED)."
  log "install git-cliff for full Keep-a-Changelog output:  brew install git-cliff"
  ((dry_run)) && {
    log "(dry-run) would regenerate CHANGELOG.md via the bash fallback"
    return 0
  }
  local last_tag range date_str tmp
  last_tag="$(git describe --tags --abbrev=0 2> /dev/null || true)"
  if [[ -n "$last_tag" ]]; then range="${last_tag}..HEAD"; else range="HEAD"; fi
  date_str="$(date +%Y-%m-%d)"
  tmp="$(mktemp "${TMPDIR:-$HOME/tmp}/ramgate-changelog.XXXXXX")" 2> /dev/null ||
    tmp="$(mktemp)"
  {
    printf '# Changelog\n\n'
    printf 'All notable changes to ramgate. Format follows [Keep a Changelog](https://keepachangelog.com/);\n'
    printf 'this project adheres to [Semantic Versioning](https://semver.org/).\n\n'
    printf '## [%s] - %s\n\n' "$new" "$date_str"
    local group label pat any
    for group in "feat:Added" "fix:Fixed" "perf:Performance" "refactor:Changed" \
      "docs:Documentation" "test:Testing" "build:Build" "ci:CI" "chore:Miscellaneous"; do
      pat="${group%%:*}"
      label="${group##*:}"
      any="$(git log "$range" --no-merges --pretty=format:'%s' 2> /dev/null |
        rg "^${pat}(\(.+\))?!?: " || true)"
      [[ -z "$any" ]] && continue
      printf '### %s\n\n' "$label"
      printf '%s\n' "$any" | sed -E "s/^${pat}(\(([^)]*)\))?!?: /- /" |
        sed -E 's/^- /- /'
      printf '\n'
    done
    # Preserve any pre-existing history below the newest entry, if the old file exists.
    if [[ -f CHANGELOG.md ]]; then
      local prior
      prior="$(rg -n '^## \[' CHANGELOG.md | sed -n '1p' | cut -d: -f1)"
      if [[ -n "$prior" ]]; then
        tail -n "+$((prior))" CHANGELOG.md
      fi
    fi
  } > "$tmp"
  mv "$tmp" CHANGELOG.md
  log "regenerated CHANGELOG.md (bash fallback)"
}

if command -v git-cliff > /dev/null 2>&1; then
  if regen_changelog_cliff; then
    ((dry_run)) || log "regenerated CHANGELOG.md via git-cliff"
  else
    printf 'error: git-cliff failed to regenerate CHANGELOG.md\n' >&2
    exit 1
  fi
else
  regen_changelog_fallback
fi

# --- 5. next steps ----------------------------------------------------------
log "done. Review the diff, then commit and tag:"
printf '\n'
printf '    git add VERSION CHANGELOG.md bin/ram-xray bin/ram-guard\n'
printf "    git commit -m 'chore(release): v%s'\n" "$new"
printf '    git tag v%s\n' "$new"
printf '\n'
((dry_run)) && log "(dry-run: no files were modified)"
exit 0
