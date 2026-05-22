#!/usr/bin/env bash
# build-may-cc-disburse.sh — materialise the disburse-wizard argv for
# the May 2026 18 750 USDM CAG/Cyber Castellum disburse from the #201
# manifest and `vendors.yaml`.
#
# This is the canonical way to invoke disburse-wizard for the
# `may-2026-cyber-castellum` disbursement. The script does NOT make any
# live network call by itself — without `--exec` it only prints the argv
# to stdout, ready to be piped into a shell or copied into a runbook;
# with `--exec` it runs `amaru-treasury-tx … disburse-wizard …`
# directly.
#
# Inputs (in-tree, source of truth):
#   * transactions/2026/network_compliance/may-references.json (#201)
#       — the 5-reference evidence set under Principle VIII v2.
#   * vendors.yaml — the CAG payee on-chain address (must NOT be `<TBD>`).
#
# Inputs (operator-supplied, no defaults):
#   * --wallet-addr BECH32   funding wallet (signs alongside script)
#   * --extra-signer BECH32  other network_compliance scope owner
#                            (repeatable for >1 extra signer)
#
# Inputs (defaultable):
#   * --metadata PATH        journal metadata file
#                            (default: /code/amaru-treasury/journal/2026/metadata.json)
#   * --out PATH             rundir where the wizard writes
#                            `intent.json` and the build log
#                            (default: ./build-may-cc-rundir). The
#                            wizard's own `--out` flag points at
#                            `<rundir>/intent.json`; `--log` at
#                            `<rundir>/build.log`.
#   * --log PATH             disburse-wizard build log
#                            (default: <out>/build.log)
#   * --binary NAME          which amaru-treasury-tx to invoke
#                            (default: amaru-treasury-tx)
#   * --destination-label T  rationale destination label
#                            (default: payee canonical legal name)
#   * --description T        rationale description
#                            (default: templated from manifest)
#   * --justification T      rationale justification
#                            (default: templated, names Principle VIII v2)
#
# Constitutional guards (Principle VIII v2):
#   * the manifest's `may-2026-cyber-castellum` block MUST carry exactly
#     5 references with kinds {payee_contract, payee_address_proof,
#     beneficiary_contract, beneficiary_invoice,
#     beneficiary_cycle_review};
#   * the CAG `onchain_address` MUST resolve to a concrete bech32
#     (`<TBD…>` is rejected — see Open Clarification 1).
#
# Exit codes:
#   0  success (argv printed, or `--exec` returned 0)
#   1  any input precondition violated
#   2  amaru-treasury-tx returned non-zero under `--exec`
#
# Usage:
#   scripts/build-may-cc-disburse.sh \
#       --wallet-addr <bech32> \
#       --extra-signer <bech32> \
#       [--metadata journal/2026/metadata.json] \
#       [--out ./build-may-cc-rundir] \
#       [--exec]

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# --- defaults --------------------------------------------------------
EXEC=0
MANIFEST=transactions/2026/network_compliance/may-references.json
VENDORS=vendors.yaml
DISBURSEMENT_ID=may-2026-cyber-castellum
METADATA="/code/amaru-treasury/journal/2026/metadata.json"
OUT=./build-may-cc-rundir
LOG=
BINARY=amaru-treasury-tx
WALLET_ADDR=
EXTRA_SIGNERS=()
DESTINATION_LABEL=
DESCRIPTION=
JUSTIFICATION=
LABEL=

# --- argument parsing -----------------------------------------------
die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --exec)            EXEC=1; shift ;;
    --wallet-addr)     WALLET_ADDR="$2"; shift 2 ;;
    --extra-signer)    EXTRA_SIGNERS+=("$2"); shift 2 ;;
    --metadata)        METADATA="$2"; shift 2 ;;
    --out)             OUT="$2"; shift 2 ;;
    --log)             LOG="$2"; shift 2 ;;
    --binary)          BINARY="$2"; shift 2 ;;
    --destination-label) DESTINATION_LABEL="$2"; shift 2 ;;
    --description)     DESCRIPTION="$2"; shift 2 ;;
    --justification)   JUSTIFICATION="$2"; shift 2 ;;
    --label)           LABEL="$2"; shift 2 ;;
    -h|--help)         sed -n '2,60p' "$0"; exit 0 ;;
    *)                 die "unknown flag: $1 (try --help)" ;;
  esac
done

# --- precondition checks --------------------------------------------
[ -f "$MANIFEST" ] || die "manifest missing: $MANIFEST"
[ -f "$VENDORS" ]  || die "vendors.yaml missing: $VENDORS"
[ -f "$METADATA" ] || die "metadata missing: $METADATA (override with --metadata)"
[ -n "$WALLET_ADDR" ] || die "--wallet-addr is required"
[ "${#EXTRA_SIGNERS[@]}" -ge 1 ] || die "--extra-signer is required (>= 1; permissions.ak demands owner + >=1 other scope owner)"

command -v jq    >/dev/null || die "jq not on PATH"
command -v awk   >/dev/null || die "awk not on PATH"
command -v grep  >/dev/null || die "grep not on PATH"

# --- read CAG bech32 from vendors.yaml ------------------------------
# Minimal YAML reader: extract `onchain_address:` line from the
# `crypto_accounting_group` block. vendors.yaml is small and stable;
# a full YAML dependency is overkill.
CAG_BECH32=$(
  awk '
    /^  - id:[[:space:]]+crypto_accounting_group[[:space:]]*$/ { inblk=1; next }
    inblk && /^  - id:/ { inblk=0 }
    inblk && /^    onchain_address:/ {
      sub(/^[[:space:]]*onchain_address:[[:space:]]*/, "")
      gsub(/^"|"$/, "")
      print
      exit
    }
  ' "$VENDORS"
)
[ -n "$CAG_BECH32" ] || die "could not read crypto_accounting_group.onchain_address from $VENDORS"
case "$CAG_BECH32" in
  '<TBD'*|'<tbd'*|TBD*|tbd*)
    die "crypto_accounting_group.onchain_address is still a placeholder ($CAG_BECH32). Resolve Open Clarification 1 before running this script."
    ;;
  addr1*) ;;  # mainnet bech32 prefix
  *)
    die "crypto_accounting_group.onchain_address does not look like a mainnet bech32 (got: $CAG_BECH32)"
    ;;
