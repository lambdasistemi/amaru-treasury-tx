{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.RegistryInitWizardSpec
Description : Unit tests for the registry-init-wizard
License     : Apache-2.0

Slice 2 of #158. Two assertions:

* JSON round-trip — @decodeTreasuryIntent
  . encodeSomeTreasuryIntent@ recovers the seed-split
  'SomeTreasuryIntent' the wizard emits.
* Wallet shortfall — the resolver returns
  'Left RegistryInitWalletShortfall' when the wallet has no
  pure-ADA UTxOs (the mock 'wreQueryWalletUtxos' returns
  @[]@). Slices 3 and 4 extend with mint and reference-scripts
  round-trips.

The unit test deliberately builds its inputs inline — the
shared golden helper 'Support.RegistryInitWizardFixtures'
lives under @test/golden/@ and isn't visible to the unit
suite.
-}
module Amaru.Treasury.Tx.RegistryInitWizardSpec (spec) where

import Data.Functor.Identity (Identity (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.IntentJSON
    ( decodeTreasuryIntent
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Tx.RegistryInitWizard
    ( RegistryInitEnv (..)
    , RegistryInitError (..)
    , RegistryInitResolverEnv (..)
    , RegistryInitResolverInput (..)
    , RegistryInitSeedSplitAnswers (..)
    , registryInitSeedSplitToIntent
    , resolveRegistryInitSeedSplit
    )
import Amaru.Treasury.Tx.SwapWizard
    ( RegistryView (..)
    , ScopeOwners (..)
    , ScopeView (..)
    , TreasuryRefs (..)
    , WalletSelection (..)
    )

spec :: Spec
spec = describe "registry-init-wizard seed-split" $ do
    it
        "encodes and decodes a seed-split SomeTreasuryIntent \
        \without loss"
        roundTripSeedSplit
    it
        "resolver returns RegistryInitWalletShortfall when \
        \the wallet has no pure-ADA UTxOs"
        walletShortfallSeedSplit

roundTripSeedSplit :: IO ()
roundTripSeedSplit = do
    let answers =
            RegistryInitSeedSplitAnswers
                { risScope = CoreDevelopment
                , risValidityHours = Nothing
                , risDescription = Nothing
                , risJustification = Nothing
                , risDestinationLabel = Nothing
                , risEvent = Nothing
                , risLabel = Nothing
                }
        env = sampleEnv
    intent <- case registryInitSeedSplitToIntent env answers of
        Left e ->
            error
                ( "registryInitSeedSplitToIntent failed: "
                    <> show e
                )
        Right i -> pure i
    let encoded = encodeSomeTreasuryIntent intent
    decodeTreasuryIntent encoded `shouldBe` Right intent

walletShortfallSeedSplit :: IO ()
walletShortfallSeedSplit = do
    let input =
            RegistryInitResolverInput
                { wriNetwork = "devnet"
                , wriWalletAddrBech32 = walletAddrText
                , wriScope = CoreDevelopment
                , wriRegistry = sampleRegistry
                , wriValidityHours = Nothing
                }
        renv :: RegistryInitResolverEnv Identity
        renv =
            RegistryInitResolverEnv
                { wreQueryWalletUtxos = \_ -> Identity []
                , wreComputeUpperBound = \_ ->
                    Identity (Right 1_000_100)
                }
        result =
            runIdentity (resolveRegistryInitSeedSplit renv input)
    result `shouldSatisfy` isWalletShortfall

isWalletShortfall :: Either RegistryInitError a -> Bool
isWalletShortfall = \case
    Left RegistryInitWalletShortfall -> True
    _ -> False

-- ----------------------------------------------------
-- Sample data (kept inline; no Support imports)
-- ----------------------------------------------------

walletAddrText :: T.Text
walletAddrText =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

sampleRefs :: TreasuryRefs
sampleRefs =
    TreasuryRefs
        { trAddress = walletAddrText
        , trScriptHash = T.replicate 56 "0"
        , trPermissionsRewardAccount = T.replicate 56 "0"
        }

sampleRegistry :: RegistryView
sampleRegistry =
    RegistryView
        { rvScopesDeployedAt = "00#0"
        , rvPermissionsDeployedAt = "00#0"
        , rvTreasuryDeployedAt = "00#0"
        , rvRegistryDeployedAt = "00#0"
        , rvRegistryPolicyId = T.replicate 56 "0"
        , rvOwners = placeholderOwners
        , rvTreasuryByScope =
            Map.singleton CoreDevelopment sampleRefs
        }

sampleEnv :: RegistryInitEnv
sampleEnv =
    RegistryInitEnv
        { reNetwork = "devnet"
        , reUpperBoundSlot = 1_000_100
        , reRegistry = sampleRegistry
        , reScopeView =
            ScopeView
                { svScope = CoreDevelopment
                , svRefs = sampleRefs
                , svDefaultSigners = []
                }
        , reWalletSelection =
            WalletSelection
                { wsTxIn = "00#0"
                , wsAddress = walletAddrText
                , wsExtraTxIns = []
                }
        }

placeholderOwners :: ScopeOwners
placeholderOwners =
    ScopeOwners
        { soCore = T.replicate 56 "0"
        , soOps = T.replicate 56 "0"
        , soNetworkCompliance = T.replicate 56 "0"
        , soMiddleware = T.replicate 56 "0"
        }
