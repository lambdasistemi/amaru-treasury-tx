#!/usr/bin/env bash
set -euo pipefail

test -f specs/118-vault-witness/spec.md
test -f specs/118-vault-witness/plan.md
test -f specs/118-vault-witness/research.md
test -f specs/118-vault-witness/data-model.md
test -f specs/118-vault-witness/contracts/cli.md
test -f specs/118-vault-witness/quickstart.md
test -f specs/118-vault-witness/tasks.md
test -f specs/118-vault-witness/checklists/requirements.md

if rg -n 'NEEDS CLARIFICATION|\[FEATURE|\[DATE|\$ARGUMENTS|ACTION REQUIRED' \
  --glob '!specs/118-vault-witness/checklists/**' \
  --glob '!specs/118-vault-witness/gate.sh' \
  specs/118-vault-witness
then
  echo "Unresolved Spec Kit placeholder found" >&2
  exit 1
fi

if rg -n "PaymentSigningKeyShelley_ed25519.*cborHex.*[0-9a-fA-F]{32,}" \
  specs/118-vault-witness
then
  echo "Spec artifacts appear to contain concrete signing-key material" >&2
  exit 1
fi

git diff --check
