# Quickstart — `reorganize-wizard` runner

**Slice**: S2 (after the live runner lands)
**Status**: ships in PR #198

After this PR merges, an operator on a local DevNet runs the
following two commands and observes an unsigned Conway tx in
`tx.unsigned.cbor`:

## Step 1 — produce the intent JSON

```bash
amaru-treasury-tx reorganize-wizard \
  --network devnet \
  --node-socket "$CARDANO_NODE_SOCKET_PATH" \
  --metadata journal/2026/metadata.json \
  --wallet-addr "$WALLET_BECH32" \
  --funding-seed-txin "$FUNDING_TXIN" \
  --scope core_development \
  --out /tmp/reorganize-intent.json
```

**What happens** (cheap-first ordering):

1. `--network devnet` accepted (any other value → exit 2 with
   `ReorganizeNonDevnetNetwork "<name>"`).
2. `--out`'s parent directory `/tmp` checked to exist (missing →
   exit 2 with `ReorganizeOutputParentMissing`).
3. `--node-socket` resolved (`CARDANO_NODE_SOCKET_PATH` is the
   fallback; missing → exit 2 with
   `ReorganizeMissingNodeSocket`).
4. N2C backend opened against the socket.
5. `--metadata journal/2026/metadata.json` read + decoded into
   `TreasuryMetadata` (missing / unparseable → exit 2 with
   `ReorganizeMetadataReadError`).
6. The `core_development` scope is looked up in the metadata's
   `tmTreasuries` (absent → exit 2 with
   `ReorganizeScopeNotInMetadata`).
7. The scope's `owner` key-hash is required to be non-null
   (null → exit 2 with `ReorganizeScopeOwnerMissing`).
8. The wallet's UTxOs at `--wallet-addr` are queried (empty →
   exit 2 with `ReorganizeWalletShortfall`).
9. The treasury's UTxOs at the scope's `address` are queried;
   if fewer than 2 are present (a reorganize of <2 UTxOs is a
   no-op) → exit 2 with
   `ReorganizeInsufficientTreasuryUtxos N`.
10. Upper-bound slot computed (`--validity-hours` → auto-longest
    if omitted, exact-hours otherwise; `Just 0` → exit 2 with
    `ReorganizeValidityHoursZero`; overshoot → exit 2 with
    `ReorganizeValidityOvershoot`).
11. The intent is encoded as a bare `SomeTreasuryIntent` JSON
    and written to `/tmp/reorganize-intent.json`.

**Exit 0** — the file is on disk. (See `data-model.md` for the
field-by-field shape.)

## Step 2 — build the unsigned Conway CBOR

```bash
amaru-treasury-tx tx-build \
  --intent /tmp/reorganize-intent.json \
  --out tx.unsigned.cbor
```

This already works on `main` (the dispatcher arm for `SReorganize`
was wired by #185). After step 1 + 2:

- `tx.unsigned.cbor` carries the unsigned Conway tx body.
- Sign + submit with `amaru-treasury-tx attach-witness …` and a
  `cardano-cli` submit (out of scope for this slice; see the
  `amaru-treasury-tx` skill for the operator pattern).

## What this slice DOES NOT do

- **Sign or submit.** The runner produces JSON; the dispatcher
  produces unsigned CBOR. Operator keys are out of scope
  (Principle IV).
- **Run a live DevNet smoke.** That's #87's job. CI does not
  invoke either step.
- **Validate `--event` overrides against the constitutional enum.**
  The default (`"reorganize"`) is in the enum; operator overrides
  are accepted at face value (the SundaeSwap indexer is the
  downstream verifier).
- **Cross-check `--funding-seed-txin` against the wallet-addr
  query result.** The operator-typed seed is trusted verbatim
  per Q-001-C1.
- **Cap the treasury-UTxO selection at a body-size bound.** All
  visible UTxOs at the scope's treasury address are taken per
  Q-001-E1; the dispatcher surfaces the body-size error if the
  result is too big.

## Common failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `ReorganizeNonDevnetNetwork "preprod"` | `--network preprod` (or `mainnet`, or `preview`) | Use `--network devnet`. |
| `ReorganizeOutputParentMissing "/tmp/foo"` | Typo in `--out` path; parent dir doesn't exist | `mkdir -p /tmp/foo` or fix the path. |
| `ReorganizeMissingNodeSocket` | `--node-socket` flag absent AND `CARDANO_NODE_SOCKET_PATH` env unset | Set the env or pass the flag. |
| `ReorganizeMetadataReadError "<path>: openBinaryFile: does not exist"` | Typo in `--metadata` path | Fix the path. |
| `ReorganizeMetadataReadError "Error in $..."` | `metadata.json` parse error (truncated, missing required field) | Verify against `journal/2026/metadata.json` upstream. |
| `ReorganizeScopeNotInMetadata <scope>` | Typo in `--scope`; scope not configured | Use one of `core_development`, `ops_and_use_cases`, `network_compliance`, `middleware`. |
| `ReorganizeScopeOwnerMissing <scope>` | The named scope has no `owner` (only contingency may); contingency cannot reorganize | Pick a different scope, or amend `metadata.json` upstream. |
| `ReorganizeInsufficientTreasuryUtxos 0` | The scope's treasury address has no UTxOs visible to the chain query | Wait for inflows; or use `treasury-inspect` to confirm chain state. |
| `ReorganizeInsufficientTreasuryUtxos 1` | The scope's treasury address has exactly 1 UTxO (no merge possible) | Wait for inflows; reorganize needs ≥ 2. |
| `ReorganizeWalletShortfall` | The wallet at `--wallet-addr` has no UTxOs at all | Fund the wallet, or use a different `--wallet-addr`. |
| `ReorganizeValidityHoursZero` | `--validity-hours 0` (zero-length window) | Use `--validity-hours N` with N > 0, or omit (auto-longest). |
| `ReorganizeValidityOvershoot <HorizonError>` | `--validity-hours N` exceeds the chain's safe horizon | Lower N. |
| `ReorganizeLedgerFieldParseError "treasuryUtxos[<n>]" "<msg>"` | A chain-query row's `txid#ix` was malformed (rare; indicates a backend bug) | Re-query; verify N2C provider version. |
| `ReorganizeLedgerFieldParseError "permissionsRewardAccount" "<msg>"` | The derived bech32 reward account failed to construct (rare; indicates a script-hash format issue) | Re-check `metadata.json`'s `permissions_script.hash` field; it must be 28-byte hex. |

## After the runner produces the intent

The intent file is suitable for:

- `tx-build --intent <file>` (already wired by #185).
- Inspection via `tx-inspect` (`cardano-tx-tools` companion).
- Diffing via `tx-diff` against a prior intent.

The file is operator-readable JSON — no extra envelope, no
binary frame. Re-running the wizard with the same inputs is
idempotent modulo the upper-bound slot (which samples the chain
tip; a few seconds of clock drift produces a different slot).