esac

# --- read & validate the may-2026-cyber-castellum block -------------
DISB_JSON=$(jq -e --arg id "$DISBURSEMENT_ID" '
  .disbursements[] | select(.id == $id)
' "$MANIFEST") || die "$MANIFEST has no disbursement with id=$DISBURSEMENT_ID"

# Schema sanity (cheap; gate.sh does the full v2 check).
echo "$DISB_JSON" | jq -e '
  (.payee_id        == "crypto_accounting_group") and
  (.beneficiary_id  == "cyber_castellum_corporation") and
  (.amount_usdm     == 18750)
' >/dev/null || die "$DISBURSEMENT_ID block does not match expected (payee=CAG, beneficiary=cyber_castellum_corporation, amount_usdm=18750)"

# Principle VIII v2 minimum evidence set (5 docs for periodic
# beneficiary contracts).
EXPECTED_KINDS='["payee_contract","payee_address_proof","beneficiary_contract","beneficiary_invoice","beneficiary_cycle_review"]'
echo "$DISB_JSON" | jq -e --argjson want "$EXPECTED_KINDS" '
  ([.references[].kind] | sort) == ($want | sort)
' >/dev/null || die "$DISBURSEMENT_ID does not carry the 5-kind evidence set required by Principle VIII v2"

# --- materialise the disburse-wizard argv ---------------------------
# Amount: --amount is in 1e-6 USDM, so 18 750 USDM => 18_750_000_000.
AMOUNT_SCALED=$(jq -nr --argjson n 18750 '$n * 1000000')

# --out is treated as a rundir; the wizard's --out gets <rundir>/intent.json
# and --log defaults to <rundir>/build.log unless the operator overrode it.
RUNDIR="$OUT"
INTENT_OUT="$RUNDIR/intent.json"
[ -n "$LOG" ] || LOG="$RUNDIR/build.log"
if [ "$EXEC" -eq 1 ]; then
  mkdir -p "$RUNDIR"
fi

# Templated rationale text (overridable via --description /
# --justification / --destination-label / --label). The strings
# mirror the cadence of the mainnet d6c14625 precedent — terse,
# factual, no enumeration of evidence in prose (the 5 documents are
# already in references[]). destinationLabel uses natural case (per
# precedent), not the all-caps vendors.yaml legal name; the
# Principle VIII v2 canonical-legal-name rule is scoped to
# references[].label, not the destinationLabel.
[ -n "$DESTINATION_LABEL" ] || DESTINATION_LABEL="Crypto Accounting Group"
[ -n "$DESCRIPTION" ] || DESCRIPTION="Disbursement of 18750 USDM to Crypto Accounting Group for the Cyber Castellum May 2026 invoice."
[ -n "$JUSTIFICATION" ] || JUSTIFICATION="Acceptance of the Cyber Castellum May 2026 cycle review."
[ -n "$LABEL" ] || LABEL="Pay USDM"

# Collect reference triplets verbatim from the manifest, in declared
# order (jq preserves array order).
mapfile -t REF_LINES < <(
  echo "$DISB_JSON" | jq -r '
    .references[]
    | "--reference-uri\t\(.uri)\t--reference-type\t\(.type)\t--reference-label\t\(.label)"
  '
)
[ "${#REF_LINES[@]}" -eq 5 ] || die "expected 5 reference rows, got ${#REF_LINES[@]}"

# Assemble argv.
argv=( "$BINARY" --network mainnet disburse-wizard
       --scope network_compliance
       --unit usdm
       --amount "$AMOUNT_SCALED"
       --beneficiary-addr "$CAG_BECH32"
       --validity-hours 48
       --wallet-addr "$WALLET_ADDR"
       --metadata "$METADATA"
       --out "$INTENT_OUT"
       --log "$LOG"
       --destination-label "$DESTINATION_LABEL"
       --description "$DESCRIPTION"
       --justification "$JUSTIFICATION"
       --label "$LABEL"
)
for s in "${EXTRA_SIGNERS[@]}"; do
  argv+=( --extra-signer "$s" )
done
for line in "${REF_LINES[@]}"; do
  # split on TAB
  IFS=$'\t' read -r u_flag u_val t_flag t_val l_flag l_val <<< "$line"
  argv+=( "$u_flag" "$u_val" "$t_flag" "$t_val" "$l_flag" "$l_val" )
done

# --- emit -----------------------------------------------------------
if [ "$EXEC" -eq 1 ]; then
  command -v "$BINARY" >/dev/null || die "$BINARY not on PATH (override with --binary)"
  mkdir -p "$OUT"
  echo "==> exec: ${argv[*]}" >&2
  exec "${argv[@]}"
fi

# Print one arg per line, shell-quoted, suitable for `bash -c "$(...)"`.
# Continuation lines are emitted for human-readable runbook style.
printf '%q' "${argv[0]}"
for ((i = 1; i < ${#argv[@]}; i++)); do
  case "${argv[$i]}" in
    --*) printf ' \\\n  %q' "${argv[$i]}" ;;
    *)   printf ' %q' "${argv[$i]}" ;;
  esac
done
printf '\n'
