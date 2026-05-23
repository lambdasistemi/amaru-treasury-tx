#!/usr/bin/env bash
# build-may-antithesis-disburse.sh — materialise the disburse-wizard
# argv for the May 2026 400 000 USDM Antithesis disburse from the #201
# manifest and `vendors.yaml`.
#
# This is the canonical way to invoke disburse-wizard for the
# `may-2026-antithesis` disbursement. The script does NOT make any live
# network call by itself — without `--exec` it only prints the argv to
# stdout, ready to be piped into a shell or copied into a runbook; with
# `--exec` it runs `amaru-treasury-tx … disburse-wizard …` directly.
#
# Principle VIII v3 carve-out A (NDA-blocked beneficiary contract)
# applies to Antithesis: the manifest lists 4 references for
# `may-2026-antithesis` but the on-chain rationale carries only 3 —
# `beneficiary_contract` is omitted, and the omission is acknowledged
# in the `justification` text. The script drops that reference kind
# before assembling the wizard argv.
#
# Inputs (in-tree, source of truth):
#   * transactions/2026/network_compliance/may-references.json (#201)
#       — manifest. The `may-2026-antithesis` block MUST carry the 4
#         references {payee_contract, payee_address_proof,
#         beneficiary_contract, beneficiary_invoice}; the script filters
#         `beneficiary_contract` out under the NDA carve-out.
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
#                            (default: ./build-may-antithesis-rundir).
#   * --log PATH             disburse-wizard build log
#                            (default: <out>/build.log)
#   * --binary NAME          which amaru-treasury-tx to invoke
#                            (default: amaru-treasury-tx)
#   * --destination-label T  rationale destination label
#                            (default: payee canonical legal name)
#   * --description T        rationale description
#                            (default: templated from manifest)
#   * --justification T      rationale justification
#                            (default: templated, names P-VIII v3 A)
#   * --keep-beneficiary-contract
#                            do NOT apply the NDA carve-out (publish all
#                            4 references). Off by default — Antithesis
#                            engagement is NDA-blocked.
#
# Constitutional guards:
#   * the manifest's `may-2026-antithesis` block MUST carry the four
#     kinds {payee_contract, payee_address_proof, beneficiary_contract,
#     beneficiary_invoice};
#   * the CAG `onchain_address` MUST resolve to a concrete bech32
#     (`<TBD…>` is rejected).
#
# Exit codes:
#   0  success (argv printed, or `--exec` returned 0)
#   1  any input precondition violated
#   2  amaru-treasury-tx returned non-zero under `--exec`
#
# Usage:
#   scripts/build-may-antithesis-disburse.sh \
#       --wallet-addr <bech32> \
#       --extra-signer <bech32> \
#       [--metadata journal/2026/metadata.json] \
#       [--out ./build-may-antithesis-rundir] \
#       [--exec]

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# --- defaults --------------------------------------------------------
EXEC=0
MANIFEST=transactions/2026/network_compliance/may-references.json
VENDORS=vendors.yaml
DISBURSEMENT_ID=may-2026-antithesis
METADATA="/code/amaru-treasury/journal/2026/metadata.json"
OUT=./build-may-antithesis-rundir
LOG=
BINARY=amaru-treasury-tx
WALLET_ADDR=
EXTRA_SIGNERS=()
DESTINATION_LABEL=
DESCRIPTION=
JUSTIFICATION=
LABEL=
KEEP_BENEFICIARY_CONTRACT=0
VALIDITY_HOURS=  # empty = let the wizard pick the chain's current horizon

# --- argument parsing -----------------------------------------------
die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --exec)                       EXEC=1; shift ;;
    --keep-beneficiary-contract)  KEEP_BENEFICIARY_CONTRACT=1; shift ;;
    --wallet-addr)                WALLET_ADDR="$2"; shift 2 ;;
    --extra-signer)               EXTRA_SIGNERS+=("$2"); shift 2 ;;
    --metadata)                   METADATA="$2"; shift 2 ;;
    --out)                        OUT="$2"; shift 2 ;;
    --log)                        LOG="$2"; shift 2 ;;
    --binary)                     BINARY="$2"; shift 2 ;;
    --destination-label)          DESTINATION_LABEL="$2"; shift 2 ;;
    --description)                DESCRIPTION="$2"; shift 2 ;;
    --justification)              JUSTIFICATION="$2"; shift 2 ;;
    --label)                      LABEL="$2"; shift 2 ;;
    --validity-hours)             VALIDITY_HOURS="$2"; shift 2 ;;
    -h|--help)                    sed -n '2,75p' "$0"; exit 0 ;;
    *)                            die "unknown flag: $1 (try --help)" ;;
  esac
done

# --- precondition checks --------------------------------------------
[ -f "$MANIFEST" ] || die "manifest missing: $MANIFEST"
[ -f "$VENDORS" ]  || die "vendors.yaml missing: $VENDORS"
[ -f "$METADATA" ] || die "metadata missing: $METADATA (override with --metadata)"
[ -n "$WALLET_ADDR" ] || die "--wallet-addr is required"
[ "${#EXTRA_SIGNERS[@]}" -ge 1 ] || die "--extra-signer is required (>= 1; permissions.ak demands owner + >=1 other scope owner)"

command -v jq   >/dev/null || die "jq not on PATH"
command -v awk  >/dev/null || die "awk not on PATH"
command -v grep >/dev/null || die "grep not on PATH"

