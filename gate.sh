#!/usr/bin/env bash
set -euo pipefail

# Docs-only PR: verify the new skill content is structurally sound
# without invoking the full Haskell build. The existing CI will run
# the build/unit/golden/format suites on the PR.

git diff --check

# Every SKILL.md must start with YAML frontmatter carrying `name:`
# and `description:` (agentskills.io contract).
fail=0
while IFS= read -r -d '' skill; do
  if ! head -1 "$skill" | grep -q '^---$'; then
    echo "FAIL: $skill missing opening --- frontmatter delimiter" >&2
    fail=1
    continue
  fi
  if ! head -20 "$skill" | grep -Eq '^name:[[:space:]]'; then
    echo "FAIL: $skill missing 'name:' in frontmatter" >&2
    fail=1
  fi
  if ! head -20 "$skill" | grep -Eq '^description:[[:space:]]'; then
    echo "FAIL: $skill missing 'description:' in frontmatter" >&2
    fail=1
  fi
done < <(find skills -name SKILL.md -print0)

# Every references/*.md the skill body links to must exist.
while IFS= read -r -d '' skill; do
  dir=$(dirname "$skill")
  # Extract `references/<file>.md` markdown link targets.
  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    if [ ! -f "$dir/$ref" ]; then
      echo "FAIL: $skill references missing $dir/$ref" >&2
      fail=1
    fi
  done < <(grep -oE '\(references/[A-Za-z0-9_-]+\.md' "$skill" | sed 's/^(//')
done < <(find skills -name SKILL.md -print0)

[ "$fail" -eq 0 ] || exit 1
echo "gate.sh: skill structure OK"
