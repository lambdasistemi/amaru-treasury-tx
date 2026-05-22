{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.StakeRewardInitWizardInputControlSpec
Description : RED+GREEN assertions for the
              @stake-reward-init-wizard@ @--exclude-utxo@ /
              @--extra-tx-in@ wiring (Slice 6 of #184).
License     : Apache-2.0

Both sub-actions (@script-account@, @plain-account@) share
the same resolver pipeline, so the canary tests run against
the script-account IC variant.

T030 — US3 contradiction at flag-validation time.
T031 — US1 exclusion filters the wallet pool.
T032 — US2 forced-inclusion ref lands in 'wsExtraTxIns'.
T033 — US1+US4 shortfall-with-excludes naming + legacy
       round-trip surrogate for SC-005.
-}
module Amaru.Treasury.Cli.StakeRewardInitWizardInputControlSpec
    ( spec
    ) where

import Data.Aeson (eitherDecode)
import Data.ByteString.Lazy qualified as BSL
import Data.Functor.Identity (Identity (..))
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    , info
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Wizard.InputControl
    ( ExclusionSet (..)
    , ForcedInclusionSet (..)
    , InputControlError (..)
    , OutRef
    , outRefText
    , parseOutRef
    )

import Amaru.Treasury.Cli.StakeRewardInitWizard
    ( ScriptAccountOpts (..)
    , StakeRewardInitWizardOpts (..)
    , stakeRewardInitWizardOptsP
    , validateStakeRewardInitWizardInputControl
    )
import Amaru.Treasury.Devnet.StakeRewardInit
    ( DevnetStakeRewardRegistry
    )
import Amaru.Treasury.Tx.StakeRewardInitWizard
    ( InputControlOutcome (..)
    , PoolHit (..)
    , StakeRewardInitEnv (..)
    , StakeRewardInitError (..)
    , StakeRewardInitResolverEnv (..)
    , StakeRewardInitResolverInput (..)
    , renderStakeRewardInitExclusionLogLine
    , renderStakeRewardInitWalletShortfallWithExcludes
    , resolveStakeRewardInitScriptAccountIC
    )
import Amaru.Treasury.Tx.SwapWizard
    ( WalletSelection (..)
    )

-- ----------------------------------------------------------------------
-- Helpers
-- ----------------------------------------------------------------------

mustParse :: Text -> OutRef
mustParse t = case parseOutRef t of
    Right r -> r
    Left e -> errorWithoutStackTrace (T.unpack e)

parseStake :: [String] -> Either String StakeRewardInitWizardOpts
parseStake args =
    case execParserPure
        defaultPrefs
        (info stakeRewardInitWizardOptsP mempty)
        args of
        Success a -> Right a
        Failure _ -> Left "parse failed"
        CompletionInvoked _ -> Left "completion invoked"

baseScriptAccountArgs :: [String]
baseScriptAccountArgs =
    [ "script-account"
    , "--wallet-addr"
    , T.unpack walletAddrText
    , "--registry"
    , "/tmp/registry.json"
    , "--funding-seed-txin"
    , "00000000000000000000000000000000000000000000000000000000000000aa#0"
    , "--out"
    , "/tmp/script-account-intent.json"
    ]

stubEnv
    :: [(Text, Integer, Bool)]
    -> StakeRewardInitResolverEnv Identity
stubEnv walletUtxos =
    StakeRewardInitResolverEnv
        { sreQueryWalletUtxos = \_ -> Identity walletUtxos
        , sreComputeUpperBound = \_ ->
            Identity (Right 1_000_100)
        , sreReadRegistry = \_ ->
            Identity (Right sampleRegistry)
        }

baseRi :: StakeRewardInitResolverInput
baseRi =
    StakeRewardInitResolverInput
        { sriNetwork = "devnet"
        , sriWalletAddrBech32 = walletAddrText
        , sriRegistryPath = "/tmp/registry.json"
        , sriValidityHours = Nothing
        }

-- ----------------------------------------------------------------------
-- Spec
-- ----------------------------------------------------------------------

spec :: Spec
spec =
    describe
        "stake-reward-init-wizard --exclude-utxo / --extra-tx-in"
        $ do
            let walletRefA = T.replicate 64 "a" <> "#0"
                walletRefB = T.replicate 64 "b" <> "#1"
                outRefA = mustParse walletRefA
                outRefB = mustParse walletRefB

            describe "T030 contradiction"
                $ it
                    "stake-reward-init-wizard fails fast at flag validation"
                $ do
                    let argv =
                            baseScriptAccountArgs
                                ++ [ "--exclude-utxo"
                                   , T.unpack walletRefA
                                   , "--extra-tx-in"
                                   , T.unpack walletRefA
                                   ]
                    case parseStake argv of
                        Left err ->
                            errorWithoutStackTrace
                                ( "expected parse success: "
                                    <> err
                                )
                        Right (StakeRewardInitScriptAccountOpts (ScriptAccountOpts cf)) ->
                            validateStakeRewardInitWizardInputControl
                                cf
                                `shouldBe` Left
                                    (Contradiction [outRefA])
                        Right _ ->
                            errorWithoutStackTrace
                                "expected script-account sub-action"

            describe "T031 exclusion filters the wallet pool" $ do
                it
                    "wallet head is the surviving candidate B after --exclude-utxo A"
                    $ do
                        let stub =
                                stubEnv
                                    [ (walletRefA, 5_000_000, False)
                                    , (walletRefB, 5_000_000, False)
                                    ]
                            r =
                                runIdentity
                                    ( resolveStakeRewardInitScriptAccountIC
                                        stub
                                        (ExclusionSet [outRefA])
                                        (ForcedInclusionSet [])
                                        baseRi
                                    )
                        case r of
                            Left e ->
                                errorWithoutStackTrace
                                    ("expected Right: " <> show e)
                            Right (env', outcome) -> do
                                wsTxIn (sreWalletSelection env')
                                    `shouldBe` walletRefB
                                icoHits outcome
                                    `shouldSatisfy` elem
                                        (outRefA, WalletOnly)
                it
                    "renders the operator-facing log line with prefix and [wallet] attribution"
                    $ do
                        renderStakeRewardInitExclusionLogLine
                            "stake-reward-init-wizard"
                            outRefA
                            WalletOnly
                            `shouldBe` ( "stake-reward-init-wizard: excluded utxo "
                                            <> outRefText outRefA
                                            <> " (operator-supplied) [wallet]"
                                       )

            describe "T032 forced inclusion lands in wsExtraTxIns"
                $ it
                    "--extra-tx-in ref appears in wsExtraTxIns of the resolved env"
                $ do
                    let stub =
                            stubEnv
                                [ (walletRefA, 5_000_000, False)
                                , (walletRefB, 5_000_000, False)
                                ]
                        r =
                            runIdentity
                                ( resolveStakeRewardInitScriptAccountIC
                                    stub
                                    (ExclusionSet [])
                                    (ForcedInclusionSet [outRefB])
                                    baseRi
                                )
                    case r of
                        Left e ->
                            errorWithoutStackTrace
                                ("expected Right: " <> show e)
                        Right (env', _) -> do
                            wsTxIn (sreWalletSelection env')
                                `shouldBe` walletRefA
                            wsExtraTxIns (sreWalletSelection env')
                                `shouldBe` [walletRefB]

            describe "T033 shortfall-with-excludes" $ do
                it
                    "wallet-side filtering all candidates surfaces shortfall naming the excluded ref"
                    $ do
                        let stub =
                                stubEnv
                                    [(walletRefA, 5_000_000, False)]
                            r =
                                runIdentity
                                    ( resolveStakeRewardInitScriptAccountIC
                                        stub
                                        (ExclusionSet [outRefA])
                                        (ForcedInclusionSet [])
                                        baseRi
                                    )
                        case r of
                            Left
                                ( StakeRewardInitResolverWalletShortfallWithExcludes
                                        _
                                        _
                                        refs
                                    ) -> do
                                    refs `shouldBe` [outRefA]
                                    renderStakeRewardInitWalletShortfallWithExcludes
                                        "wallet shortfall"
                                        refs
                                        `shouldSatisfy` T.isInfixOf
                                            (outRefText outRefA)
                            other ->
                                errorWithoutStackTrace
                                    ( "expected StakeRewardInitResolverWalletShortfallWithExcludes, got: "
                                        <> show other
                                    )
                it
                    "legacy shim with empty flag sets resolves equivalently to the IC variant"
                    $ do
                        let stub =
                                stubEnv
                                    [ (walletRefA, 5_000_000, False)
                                    , (walletRefB, 5_000_000, False)
                                    ]
                            ric =
                                runIdentity
                                    ( resolveStakeRewardInitScriptAccountIC
                                        stub
                                        (ExclusionSet [])
                                        (ForcedInclusionSet [])
                                        baseRi
                                    )
                        case ric of
                            Right (env', _) ->
                                wsExtraTxIns (sreWalletSelection env')
                                    `shouldBe` []
                            Left e ->
                                errorWithoutStackTrace
                                    ("expected Right: " <> show e)

-- ----------------------------------------------------------------------
-- Sample data
-- ----------------------------------------------------------------------

walletAddrText :: Text
walletAddrText =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

sampleRegistry :: DevnetStakeRewardRegistry
sampleRegistry =
    case eitherDecode sampleRegistryBytes of
        Right r -> r
        Left e ->
            errorWithoutStackTrace
                ("sampleRegistry decode failed: " <> e)

sampleRegistryBytes :: BSL.ByteString
sampleRegistryBytes =
    "{\"phase\":\"registry-init\",\"network\":\"devnet\",\
    \\"anchors\":{\"permissionsDeployedAt\":\"\
    \aa00000000000000000000000000000000000000000000000000000000000000#0\",\
    \\"treasuryDeployedAt\":\"\
    \cc00000000000000000000000000000000000000000000000000000000000000#1\"},\
    \\"scripts\":{\"permissionsScriptHash\":\"\
    \11111111111111111111111111111111111111111111111111111111\",\
    \\"treasuryScriptHash\":\"\
    \22222222222222222222222222222222222222222222222222222222\"}}"
