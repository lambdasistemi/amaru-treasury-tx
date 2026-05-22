{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.ReorganizeWizardInputControlSpec
Description : RED+GREEN assertions for the @reorganize-wizard@
              @--exclude-utxo@ / @--extra-tx-in@ wiring
              (Slice 10 of #184).
License     : Apache-2.0

Reorganize-wizard came online for real networks in #218 (after
the initial #184 slices shipped). This slice wires the shared
'Amaru.Treasury.Wizard.InputControl' API into the existing
'resolveReorganize'/'resolveReorganizeIC' resolver pair.

T051 — US3 contradiction at flag-validation time.
T052 — US1 exclusion filters the wallet pool.
T053 — US2 forced inclusion lands in 'wsExtraTxIns'.
T054 — US1+US4 shortfall-with-excludes naming.
-}
module Amaru.Treasury.Cli.ReorganizeWizardInputControlSpec
    ( spec
    ) where

import Data.Functor.Identity (Identity (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , ScriptRef (..)
    , TreasuryMetadata (..)
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

import Amaru.Treasury.Cli.ReorganizeWizard
    ( CommonFlags (..)
    , validateReorganizeWizardInputControl
    )
import Amaru.Treasury.Tx.ReorganizeWizard
    ( InputControlOutcome (..)
    , PoolHit (..)
    , ReorganizeEnv (..)
    , ReorganizeError (..)
    , ReorganizeResolverEnv (..)
    , ReorganizeResolverInput (..)
    , renderReorganizeExclusionLogLine
    , renderReorganizeWalletShortfallWithExcludes
    , resolveReorganizeIC
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

stubEnv
    :: [(Text, Integer, Bool)]
    -> ReorganizeResolverEnv Identity
stubEnv walletUtxos =
    ReorganizeResolverEnv
        { sreReadMetadata = \_ -> Identity (Right sampleMeta)
        , sreQueryWalletUtxos = \_ -> Identity walletUtxos
        , sreQueryTreasuryUtxos = \_ ->
            Identity
                [
                    ( "00000000000000000000000000000000000000000000000000000000000000aa#0"
                    , 5_000_000
                    , False
                    )
                ,
                    ( "00000000000000000000000000000000000000000000000000000000000000bb#1"
                    , 5_000_000
                    , False
                    )
                ]
        , sreComputeUpperBound = \_ ->
            Identity (Right 1_000_100)
        }

baseRi :: ReorganizeResolverInput
baseRi =
    ReorganizeResolverInput
        { rriNetwork = "preprod"
        , rriWalletAddrBech32 = walletAddrText
        , rriMetadataPath = "/tmp/metadata.json"
        , rriScope = CoreDevelopment
        , rriValidityHours = Nothing
        }

baseCommonFlags :: CommonFlags
baseCommonFlags =
    CommonFlags
        { cfWalletAddr = walletAddrText
        , cfMetadataPath = "/tmp/metadata.json"
        , cfOut = "/tmp/reorganize-intent.json"
        , cfLog = Nothing
        , cfScope = CoreDevelopment
        , cfValidityHours = Nothing
        , cfDescription = Nothing
        , cfJustification = Nothing
        , cfDestinationLabel = Nothing
        , cfEvent = Nothing
        , cfLabel = Nothing
        , cfForce = False
        , cfExcludeSet = ExclusionSet []
        , cfForcedSet = ForcedInclusionSet []
        }

-- ----------------------------------------------------------------------
-- Spec
-- ----------------------------------------------------------------------

spec :: Spec
spec =
    describe
        "reorganize-wizard --exclude-utxo / --extra-tx-in"
        $ do
            let walletRefA = T.replicate 64 "a" <> "#0"
                walletRefB = T.replicate 64 "b" <> "#1"
                outRefA = mustParse walletRefA
                outRefB = mustParse walletRefB

            describe "T051 contradiction" $ do
                it
                    "reorganize-wizard validation fails fast on overlapping flags"
                    $ do
                        let cf =
                                baseCommonFlags
                                    { cfExcludeSet =
                                        ExclusionSet [outRefA]
                                    , cfForcedSet =
                                        ForcedInclusionSet [outRefA]
                                    }
                        validateReorganizeWizardInputControl cf
                            `shouldBe` Left
                                (Contradiction [outRefA])

            describe "T052 exclusion filters the wallet pool" $ do
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
                                    ( resolveReorganizeIC
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
                                wsTxIn (reWalletSelection env')
                                    `shouldBe` walletRefB
                                icoHits outcome
                                    `shouldSatisfy` elem
                                        (outRefA, WalletOnly)
                it
                    "renders the operator-facing log line with prefix and [wallet] attribution"
                    $ do
                        renderReorganizeExclusionLogLine
                            "reorganize-wizard"
                            outRefA
                            WalletOnly
                            `shouldBe` ( "reorganize-wizard: excluded utxo "
                                            <> outRefText outRefA
                                            <> " (operator-supplied) [wallet]"
                                       )

            describe "T053 forced inclusion lands in wsExtraTxIns" $ do
                it
                    "--extra-tx-in ref appears in wsExtraTxIns of the resolved env"
                    $ do
                        let stub =
                                stubEnv
                                    [ (walletRefA, 5_000_000, False)
                                    , (walletRefB, 5_000_000, False)
                                    ]
                            r =
                                runIdentity
                                    ( resolveReorganizeIC
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
                                wsTxIn (reWalletSelection env')
                                    `shouldBe` walletRefA
                                wsExtraTxIns (reWalletSelection env')
                                    `shouldBe` [walletRefB]

            describe "T054 shortfall-with-excludes" $ do
                it
                    "wallet-side filtering all candidates surfaces shortfall naming the excluded ref"
                    $ do
                        let stub =
                                stubEnv
                                    [(walletRefA, 5_000_000, False)]
                            r =
                                runIdentity
                                    ( resolveReorganizeIC
                                        stub
                                        (ExclusionSet [outRefA])
                                        (ForcedInclusionSet [])
                                        baseRi
                                    )
                            extractRefs = case r of
                                Left
                                    ( ReorganizeResolverWalletShortfallWithExcludes
                                            _
                                            _
                                            refs
                                        ) ->
                                        refs
                                _ -> []
                        extractRefs `shouldBe` [outRefA]
                        renderReorganizeWalletShortfallWithExcludes
                            "wallet shortfall"
                            [outRefA]
                            `shouldSatisfy` T.isInfixOf
                                (outRefText outRefA)

-- ----------------------------------------------------------------------
-- Sample data
-- ----------------------------------------------------------------------

walletAddrText :: Text
walletAddrText =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

sampleMeta :: TreasuryMetadata
sampleMeta =
    TreasuryMetadata
        { tmScopeOwners =
            "0000000000000000000000000000000000000000000000000000000000000000#0"
        , tmTreasuries =
            Map.singleton CoreDevelopment sampleScope
        }

sampleScope :: ScopeMetadata
sampleScope =
    ScopeMetadata
        { smOwner = Just (T.replicate 56 "1")
        , smBudget = Nothing
        , smAddress = walletAddrText
        , smTreasury = sampleRef
        , smPermissions = sampleRef
        , smRegistry = sampleRef
        }

sampleRef :: ScriptRef
sampleRef =
    ScriptRef
        { srHash = T.replicate 56 "0"
        , srDeployedAt =
            "0000000000000000000000000000000000000000000000000000000000000000#0"
        }
