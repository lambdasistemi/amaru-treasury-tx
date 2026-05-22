#!/usr/bin/env bash
# gate.sh — local pre-push gate for the
# 202-may-disburse-cyber-castellum PR (rebased on top of the
# feat/issue-196-disburse-wizard-references branch / PR #197).
#
# Scope: mainnet operator-execution ticket. The gate runs against
# whatever artifacts are present at HEAD (planning artifacts during
# the specs+plan+tasks phase; archive files once the live disburse
# starts producing rundirs under transactions/2026/network_compliance/).
# Because #202 is stacked on top of the disburse-wizard source
# changes from #197, this gate also runs the upstream `just ci`
# recipe (build + schema + unit + golden + format-check + hlint +
# smoke + release-check) so a stale stack does not silently regress
# #197's tests.
#
# Lifecycle (per the gate-script skill):
#   * created in the first `chore: add gate.sh` commit on this branch,
#   * extended as the slice plan grows (archive-completeness, secret
#     greps, principle-VIII v2 conformance checks),
#   * dropped in the very last commit before the PR is marked ready
#     (`chore: drop gate.sh (ready for review)`).
#
# Run from the worktree root: ./gate.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "==> diff --check (no whitespace-only / merge-conflict markers)"
git diff --check

echo "==> nix develop -c just ci"
nix develop --quiet -c just ci

# --- archive-completeness check (active once an archive exists) -----
# The archive layout is set by the acceptance criteria of #202:
#   transactions/2026/network_compliance/<txid>/
#     intent.json
#     tx.cbor
#     tx.envelope.json
#     signed-tx.hex
#     signed-tx.tx
#     submit.log
#     submitted.json
#     summary.md
#     inputs/<parent-txid>.cbor
# This block is a noop until the rundir actually appears in-tree.
ARCHIVE_ROOT=transactions/2026/network_compliance
# Only audit rundirs added by this PR (paths present at HEAD that
# weren't in origin/main). Pre-existing partial archives elsewhere in
# the tree are out of scope for this PR's gate.
base_ref="${BASE_REF:-origin/main}"
git fetch origin main >/dev/null 2>&1 || true
new_rundirs=$(git diff --name-only --diff-filter=A "$base_ref"..HEAD -- "$ARCHIVE_ROOT" 2>/dev/null \
              | grep -oE "^${ARCHIVE_ROOT}/[0-9a-f]{64}" \
              | sort -u)
if [ -n "${new_rundirs:-}" ]; then
  while IFS= read -r dir; do
    [ -z "$dir" ] && continue
    echo "==> archive completeness on $dir"
    for f in intent.json tx.cbor tx.envelope.json signed-tx.hex \
             signed-tx.tx submit.log submitted.json summary.md; do
      [ -f "$dir/$f" ] \
        || { echo "missing $dir/$f"; exit 1; }
    done
    [ -d "$dir/inputs" ] \
      || { echo "missing $dir/inputs/ directory"; exit 1; }
    [ -n "$(ls -A "$dir/inputs" 2>/dev/null)" ] \
      || { echo "$dir/inputs/ has no parent CBORs"; exit 1; }
  done <<< "$new_rundirs"
fi

# --- secret-leak grep ------------------------------------------------
# Match actual key-material shapes, not the words "vault" / "passphrase"
# that legitimately appear in docs and CLI flag definitions:
#   * bech32 addr/ed25519 signing keys (addr_sk1…, ed25519_sk1…, root_xsk1…)
#   * PEM private-key blocks
#   * JWT-shaped tokens (eyJ…\..*\..*)
#   * age secret-key bech32 (AGE-SECRET-KEY-1…)
# Limited to archive + scripts produced by this PR; skill/docs/source
# trees that talk *about* secrets are excluded.
echo "==> secret-leak grep (actual key material in PR-owned paths)"
PR_PATHS=( ':!gate.sh' ':!specs/' ':!.claude/' ':!docs/' ':!lib/' ':!test/' ':!skills/' ':!scripts/smoke/' )
if git grep -nE '(\b(addr_sk|ed25519_sk|root_xsk|stake_sk)1[ac-hj-np-z02-9]{50,}|BEGIN (PRIVATE|ENCRYPTED) KEY|AGE-SECRET-KEY-1[A-Z0-9]{30,}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,})' -- "${PR_PATHS[@]}"; then
  echo "potential secret leak in PR-owned tree"; exit 1
fi

# --- commit-message gate --------------------------------------------
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

# --- finalization audit ---------------------------------------------
echo "==> finalization audit (open tasks)"
if [ -d specs/202-may-disburse-cyber-castellum ]; then
  open=$(grep -nE '^\s*-\s*\[ \]\s*\*?\*?T[0-9]+' \
         specs/202-may-disburse-cyber-castellum/tasks.md 2>/dev/null || true)
  if [ -n "$open" ]; then
    echo "INFO: open tasks remain in tasks.md (expected during in-flight slicing):"
    echo "$open"
  fi
fi

echo "==> gate.sh PASS"
