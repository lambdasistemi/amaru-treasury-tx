# #239 T002 — derive the read-only "recent submitted treasury
# txs" manifest at image-build time.
#
# Source: every committed `transactions/2026/<scope>/<txid>/
# summary.md` whose body carries an `- Submitted: <ISO-8601>`
# line. The 10 newest entries (by Submitted timestamp,
# descending) are emitted as `recent-txs.json` matching the
# shape declared in
# `specs/239-treasury-inspect-dashboard/contracts/v1-recent-txs.openapi.yaml`.
#
# Side-effect-free: the derivation has the transactions tree
# as a content-addressed input; bumping the manifest in
# production requires a commit + rebuild + redeploy. There
# is no on-chain query, no external service.
#
# Summaries lacking a `Submitted:` line are silently dropped
# (they're typically historical pre-#172 archives without a
# recorded submission time).

{ pkgs, transactionsDir }:

pkgs.runCommand "amaru-treasury-recent-txs"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.gawk
      pkgs.jq
    ];
  }
  ''
    set -euo pipefail

    work=$(mktemp -d)
    : > "$work/all.tsv"

    while IFS= read -r summary; do
      rel=''${summary#${transactionsDir}/}
      scope=''${rel%%/*}
      rest=''${rel#*/}
      txid=''${rest%%/*}
      submitted=$(
        grep -m1 '^- Submitted:' "$summary" \
        | sed -e 's/^- Submitted:[[:space:]]*//' \
              -e 's/[[:space:]].*$//'
      ) || true
      if [ -n "$submitted" ]; then
        printf '%s\t%s\t%s\n' \
          "$submitted" "$scope" "$txid" >> "$work/all.tsv"
      fi
    done < <(
      find ${transactionsDir} \
        -mindepth 3 -maxdepth 3 \
        -type f -name summary.md \
      | sort
    )

    sort -r "$work/all.tsv" | head -n 10 > "$work/top.tsv"

    mkdir -p $out
    jq -Rn '
      [
        inputs
        | split("\t")
        | {
            rteCardanoscanUrl: ("https://cardanoscan.io/transaction/" + .[2]),
            rteScope: .[1],
            rteSubmittedAt: .[0],
            rteTxid: .[2]
          }
      ]
      | { rtmEntries: . }
    ' < "$work/top.tsv" > $out/recent-txs.json
  ''
