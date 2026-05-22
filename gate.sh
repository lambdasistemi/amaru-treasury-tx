#!/usr/bin/env bash
# gate.sh — local pre-push gate for the 212 reorganize phase-2 fix PR.
#
# Lifecycle (per the gate-script skill):
#   * created in the first chore: add gate.sh commit on this branch,
#   * extended as the slice plan grows (new focused tests, smoke
#     checks, etc.),
#   * dropped in the very last commit before the PR is marked ready
#     (chore: drop gate.sh (ready for review)).
#
# Mirrors the existing `just ci` recipe (build + schema + unit +
# golden + format-check + hlint + smoke + release-check) and adds
# the commit-message gate enforced for every commit on the branch.
#
# Run from the worktree root: ./gate.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "==> diff --check (no whitespace-only / merge-conflict markers)"
git diff --check

echo "==> nix develop -c just ci"
nix develop --quiet -c just ci

echo "==> commit-message gate (Conventional Commits + Tasks: trailer)"

commit_gate() {
  local sha="${1:?usage: commit_gate <sha>}"
  local subject body
  subject=$(git show -s --format=%s "$sha")
  body=$(git show -s --format=%b "$sha" | sed '/^[[:space:]]*$/d')

  case "$subject" in
    [Ww][Ii][Pp]*|draft*|Draft*|tmp*|Tmp*|temp*|Temp*|fixup!*|squash!*)
      echo "bad subject: $subject"; return 1 ;;
  esac

  printf '%s\n' "$subject" \
    | grep -Eq '^(feat|fix|docs|test|refactor|perf|build|ci|chore|style|revert)(\([^)]+\))?!?: .+' \
    || { echo "subject is not an approved Conventional Commit"; return 1; }

  [ -n "$body" ] || { echo "commit body is empty"; return 1; }

  case "$subject" in
    chore*|docs*|build*|ci*|style*|revert*) ;;
    *)
      printf '%s\n' "$body" \
        | grep -Eq '^Tasks:[[:space:]]*T[0-9]+([[:space:]]*,[[:space:]]*T[0-9]+)*[[:space:]]*$' \
        || { echo "commit body missing 'Tasks: T###[, T###]' trailer"; return 1; }
      ;;
  esac
}

base_ref="${BASE_REF:-origin/main}"
git fetch origin main >/dev/null 2>&1 || true
base=$(git merge-base "$base_ref" HEAD)
fail=0
while read -r sha; do
  if ! commit_gate "$sha"; then
    printf '  %s\t%s\n' "${sha:0:7}" "$(git show -s --format=%s "$sha")"
    fail=1
  fi
done < <(git rev-list --reverse "$base..HEAD")
[ "$fail" -eq 0 ] || { echo "commit-message gate FAILED"; exit 1; }

echo "==> finalization audit (all tasks.md items checked)"
if [ -d specs/212-reorganize-permissions-rewarding-redeemer ]; then
  open=$(grep -nE '^\s*-\s*\[ \]\s*T[0-9]+' specs/212-reorganize-permissions-rewarding-redeemer/tasks.md 2>/dev/null || true)
  if [ -n "$open" ]; then
    echo "INFO: open tasks remain in tasks.md (expected during in-flight slicing):"
    echo "$open"
  fi
fi

echo "==> gate.sh PASS"
