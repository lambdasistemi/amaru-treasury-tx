{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.RegistryInitWizardSpec
Description : Unit tests for the registry-init-wizard
License     : Apache-2.0

Slice 2 of #158 shipped the seed-split round-trip and the
wallet-shortfall path. Slice 3 extends with a mint
round-trip on the same pattern. Slice 4 adds the
reference-scripts round-trip on the same shape.

Assertions:

* JSON round-trip (seed-split) — @decodeTreasuryIntent
  . encodeSomeTreasuryIntent@ recovers the seed-split
  'SomeTreasuryIntent' the wizard emits.
* JSON round-trip (mint) — same, for the mint translation
  built by 'registryInitMintToIntent'.
* JSON round-trip (reference-scripts) — same, for the
  reference-scripts translation built by
  'registryInitReferenceScriptsToIntent'.
* Wallet shortfall — the resolver returns
  'Left RegistryInitWalletShortfall' when the wallet has no
  pure-ADA UTxOs (the mock 'wreQueryWalletUtxos' returns
  @[]@).

The unit test deliberately builds its inputs inline — the
shared golden helper 'Support.RegistryInitWizardFixtures'
lives under @test/golden/@ and isn't visible to the unit
suite.
-}
module Amaru.Treasury.Tx.RegistryInitWizardSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Functor.Identity (Identity (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Crypto.Hash.Class
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    )
import Cardano.Ledger.BaseTypes (mkTxIxPartial)
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Amaru.Treasury.IntentJSON
    ( decodeTreasuryIntent
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Tx.RegistryInitWizard
    ( RegistryInitEnv (..)
    , RegistryInitError (..)
    , RegistryInitMintAnswers (..)
    , RegistryInitReferenceScriptsAnswers (..)
    , RegistryInitResolverEnv (..)
    , RegistryInitResolverInput (..)
    , RegistryInitSeedSplitAnswers (..)
    , registryInitMintToIntent
    , registryInitReferenceScriptsToIntent
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
spec = describe "registry-init-wizard" $ do
    describe "seed-split" $ do
        it
            "encodes and decodes a seed-split SomeTreasuryIntent \
            \without loss"
            roundTripSeedSplit
        it
            "resolver returns RegistryInitWalletShortfall when \
            \the wallet has no pure-ADA UTxOs"
            walletShortfallSeedSplit
    describe "mint" $
        it
            "encodes and decodes a mint SomeTreasuryIntent \
            \without loss"
            roundTripMint
    describe "reference-scripts" $
        it
            "encodes and decodes a reference-scripts \
            \SomeTreasuryIntent without loss"
            roundTripReferenceScripts

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

roundTripMint :: IO ()
roundTripMint = do
    let answers =
            RegistryInitMintAnswers
                { rimScope = CoreDevelopment
                , rimValidityHours = Nothing
                , rimDescription = Nothing
                , rimJustification = Nothing
                , rimDestinationLabel = Nothing
                , rimEvent = Nothing
                , rimLabel = Nothing
                , rimScopesSeedTxIn = sampleScopesSeedTxIn
                , rimRegistrySeedTxIn = sampleRegistrySeedTxIn
                , rimOwnerKeyHash = sampleOwnerKeyHash
                }
        env = sampleEnv
    intent <- case registryInitMintToIntent env answers of
        Left e ->
            error
                ( "registryInitMintToIntent failed: "
                    <> show e
                )
        Right i -> pure i
    let encoded = encodeSomeTreasuryIntent intent
    decodeTreasuryIntent encoded `shouldBe` Right intent

roundTripReferenceScripts :: IO ()
roundTripReferenceScripts = do
    let answers =
            RegistryInitReferenceScriptsAnswers
                { rirScope = CoreDevelopment
                , rirValidityHours = Nothing
                , rirDescription = Nothing
                , rirJustification = Nothing
                , rirDestinationLabel = Nothing
                , rirEvent = Nothing
                , rirLabel = Nothing
                , rirScopesSeedTxIn = sampleScopesSeedTxIn
                , rirRegistrySeedTxIn = sampleRegistrySeedTxIn
                , rirFundingSeedTxIn = sampleFundingSeedTxIn
                }
        env = sampleEnv
    intent <-
        case registryInitReferenceScriptsToIntent env answers of
            Left e ->
                error
                    ( "registryInitReferenceScriptsToIntent failed: "
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

-- ----------------------------------------------------
-- Mint sample data
-- ----------------------------------------------------

sampleScopesSeedTxIn :: TxIn
sampleScopesSeedTxIn = mkTxIn (BS.replicate 32 0x44) 0

sampleRegistrySeedTxIn :: TxIn
sampleRegistrySeedTxIn = mkTxIn (BS.replicate 32 0x55) 1

sampleOwnerKeyHash :: KeyHash kr
sampleOwnerKeyHash = KeyHash (mkHash (BS.replicate 28 0x11))

-- ----------------------------------------------------
-- Reference-scripts sample data
-- ----------------------------------------------------

sampleFundingSeedTxIn :: TxIn
sampleFundingSeedTxIn = mkTxIn (BS.replicate 32 0x66) 2

mkTxIn :: ByteString -> Integer -> TxIn
mkTxIn bs ix =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash bs)))
        (mkTxIxPartial ix)

mkHash :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash = fromJust . hashFromBytes
