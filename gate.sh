#!/usr/bin/env bash
# gate.sh — local pre-push gate for #210 constitution Principle VIII v2.
#
# Scope: docs (.specify/memory/constitution.md) + new YAML registry
# (vendors.yaml at repo root) + CHANGELOG bullet. No Haskell source
# touched, so `just ci` is intentionally skipped.
#
# Lifecycle: created in chore: add gate.sh, dropped in chore: drop
# gate.sh (ready for review). See gate-script skill.
#
# Run from worktree root: ./gate.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

CONSTITUTION=.specify/memory/constitution.md
VENDORS=vendors.yaml

echo "==> diff --check"
git diff --check

if [ -f "$VENDORS" ]; then
  echo "==> yaml parse: $VENDORS"
  if command -v yq >/dev/null 2>&1; then
    yq eval '.' "$VENDORS" >/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "import sys,yaml; yaml.safe_load(open('$VENDORS'))"
  else
    echo "no yaml parser (yq/python3) on PATH — skipping parse"
  fi

  echo "==> vendors.yaml schema + required entries"
  if command -v yq >/dev/null 2>&1; then
    schema=$(yq eval '.schema' "$VENDORS")
    [ "$schema" = "amaru-treasury-vendors-v1" ] \
      || { echo "schema must be amaru-treasury-vendors-v1, got $schema"; exit 1; }
    for id in crypto_accounting_group cyber_castellum_corporation antithesis_operations_llc; do
      yq eval ".vendors[] | select(.id == \"$id\") | .id" "$VENDORS" \
        | grep -q "$id" \
        || { echo "vendors.yaml missing entry id=$id"; exit 1; }
    done
  fi
fi

if [ -f "$CONSTITUTION" ]; then
  echo "==> constitution version footer + Principle VIII v2 markers"
  grep -Eq '^\*\*Version\*\*: 0\.4\.0 \| \*\*Ratified\*\*: 2026-05-04 \| \*\*Last Amended\*\*: 2026-05-22' "$CONSTITUTION" \
    || { echo "constitution version footer must read 0.4.0 / 2026-05-04 / 2026-05-22"; exit 1; }
  grep -q 'The repository-root file' "$CONSTITUTION" \
    || { echo "Principle VIII does not reference vendors.yaml as source of truth"; exit 1; }
  grep -q '#### Two vendor roles' "$CONSTITUTION" \
    || { echo "Principle VIII missing payee+beneficiary section"; exit 1; }
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

echo "==> finalization audit (all tasks.md items checked)"
if [ -d specs/210-constitution-principle-viii-v2 ]; then
  open=$(grep -nE '^\s*-\s*\[ \]\s*T[0-9]+' specs/210-constitution-principle-viii-v2/tasks.md 2>/dev/null || true)
  if [ -n "$open" ]; then
    echo "INFO: open tasks remain in tasks.md (expected during in-flight slicing):"
    echo "$open"
  fi
fi

echo "==> gate.sh PASS"