# --- read CAG bech32 from vendors.yaml ------------------------------
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
    die "crypto_accounting_group.onchain_address is still a placeholder ($CAG_BECH32)."
    ;;
  addr1*) ;;  # mainnet bech32 prefix
  *)
    die "crypto_accounting_group.onchain_address does not look like a mainnet bech32 (got: $CAG_BECH32)"
    ;;
esac

# --- read & validate the may-2026-antithesis block ------------------
DISB_JSON=$(jq -e --arg id "$DISBURSEMENT_ID" '
  .disbursements[] | select(.id == $id)
' "$MANIFEST") || die "$MANIFEST has no disbursement with id=$DISBURSEMENT_ID"

# Schema sanity.
echo "$DISB_JSON" | jq -e '
  (.payee_id        == "crypto_accounting_group") and
  (.beneficiary_id  == "antithesis_operations_llc") and
  (.amount_usdm     == 400000)
' >/dev/null || die "$DISBURSEMENT_ID block does not match expected (payee=CAG, beneficiary=antithesis_operations_llc, amount_usdm=400000)"

# Manifest carries 4 kinds; the NDA carve-out drops `beneficiary_contract`
# before passing to the wizard (unless --keep-beneficiary-contract).
EXPECTED_KINDS='["payee_contract","payee_address_proof","beneficiary_contract","beneficiary_invoice"]'
echo "$DISB_JSON" | jq -e --argjson want "$EXPECTED_KINDS" '
  ([.references[].kind] | sort) == ($want | sort)
' >/dev/null || die "$DISBURSEMENT_ID does not carry the 4-kind evidence set ({payee_contract, payee_address_proof, beneficiary_contract, beneficiary_invoice})"

# --- materialise the disburse-wizard argv ---------------------------
# Amount: --amount is in 1e-6 USDM, so 400 000 USDM => 400_000_000_000.
AMOUNT_SCALED=$(jq -nr --argjson n 400000 '$n * 1000000')

RUNDIR="$OUT"
INTENT_OUT="$RUNDIR/intent.json"
[ -n "$LOG" ] || LOG="$RUNDIR/build.log"
if [ "$EXEC" -eq 1 ]; then
  mkdir -p "$RUNDIR"
fi

# Templated rationale text (overridable). Strings mirror the d6c14625
# precedent — terse, factual. destinationLabel is natural case (the
# canonical-legal-name rule applies to references[].label, not
# destinationLabel).
#
# Every defaulted string here MUST fit in 64 UTF-8 bytes — the
# Cardano per-text metadatum cap. The wizard does NOT auto-chunk
# description/justification/destinationLabel/label.
[ -n "$DESTINATION_LABEL" ] || DESTINATION_LABEL="Crypto Accounting Group"
[ -n "$DESCRIPTION" ]       || DESCRIPTION="Disburse 400000 USDM to CAG for Antithesis May 2026."
if [ -n "$JUSTIFICATION" ]; then
  :
elif [ "$KEEP_BENEFICIARY_CONTRACT" -eq 1 ]; then
  JUSTIFICATION="Antithesis May 2026 engagement; on-chain testing infra."
else
  JUSTIFICATION="Beneficiary contract omitted: Antithesis NDA (P-VIII v3 A)."
fi
[ -n "$LABEL" ] || LABEL="Pay USDM"

# Collect reference triplets from the manifest. Under the NDA
# carve-out (default), `beneficiary_contract` is dropped.
if [ "$KEEP_BENEFICIARY_CONTRACT" -eq 1 ]; then
  REF_FILTER='.references[]'
  EXPECTED_REF_COUNT=4
else
  REF_FILTER='.references[] | select(.kind != "beneficiary_contract")'
  EXPECTED_REF_COUNT=3
fi
mapfile -t REF_LINES < <(
  echo "$DISB_JSON" | jq -r "
    $REF_FILTER
    | \"--reference-uri\t\(.uri)\t--reference-type\t\(.type)\t--reference-label\t\(.label)\"
  "
)
[ "${#REF_LINES[@]}" -eq "$EXPECTED_REF_COUNT" ] || die "expected $EXPECTED_REF_COUNT reference rows, got ${#REF_LINES[@]}"

# Assemble argv.
argv=( "$BINARY" --network mainnet disburse-wizard
       --scope network_compliance
       --unit usdm
       --amount "$AMOUNT_SCALED"
       --beneficiary-addr "$CAG_BECH32"
       --wallet-addr "$WALLET_ADDR"
       --metadata "$METADATA"
       --out "$INTENT_OUT"
       --log "$LOG"
       --destination-label "$DESTINATION_LABEL"
       --description "$DESCRIPTION"
       --justification "$JUSTIFICATION"
       --label "$LABEL"
)
if [ -n "$VALIDITY_HOURS" ]; then
  argv+=( --validity-hours "$VALIDITY_HOURS" )
fi
for s in "${EXTRA_SIGNERS[@]}"; do
  argv+=( --extra-signer "$s" )
done
for line in "${REF_LINES[@]}"; do
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

# Print one arg per line, shell-quoted, for runbook copy-paste.
printf '%q' "${argv[0]}"
for ((i = 1; i < ${#argv[@]}; i++)); do
  case "${argv[$i]}" in
    --*) printf ' \\\n  %q' "${argv[$i]}" ;;
    *)   printf ' %q' "${argv[$i]}" ;;
  esac
done
printf '\n'
