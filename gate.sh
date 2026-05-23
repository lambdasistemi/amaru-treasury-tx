#!/usr/bin/env bash
# gate.sh — local pre-commit gate for the 259-swap-wizard-pure PR.
#
# Bisect-safe contract: every commit on this branch MUST pass this
# gate so the patch series is bisectable end-to-end. Run from the
# worktree root: ./gate.sh
#
# Lifecycle (per the gate-script skill):
#   * created in the first chore: add gate.sh commit on this branch
#   * extended as new checks become relevant during the refactor
#   * dropped in the very last commit before the PR is marked ready
#
# Install as a pre-commit hook (recommended):
#   ln -sf ../../gate.sh .git/hooks/pre-commit
#
# Override the base branch the commit-message gate diffs against:
#   BASE_REF=origin/main ./gate.sh

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "==> diff --check (no whitespace-only / merge-conflict markers)"
git diff --check || {
    echo "FAIL: whitespace or conflict markers in tree"
    exit 1
}

echo "==> nix build .#checks.x86_64-linux.lint .#checks.x86_64-linux.unit"
nix build --quiet --no-link \
    .#checks.x86_64-linux.lint \
    .#checks.x86_64-linux.unit \
    || {
        echo "FAIL: lint or unit check failed"
        exit 1
    }

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
                | grep -Eq '^Tasks:[[:space:]]*T[0-9]+[a-z]?([[:space:]]*,[[:space:]]*T[0-9]+[a-z]?)*[[:space:]]*$' \
                || { echo "commit body missing 'Tasks: T###[a-z]?[, T###[a-z]?]' trailer"; return 1; }
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
[ "$fail" -eq 0 ] || { echo "FAIL: commit-message gate"; exit 1; }

echo "==> gate.sh PASS"
