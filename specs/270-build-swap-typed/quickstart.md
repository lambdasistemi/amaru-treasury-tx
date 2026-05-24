# Quickstart — `buildSwapTx` + HTTP + `/operate` CBOR & Report

Three smoke recipes — one per user story — that an engineer can run end-to-end after the slice lands.

---

## US1 (P1) — REPL: call `buildSwapTx`, observe typed failure on bad input

```bash
cd /code/amaru-treasury-tx-issue-269   # or the merged worktree
nix develop
cabal repl amaru-treasury-tx
```

```haskell
λ> import Amaru.Treasury.Wizard.Swap (buildSwapTx)
λ> import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
λ> import Control.Monad.Trans.Except (runExceptT)
λ> import Control.Tracer (nullTracer)
λ> :set -XOverloadedStrings

-- Use one of the golden intents shipped under transactions/2026/...
λ> intent <- decodeIntent <$> ByteString.readFile "transactions/2026/network_compliance/.../intent.json"
λ> opts   <- mkDevGlobalOpts
λ> withLocalNodeBackend opts $ \backend ->
     runExceptT (buildSwapTx opts backend intent nullTracer)

-- Right (cborHex, report) on success.
-- Left (WalletUtxoStale {missing = [...]}) on stale wallet UTxOs.
-- The host process IS STILL ALIVE either way — no exitWith.
```

**Expected pass**: `Right` arm carries a `CborHex` non-empty + a `Report` whose `txid` matches the golden fixture.
**Expected fail mode** (try with a deliberately-wrong wallet bech32): `Left WalletAddressUnresolved {address = "..."}` and the REPL stays open.

---

## US2 (P2) — CLI byte-identity smoke

```bash
cd /code/amaru-treasury-tx-issue-269
just unit                                         # full golden corpus
# or, just the swap subset:
cabal test unit-tests --test-show-details=direct \
  --test-option=--match --test-option=BuildSwapGolden
```

**Expected**: zero byte diffs reported. Every fixture in the swap corpus passes unchanged from v0.2.15.0.

```bash
# Single CLI invocation against the dev container, for spot-check:
amaru-treasury-tx swap-wizard \
  --scope core_development \
  --wallet-addr addr1q... \
  --amount-mode FixedUsdm --usdm 1500 \
  --rate-mode RateMin --min-rate 0.50 \
  --validity-hours 48 \
  --description "smoke" \
  --metadata /etc/amaru-treasury/metadata.json \
  > /tmp/intent.json

amaru-treasury-tx tx-build < /tmp/intent.json > /tmp/tx.cbor
amaru-treasury-tx tx-build --report < /tmp/intent.json > /tmp/report.json

# Exit codes:
echo $?
# 0 on success
# 64 on usage error (bad CLI arg)
# 69 on backend unavailable (node socket gone)
# 70 on internal software error (typed failure that maps to "this should not have happened")
```

---

## US3 (P3) — HTTP + `/operate` smoke

```bash
# Backend
curl -sS -X POST https://amaru-treasury.dev.plutimus.com/v1/build/swap \
  -H 'content-type: application/json' \
  -d @specs/270-build-swap-typed/contracts/sample-request.json \
  | jq '{intentJson_present: (.intentJson != null), cborHex_present: (.cborHex != null), report_present: (.report != null), intentFailure, buildFailure, internalError}'
```

**Expected** on a well-formed request body that successfully builds:
```json
{
  "intentJson_present": true,
  "cborHex_present":    true,
  "report_present":     true,
  "intentFailure":      null,
  "buildFailure":       null,
  "internalError":      null
}
```

**Expected** on a wallet-underfunded request:
```json
{
  "intentJson_present": true,
  "cborHex_present":    false,
  "report_present":     false,
  "intentFailure":      null,
  "buildFailure":       { "tag": "WalletUnderfunded", "field": "wallet-address", "detail": "..." },
  "internalError":      null
}
```

```bash
# Frontend
open https://amaru-treasury.dev.plutimus.com/operate
```

Steps:
1. Fill the swap form (scope, wallet, amount, rate, validity, rationale).
2. Click **Build unsigned tx**.
3. Observe:
   - Intent tab populates with the typed JSON tree (existing behaviour).
   - CBOR tab populates with the hex string + a **Copy CBOR** chip.
   - Report tab populates with the typed JSON tree of the build report + a **Copy report** chip.
4. Now intentionally underfund the wallet (edit the address to one with too little ADA) → click Build → observe:
   - Intent tab populates (intent assembly succeeded).
   - CBOR + Report tabs show "not built yet" caption.
   - Status banner reads `build: WalletUnderfunded`.
   - Wallet address input is highlighted red.

---

## Acceptance checklist

- [ ] US1 REPL smoke: `Right` on success, typed `Left` on bad input, REPL stays open on failure.
- [ ] US2 golden corpus: zero byte diffs.
- [ ] US2 CLI exit codes: 64/69/70 match the v0.2.15.0 baseline for the same input bundles.
- [ ] US3 HTTP: all four arms reachable, `cliCommand` always populated.
- [ ] US3 `/operate`: all three preview tabs render real data on success.
- [ ] US3 `/operate`: typed-failure banner + field highlight surface on failure.
- [ ] Build Gate green on every commit in the PR (bisect-safe).
