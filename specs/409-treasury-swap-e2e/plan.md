# Plan — #409 treasury swap e2e on devnet (design A)

Decision (Q-001 / A-001): implement **A** — datum-faithful treasury swap.
The full deploy + `swapProgram` path (B) is tracked as **#413**.

## Approach

Add a new, **additive** devnet phase `treasury-swap-e2e` that reuses the
verified `scoop-e2e` cascade/pool/scoop machinery but:
- places the order via the shipped `swapOrderDatum` with a **treasury-script
  destination** (derived `CoreDevelopment` treasury hash) and **this run's
  fresh pool ident**, and
- routes the scooped swap output to the **treasury address**, then asserts the
  treasury received the swapped token.

`scoop-e2e` stays untouched as the regression anchor (the ticket allows
"extend scoop-e2e OR add treasury-swap-e2e"; additive is more bisect-safe).

## Tech stack / files

- `test/devnet/Amaru/Treasury/Devnet/SmokeSpec.hs` — the harness (all new code).
- `scripts/smoke/devnet-local` — phase allowlist (+ `treasury-swap-e2e`).
- Run env: `E2E_GENESIS_DIR=/code/cardano-node-clients/devnet/genesis`,
  `SUNDAE_CONTRACTS_DIR=/tmp/attx-409/sundae-contracts`, via `nix develop -c`.

## Pre-applied seam analysis (so the driver doesn't reinvent it)

1. **Treasury hash + address (pure, no deploy).**
   Mirror the swap-ready phase (SmokeSpec.hs:2176, 2210):
   ```haskell
   treasuryTarget <-
       RegistryInit.treasuryTargetFromBlob Testnet
         =<< expectEither "derive #409 treasury script"
               (derivedTreasuryScriptBlob CoreDevelopment)
   let treasuryHash = ttScriptHash treasuryTarget
   ```
   The treasury **destination address** must match what `swapOrderDatum`
   encodes — payment = `ScriptHashObj treasuryHash`, stake =
   `StakeRefBase (ScriptHashObj treasuryHash)`. Use `TreasuryTarget`'s address
   if it is exactly that; otherwise add a tiny helper
   `stakedScriptAddr :: ScriptHash -> Addr`
   (`Addr Testnet (ScriptHashObj h) (StakeRefBase (ScriptHashObj h))`).
   Verify the address the order datum implies == the address the scoop pays ==
   the address the assertion queries. Mismatch here = the order won't fill.

2. **Treasury-destination order** (new `placeTreasurySwapOrder`, mirroring
   `placeGenericSundaeOrder` at SmokeSpec.hs:3019). Build the inline datum with
   the shipped `swapOrderDatum` (Tx/Swap.hs:210) using:
   - `sodTreasuryScriptHash = scriptHashBytes treasuryHash`,
   - `sodPoolId = spuIdent pool`  ← **REQUIRED**: `swapOrderDatum` emits
     `Some(poolId)`, so it must equal this run's scooping pool ident or the
     order validator rejects the scoop (the generic order used `None`),
   - `sodUsdmPolicy/sodUsdmToken = sttPolicy/sttAssetName token` (the swapped
     asset = the test token),
   - owners = 4× `keyHashBytes genesisPaymentKeyHash` (cancel-only; irrelevant
     to scoop), fee = same scooper fee as the foundation,
   - offer = 10_000_000 lovelace, min-received small (e.g. 1) so the
     constant-product payout (9_896_088) clears the minimum.
   Keep the **locked order value identical to the generic order** (14_500_000)
   so the existing scoop constant-product math is unchanged — only the datum's
   destination + pool-id differ.

3. **Scoop to treasury.** Mirror `scoopSundaeOrder` (SmokeSpec.hs:3068) but the
   swapped-token output (the 9_896_088 test tokens) goes to `treasuryAddr`
   instead of `walletAddr`, with the datum the order's destination spec
   requires (`swapOrderDatum` destination datum = `Constr 0 []` ⇒ NoDatum;
   match the generic order's `mkBasicTxOut` no-datum output). Keep pool out,
   withdraw-zero, redeemers, validity exactly as the foundation. Reuse helpers
   (`buildSubmitAndWait`, `poolScoopRedeemer`, `orderScoopRedeemer`, etc.).
   Driver may parameterize the existing `scoopSundaeOrder` by destination OR add
   a `scoopTreasurySwapOrder` variant — driver's call, logged in WIP.md;
   prefer the lower-risk option that keeps `scoop-e2e` byte-for-byte behaviour.

4. **Assertion.** Query the treasury address UTxOs; sum the test-token
   quantity; assert `treasuryTokenQuantity >= 9_896_088` (i.e. `> 0` with the
   real payout). Assert the order UTxO is consumed (`orderConsumed == True`).

5. **Evidence + summary.json.** Add a `TreasurySwapEvidence` (or extend
   `ScoopE2EEvidence`) carrying `treasuryTokenQuantity`, `treasuryAddress`,
   `treasuryScriptHash`, plus the existing scoop/cascade fields. Write
   `summary.json` (phase `treasury-swap-e2e`) with at least: `orderConsumed`
   (true), `treasuryTokenQuantity` (>0), `scoopTxId`, and the cascade hashes
   (settings/pool/pool_stake/order). Mirror `writeScoopE2EArtifacts`
   (SmokeSpec.hs:4521).

6. **Wire the phase.** Add the `it "treasury-swap-e2e: ..."
   (runForPhases ["treasury-swap-e2e"] treasurySwapE2ESmoke)` entry next to the
   scoop-e2e one (SmokeSpec.hs:1235), and add `treasury-swap-e2e` to the phase
   allowlist + the `[[ ... ]]` guard in `scripts/smoke/devnet-local` (lines
   22 and 33).

## Slice breakdown

One cohesive, additive, bisect-safe slice:

- **S1 — `treasury-swap-e2e` phase (the whole proof).** Items 1–6 above. Build
  green (`just ci` compiles devnet-tests), foundation `scoop-e2e` still green,
  new `treasury-swap-e2e` green at the live boundary
  (`treasuryTokenQuantity > 0`). RED→GREEN: write the treasury-balance
  assertion first and confirm it fails while the swap output still targets the
  wallet, then route the scoop to the treasury to go GREEN (record RED evidence
  in WIP.md). If the driver finds a clean internal seam to split, raise a
  Q-file rather than committing a non-functional intermediate.

## Gate / proof

- `./gate.sh` (= `nix develop -c just ci`) green at HEAD.
- Live-boundary proof (recorded in WIP.md + the PR, not in the per-commit gate):
  ```
  E2E_GENESIS_DIR=/code/cardano-node-clients/devnet/genesis \
  SUNDAE_CONTRACTS_DIR=/tmp/attx-409/sundae-contracts \
  nix develop -c scripts/smoke/devnet-local --phase treasury-swap-e2e
  ```
  Expected: `phase treasury-swap-e2e passed`, `orderConsumed=true`,
  `treasuryTokenQuantity` ≥ 9_896_088, a scoop tx id, cascade hashes in
  `summary.json`. Also re-run `--phase scoop-e2e` to confirm no regression.

## Risks

- **Destination/address mismatch** (datum vs scoop output vs query) — the #1
  failure mode; the three must be the identical script-payment+script-stake
  address. Verified at the live boundary.
- **Pool-id constraint** — `Some(poolId)` must equal the fresh pool ident.
- **Datum on a script-address output** — Conway allows no-datum outputs to
  script addresses; the Sundae order validator checks the output matches the
  destination spec. Resolve at GREEN against the node.
