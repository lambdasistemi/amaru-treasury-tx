# Operator-facing brief: dispatch a fresh subagent, do not write it yourself

Mechanical inspection (running `tx-inspect` / `tx-validate`, parsing
the tree, reading `report.json`) is the orchestrator's job. The
**operator-facing pre-submit summary** — the narrative that walks
through the swap economics, slippage, fill probability, net deliverables,
and the go/no-go recommendation — must be produced by a **fresh
subagent with no prior conversation context**.

Why: the orchestrator has been arguing about flag choices, wallet
swaps, witness rounds — its brief will rationalise whatever it built.
A subagent that reads only the on-disk artefacts gives an independent
read and catches things like "the floor rate is below the bottom of
recent execution" or "the signed body disagrees with the archive
summary.md".

Dispatch pattern (the orchestrator launches; the subagent reads cold):

```text
Goal: pre-submit operator brief for an Amaru treasury tx.
Inputs (read these only, ignore the conversation):
  /tmp/attx-<issue>/<flow>/signed-tx.tx
  /tmp/attx-<issue>/<flow>/intent.json
  /tmp/attx-<issue>/<flow>/report.json
  /tmp/attx-<issue>/<flow>/wizard.log
  /tmp/attx-<issue>/<flow>/build.log
  /tmp/attx-<issue>/sundae-market-scan/report.md   # if a swap
  <repo>/transactions/<year>/<scope>/<slug>/summary.md
  <repo>/transactions/README.md
  /code/amaru-treasury/docs/permissions.md         # validator policy
Tools: tx-inspect (with --rules), tx-validate (live n2c socket), jq, awk
Output: ~400-600 word markdown brief with:
  1. one-paragraph plain-English summary
  2. inputs/outputs ledger (every UTxO, value conservation check)
  3. rate economics vs current mid + recent execution band
  4. constant-product slippage model for this size
  5. net deliverables (USDM arriving, ADA consumed, change destinations)
  6. risk checks (TTL, signer roster vs on-chain policy, surprises)
  7. provenance (CLI version, predicted txid, validation status)
  8. independent go/no-go recommendation with reason
Write to <rundir>/pre-submit-brief.md AND print to final message.
```

Show the subagent's brief to the operator verbatim — don't paraphrase,
don't second-guess. If the brief disagrees with the orchestrator's
read, surface the disagreement instead of glossing over it.

This applies to every tx that's about to be submitted, not just swaps.
For disburses / withdrawals / contingency the "economics" section
narrows to "what's being moved and from/to where", but the
independent-reader requirement is the same.
