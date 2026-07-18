#!/usr/bin/env bash
# Mechanical gate for issue #475 — link books + advertise the inspector.
# Covers the CLI (Haskell) and the frontend (PureScript) surfaces.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

git diff --check

# ---------------------------------------------------------------------------
# CLI (Haskell) — build + unit + golden + format + hlint + smoke.
nix develop --quiet -c bash -lc '
  set -euo pipefail
  cabal build all -O0
  just unit
  just golden
  just format-check
  just hlint
  just smoke
'

# ---------------------------------------------------------------------------
# Frontend (PureScript) — spago build + spago test (Test.Main) via the
# purescript-overlay shell, then the packaged bundle build.
frontend_shell='
let
  f = builtins.getFlake (toString '"$repo_root"');
  system = builtins.currentSystem;
  pkgs = import f.inputs.nixpkgs {
    inherit system;
    overlays = [ f.inputs.purescript-overlay.overlays.default ];
  };
in pkgs.mkShell {
  packages = [ pkgs.purs pkgs.spago-unstable pkgs.esbuild pkgs.nodejs_20 ];
}
'

nix develop --quiet --impure --expr "$frontend_shell" -c bash -lc '
  set -euo pipefail
  cd "$1"

  browser_json_tree=$(nix eval --raw --impure --expr \
    "(builtins.getFlake (toString $1)).inputs.browser-json-tree.outPath")

  vendor_root="$1/frontend/vendor"
  vendor_link="$vendor_root/browser-json-tree"
  made_vendor=0
  if [ ! -e "$vendor_link" ]; then
    mkdir -p "$vendor_root"
    ln -s "$browser_json_tree" "$vendor_link"
    made_vendor=1
  fi
  cleanup() {
    if [ "$made_vendor" = 1 ]; then
      rm -f "$vendor_link"
      rmdir "$vendor_root" 2>/dev/null || true
    fi
  }
  trap cleanup EXIT

  cd frontend
  spago build
  spago test
' bash "$repo_root"

nix build --quiet .#frontend

echo "gate.sh: OK"

# ---------------------------------------------------------------------------
# Helpers used during review / finalization (not part of the run above).

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

finalization_audit() {
  local pr="${1:?usage: finalization_audit <pr-number> <tasks.md>}"
  local task_file="${2:?usage: finalization_audit <pr-number> <tasks.md>}"
  local base_ref base fail=0
  base_ref=$(gh pr view "$pr" --json baseRefName -q .baseRefName)
  git fetch origin "$base_ref" >/dev/null
  base=$(git merge-base "origin/$base_ref" HEAD)
  while read -r sha; do
    if ! commit_gate "$sha" >/dev/null 2>&1; then
      printf '%s\t%s\n' "${sha:0:7}" "$(git show -s --format=%s "$sha")"
      fail=1
    fi
  done < <(git rev-list --reverse "$base..HEAD")
  [ "$fail" -eq 0 ] || return 1
  if grep -nE '^\s*-\s*\[ \]\s*T[0-9]+' "$task_file"; then
    echo "FAIL: open tasks remain in $task_file"
    return 1
  fi
  echo "OK: every commit passes the message gate; $task_file is complete."
}
