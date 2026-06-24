#!/usr/bin/env bash
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

git diff --check
nix develop --quiet -c just ci

commit_gate() {
    local sha="${1:?usage: commit_gate <sha>}"
    local subject body
    subject=$(git show -s --format=%s "$sha")
    body=$(git show -s --format=%b "$sha" | sed '/^[[:space:]]*$/d')

    case "$subject" in
        WIP* | wip* | draft* | Draft* | tmp* | Tmp* | temp* | Temp* | fixup!* | squash!*)
            echo "bad subject: $subject"
            return 1
            ;;
    esac

    printf '%s\n' "$subject" \
        | grep -Eq '^(feat|fix|docs|test|refactor|perf|build|ci|chore|style|revert)(\([^)]+\))?!?: .+' \
        || {
            echo "subject is not an approved Conventional Commit: $subject"
            return 1
        }

    [ -n "$body" ] || {
        echo "commit body is empty: $sha"
        return 1
    }

    case "$subject" in
        chore* | docs* | build* | ci* | style* | revert*) ;;
        *)
            printf '%s\n' "$body" \
                | grep -Eq '^Tasks:[[:space:]]*T[0-9]+([[:space:]]*,[[:space:]]*T[0-9]+)*[[:space:]]*$' \
                || {
                    echo "commit body missing Tasks trailer: $sha"
                    return 1
                }
            ;;
    esac
}

git fetch origin main >/dev/null 2>&1 || true
base=$(git merge-base origin/main HEAD)
while read -r sha; do
    commit_gate "$sha"
done < <(git rev-list --reverse "$base..HEAD")

echo "==> gate.sh PASS"
