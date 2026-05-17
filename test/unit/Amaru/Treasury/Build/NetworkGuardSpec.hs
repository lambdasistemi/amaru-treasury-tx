{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Build.NetworkGuardSpec
Description : Dispatcher-level network guard for init intents
License     : Apache-2.0

The seven @registry-init-*@, @stake-reward-init-*@, and
@governance-withdrawal-init-*@ sub-actions are DevNet-only in the
current #156 rollout. The decoder still accepts any
@network: Text@ value (parsing is the wrong layer for runtime
policy — see @specs\/157-flatten-devnet-cli\/research.md@) but
'Amaru.Treasury.Build.runBuildExcept' calls
'Amaru.Treasury.Build.requireDevnet' as the first action in every
init dispatch arm, so the dispatcher fails closed with a typed
'BuildError' before any N2C connection or transaction
construction happens.

This spec reads each of the seven happy-path fixture JSONs,
swaps the @network@ field to @\"mainnet\"@, feeds the result to
'runFromIntentEither' against a 'ChainContext' that is itself a
bottom thunk, and asserts the rejection diagnostic. Because
'requireDevnet' runs before any field of the chain context is
forced, the bottom thunk is never evaluated — that IS the proof
the rejection happens before any chain-side work.
-}
module Amaru.Treasury.Build.NetworkGuardSpec (spec) where

import Data.Aeson (Value (..), eitherDecode, encode)
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString.Lazy qualified as BSL
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Build
    ( BuildAction (..)
    , BuildDiagnostic (..)
    , BuildError (..)
    , BuildFailurePhase (..)
    , runFromIntentEither
    )
import Amaru.Treasury.ChainContext (ChainContext)
import Amaru.Treasury.IntentJSON (SomeTreasuryIntent)

-- ----------------------------------------------------
-- Per-sub-action rejection cases
-- ----------------------------------------------------

spec :: Spec
spec =
    describe "dispatcher requireDevnet guard" $ do
        it
            "rejects registry-init-seed-split on mainnet"
            ( expectMainnetRejection
                "test/fixtures/intent/registry-init-seed-split.json"
            )
        it
            "rejects registry-init-mint on mainnet"
            ( expectMainnetRejection
                "test/fixtures/intent/registry-init-mint.json"
            )
        it
            "rejects registry-init-reference-scripts on mainnet"
            ( expectMainnetRejection
                "test/fixtures/intent/registry-init-reference-scripts.json"
            )
        it
            "rejects stake-reward-init-script-account on mainnet"
            ( expectMainnetRejection
                "test/fixtures/intent/stake-reward-init-script-account.json"
            )
        it
            "rejects stake-reward-init-plain-account on mainnet"
            ( expectMainnetRejection
                "test/fixtures/intent/stake-reward-init-plain-account.json"
            )
        it
            "rejects governance-withdrawal-init-proposal on mainnet"
            ( expectMainnetRejection
                "test/fixtures/intent/governance-withdrawal-init-proposal.json"
            )
        it
            "rejects governance-withdrawal-init-materialization on mainnet"
            ( expectMainnetRejection
                "test/fixtures/intent/governance-withdrawal-init-materialization.json"
            )

-- ----------------------------------------------------
-- Helpers
-- ----------------------------------------------------

{- | Load a fixture intent, rewrite its @network@ field to
@\"mainnet\"@, dispatch through 'runFromIntentEither' with a
bottom 'ChainContext', and assert the rejection diagnostic.
-}
expectMainnetRejection :: FilePath -> IO ()
expectMainnetRejection path = do
    some <- loadMainnetIntent path
    result <- runFromIntentEither dummyContext some
    case result of
        Left err -> do
            beAction err `shouldBe` BuildActionIntent
            bePhase err `shouldBe` BuildPhaseUnsupported
            beDiagnostic err
                `shouldBe` DiagnosticUnsupportedNetwork "mainnet"
        Right _ ->
            expectationFailure
                ( "expected requireDevnet rejection, got Right \
                  \(meaning the dispatcher reached the construction \
                  \core for "
                    <> path
                    <> ")"
                )

{- | Read a fixture JSON, swap the @network@ field to
@\"mainnet\"@, and re-decode as 'SomeTreasuryIntent'. The
decoder is supposed to accept any @network: Text@ — confirming
that as a side-effect of this helper succeeding.
-}
loadMainnetIntent :: FilePath -> IO SomeTreasuryIntent
loadMainnetIntent path = do
    raw <- BSL.readFile path
    value <- case eitherDecode raw of
        Left e ->
            errorIO
                ( "NetworkGuardSpec: fixture is not valid JSON ("
                    <> path
                    <> "): "
                    <> e
                )
        Right v -> pure v
    let rewritten = setNetwork "mainnet" value
    case eitherDecode (encode rewritten) of
        Left e ->
            errorIO
                ( "NetworkGuardSpec: decoder rejected mainnet \
                  \payload (the decoder must accept any network: \
                  \Text — guard is a dispatcher concern) for "
                    <> path
                    <> ": "
                    <> e
                )
        Right some -> pure some

-- | Replace the top-level @network@ field of an intent object.
setNetwork :: Value -> Value -> Value
setNetwork newValue (Object o) =
    Object (KM.insert "network" newValue o)
setNetwork _ other = other

{- | 'ChainContext' shaped as a bottom thunk. 'requireDevnet'
runs before any dispatcher arm forces the context, so forcing
this value indicates the guard let the build proceed.
-}
dummyContext :: ChainContext
dummyContext =
    error
        "NetworkGuardSpec: ChainContext was forced before \
        \requireDevnet had a chance to reject the intent — \
        \the dispatcher network guard regressed."

errorIO :: String -> IO a
errorIO = ioError . userError
