# Quickstart — Calling the refactored swap wizard

## From the CLI (no change for operators)

```bash
amaru-treasury-tx swap-wizard \
  --scope core_development \
  --wallet-addr addr1q… \
  --usdm 1500 --split 33 \
  --ada-usdm operator-supplied:0.43 \
  --slippage-bps 75 \
  --validity-hours 24 \
  --description "weekly USDM build" \
  --justification "operator decision" \
  --destination-label core_development \
  --metadata /etc/amaru-treasury/metadata.json \
  > intent.json

amaru-treasury-tx tx-build \
  --intent intent.json \
  --report report.json \
  --out tx.cbor
```

Same flags, same output bytes, same operator-visible error text. The non-zero exit code on failure now follows `sysexits.h` families per `spec.md` FR-008: `Input*` failures exit `64` (`EX_USAGE`), `Resolve*` failures exit `69` (`EX_UNAVAILABLE`), `Internal*` failures exit `70` (`EX_SOFTWARE`). Wrapping scripts can branch on family without parsing stderr.

## From a Haskell caller (new)

```haskell
import Amaru.Treasury.Wizard.Swap
    ( buildSwapIntent
    , buildSwapTx
    , ChainEnv (..)
    )
import Amaru.Treasury.Wizard.Failure
    ( WizardFailure
    , BuildFailure
    , renderWizardFailure
    , fieldOf
    )
import Control.Tracer (nullTracer)

doSwap :: GlobalOpts -> WizardOpts -> Backend -> IO ()
doSwap g o backend = do
    -- 1. Build intent (chain → typed value).
    iE <- buildSwapIntent g o backend nullTracer
    case iE of
        Left wf -> do
            putStrLn $ "intent build failed: " <> T.unpack (renderWizardFailure wf)
            case fieldOf wf of
                Just f  -> putStrLn $ "highlight field: " <> show f
                Nothing -> pure ()
        Right intent -> do
            -- 2. Open ChainEnv (snapshot live chain).
            env <- openChainEnv backend
            bE  <- buildSwapTx env intent nullTracer
            case bE of
                Left bf            -> putStrLn $ "tx build failed: " <> T.unpack (renderBuildFailure bf)
                Right (cbor, rep)  -> do
                    BSL.writeFile "tx.cbor" cbor
                    BSL.writeFile "report.json" (encode rep)
```

`nullTracer` opts out of logging. Replace with `Tracer (\e -> atomicModifyIORef' logs (\acc -> (e : acc, ())))` to capture events.

## From a servant handler (follow-up, sketched here for context)

```haskell
swapBuildH :: SwapBuildRequest -> Handler SwapBuildResponse
swapBuildH req = liftIO $ do
    let g = goFromConfig serverConfig
        o = wizardOptsFromRequest req
    iE <- buildSwapIntent g o sharedBackend nullTracer
    case iE of
        Left wf      -> pure (SwapBuildResponse (Just wf) Nothing)
        Right intent -> do
            env <- chainEnvFromCache cacheRef
            bE  <- buildSwapTx env intent nullTracer
            pure case bE of
                Left bf           -> SwapBuildResponse Nothing (Just bf)
                Right (cbor, rep) -> SwapBuildResponse Nothing
                                       (Just (BuildOk intent cbor rep))
```

The servant layer maps the typed failures to status codes (e.g., `Input*` → 400, `Resolve*` → 503, `Internal*` → 500). Out of scope for this slice.

## Smoke test (devnet)

```bash
just devnet-swap-smoke   # already wired; verifies the CLI path end-to-end
```

This recipe MUST stay green across the refactor — it's the operator-facing witness.

## Inner-loop test

```bash
just unit -m "buildSwapIntent\|buildSwapTx\|WizardFailure\|BuildFailure"
```

Runs the new function-level golden + failure-coverage Hspecs without spinning up a node.
