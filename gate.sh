#!/usr/bin/env bash
# gate.sh — local pre-push gate for the
# 235-constitution-viii-v3 PR.
#
# Scope: constitution amendment + vendors.yaml typing relaxation +
# optional docs runbook update. No source-code edits; no test edits.
# Gate is light: diff-check, secret-leak grep (limited surface),
# commit-message gate.
#
# Lifecycle:
#   * created in the first `chore: add gate.sh` commit on this branch,
#   * extended if needed,
#   * dropped in the very last commit before the PR is marked ready.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "==> diff --check"
git diff --check

# constitution version footer sanity
echo "==> constitution version footer sanity"
if [ -f .specify/memory/constitution.md ]; then
  if ! grep -qE '^\*\*Version\*\*:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' .specify/memory/constitution.md; then
    echo "constitution.md missing semver-shaped version footer"; exit 1
  fi
fi

# secret-leak grep (narrow; constitution + docs are pure text)
echo "==> secret-leak grep (actual key material in PR-owned paths)"
PR_PATHS=( ':!gate.sh' ':!specs/' ':!.claude/' ':!docs/' ':!lib/' ':!test/' ':!skills/' ':!scripts/smoke/' )
if git grep -nE '(\b(addr_sk|ed25519_sk|root_xsk|stake_sk)1[ac-hj-np-z02-9]{50,}|BEGIN (PRIVATE|ENCRYPTED) KEY|AGE-SECRET-KEY-1[A-Z0-9]{30,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,})' -- "${PR_PATHS[@]}"; then
  echo "potential secret leak in PR-owned tree"; exit 1
fi

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

echo "==> finalization audit (open tasks)"
if [ -d specs/235-constitution-viii-v3 ]; then
  open=$(grep -nE '^\s*-\s*\[ \]\s*\*?\*?T[0-9]+' specs/235-constitution-viii-v3/tasks.md 2>/dev/null || true)
  if [ -n "$open" ]; then
    echo "INFO: open tasks remain in tasks.md (expected during in-flight slicing):"
    echo "$open"
  fi
fi

echo "==> gate.sh PASS"
