#!/usr/bin/env bash
# verify-may-references.sh — live-boundary smoke for the May 2026
# network_compliance reference manifest. For every reference uri in
# transactions/2026/network_compliance/may-references.json, perform
# an HTTP HEAD against a public IPFS gateway and assert 2xx.
#
# Exits non-zero on the first failing CID. Network required; do not
# run in CI without network.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

MANIFEST=transactions/2026/network_compliance/may-references.json
GATEWAY="${IPFS_GATEWAY:-https://ipfs.io/ipfs}"

if [ ! -f "$MANIFEST" ]; then
  echo "manifest missing: $MANIFEST" >&2
  exit 1
fi

cids=$(jq -r '[.disbursements[].references[].uri] | unique | .[]' "$MANIFEST" \
       | sed 's#^ipfs://##')

fail=0
while read -r cid; do
  [ -z "$cid" ] && continue
  url="$GATEWAY/$cid"
  if curl -fsS -I --max-time 30 "$url" >/dev/null; then
    printf 'PASS  %s\n' "$cid"
  else
    printf 'FAIL  %s\n' "$cid"
    fail=1
  fi
done <<< "$cids"

[ "$fail" -eq 0 ] || { echo "verify-may-references: one or more CIDs unreachable"; exit 1; }
echo "verify-may-references: all CIDs reachable via $GATEWAY"
