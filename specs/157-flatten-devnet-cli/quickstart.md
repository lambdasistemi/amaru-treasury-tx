# Quickstart: Build An Init Sub-Action Tx From An Intent

Reproduces the SC-002 golden equivalence locally without a live
DevNet node. The shipped `tx-build` does need a live socket, so the
quickstart focuses on the in-process equivalent (the dispatcher
+ extracted construction core) — the operator path is identical
under the hood.

## 1. Generate a fixture intent

The golden test-support helper materializes a fixture
`bootstrap-intent.json` from the same logical inputs the
corresponding library sub-transaction takes. Example for
`registry-init-seed-split`:

```haskell
import Amaru.Treasury.Devnet.RegistryInit (DevnetRegistryInitConfig(..))
import Amaru.Treasury.IntentJSON (encodeSomeTreasuryIntent)
import qualified Data.ByteString.Lazy as BSL

fixture :: SomeTreasuryIntent
fixture = registryInitSeedSplitIntent
  fundingTxIn fundingAddress seedCount seedLovelace devnetNetwork

main :: IO ()
main = BSL.writeFile "fixtures/registry-init-seed-split.json"
  (encodeSomeTreasuryIntent fixture)
```

## 2. Build via the dispatcher (in-process golden path)

```haskell
import Amaru.Treasury.Build (runFromIntent)
import Amaru.Treasury.IntentJSON (decodeTreasuryIntentFile)

result <- runFromIntent ctx . either error id
  =<< decodeTreasuryIntentFile "fixtures/registry-init-seed-split.json"
-- result :: BuildResult
```

## 3. Build via the extracted construction core directly

```haskell
import Amaru.Treasury.Devnet.RegistryInit (buildSeedSplitCore)

coreResult <- buildSeedSplitCore ctx seedSplitInputs
-- coreResult :: BuildResult
```

## 4. Assert byte-identical CBOR

```haskell
brCborBytes result `shouldBe` brCborBytes coreResult
```

This is the golden assertion shipped by Slice 3a / 3b / 3c per
`plan.md`.

## 5. Live-DevNet exercise (operator path)

Once #158–#160 land, the operator runs:

```bash
registry-init-wizard seed-split > intent.json     # #158
amaru-treasury-tx tx-build --intent intent.json   # #157 (this PR)
amaru-treasury-tx witness --tx ... --signer ...
amaru-treasury-tx submit  --tx ... --witnesses ...
```

For #157 the producer side is the test-support helper from step 1;
the operator-facing wizard ships separately.

## 6. CI coverage

- `nix build .#checks.unit` — `IntentJSONSpec` round-trips +
  `NetworkGuardSpec` rejections for all seven sub-actions.
- `nix build .#checks.golden` — CBOR equivalence per sub-action.
- `just schema-check` — `docs/assets/intent-schema.json` updated.
- `./gate.sh` runs `just ci` which covers all three plus
  format-check, hlint, and the existing smoke suite.

## 7. Removed shortcuts

The previous in-process operator surface
(`amaru-treasury-tx devnet registry-init …` etc.) is gone after
#157. Operators that depended on the old `devnet` supercommand
should migrate to the wizard + `tx-build` chain. Tests and the
DevNet smoke (`SmokeSpec`) keep calling the relocated library
functions directly.
