#!/usr/bin/env bash
# gate.sh — local pre-push gate for the 201-ipfs-pin-may-references PR.
#
# Scope: JSON-data + docs ticket (no Haskell source touched).
# The gate validates the manifest JSON shape, optionally exercises the
# verify script if present, and enforces Conventional Commits + Tasks:
# trailer on every commit between origin/main and HEAD.
#
# Lifecycle (per the gate-script skill):
#   * created in the first chore: add gate.sh commit on this branch,
#   * extended as the slice plan grows,
#   * dropped in the very last commit before the PR is marked ready
#     (chore: drop gate.sh (ready for review)).
#
# Run from the worktree root: ./gate.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

MANIFEST=transactions/2026/network_compliance/may-references.json

echo "==> diff --check (no whitespace-only / merge-conflict markers)"
git diff --check

if [ -f "$MANIFEST" ]; then
  echo "==> jq sanity on $MANIFEST"
  jq -e '.' "$MANIFEST" >/dev/null

  echo "==> schema fields present (v2: payee+beneficiary model)"
  jq -e '
    .schema == "amaru-treasury-may-references-v2" and
    .scope == "network_compliance" and
    .month == "2026-05" and
    .constitution_principle == "VIII" and
    .constitution_version == "0.4.0" and
    (.disbursements | type == "array" and length >= 1)
  ' "$MANIFEST" >/dev/null \
    || { echo "manifest fails schema invariants"; exit 1; }

  echo "==> each disbursement has payee_id, beneficiary_id, and minimum evidence set"
  # Principle VIII v2: when payee != beneficiary, minimum is 4 docs
  # (payee contract + payee address proof + beneficiary contract +
  # beneficiary invoice), 5 if a cycle review applies.
  jq -e '
    .disbursements
    | all(
        (.id | type == "string" and length > 0)
        and (.payee_id | type == "string" and length > 0)
        and (.beneficiary_id | type == "string" and length > 0)
        and (.amount_usdm | type == "number")
        and (
          [.references[].kind]
          | (any(. == "payee_contract"))
            and (any(. == "payee_address_proof"))
            and (any(. == "beneficiary_contract"))
            and (any(. == "beneficiary_invoice"))
        )
      )
  ' "$MANIFEST" >/dev/null \
    || { echo "manifest fails per-disbursement minimum evidence set"; exit 1; }

  echo "==> every reference has uri/type/label/vendor_id and ipfs:// scheme"
  jq -e '
    [.disbursements[].references[]]
    | all(
        (.uri | startswith("ipfs://"))
        and (.type | type == "string")
        and (.label | type == "string" and length > 0)
        and (.vendor_id | type == "string" and length > 0)
        and (.kind | type == "string" and length > 0)
      )
  ' "$MANIFEST" >/dev/null \
    || { echo "manifest reference rows malformed"; exit 1; }

  echo "==> no placeholder CIDs"
  if grep -E '<CID|__PLACEHOLDER__|TODO|TBD' "$MANIFEST"; then
    echo "manifest still contains placeholder markers"; exit 1
  fi
fi

if [ -x scripts/verify-may-references.sh ] && [ -f "$MANIFEST" ]; then
  echo "==> scripts/verify-may-references.sh"
  ./scripts/verify-may-references.sh
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
if [ -d specs/201-ipfs-pin-may-references ]; then
  open=$(grep -nE '^\s*-\s*\[ \]\s*T[0-9]+' specs/201-ipfs-pin-may-references/tasks.md 2>/dev/null || true)
  if [ -n "$open" ]; then
    echo "INFO: open tasks remain in tasks.md (expected during in-flight slicing):"
    echo "$open"
  fi
fi

echo "==> gate.sh PASS"
