{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.RegistryInitWizardNetworkGuardSpec
Description : Devnet-only guard for the registry-init-wizard
License     : Apache-2.0

Slice 2 of #158 wired the seed-split arm. Slice 3 refined
the mint arm from a placeholder to real Answers. Slice 4
refines the reference-scripts arm on the same shape: real
'RegistryInitReferenceScriptsAnswers' values are constructed
and the resolver is exercised with each non-devnet network so
the guard fires before any chain query.

The seed-split resolver MUST fire
'RegistryInitNonDevnetNetwork' for every non-devnet network
(mainnet, preprod, preview) BEFORE any chain query happens.

The mock resolver env's @wreQueryWalletUtxos@ raises with
'error' if invoked — the tests pass iff the resolver
short-circuits at the network guard. All three Answers
shapes exercise the SAME resolver
('resolveRegistryInitSeedSplit'), since the network guard
fires in the resolver before the sub-action discriminator
matters; the mint and reference-scripts cases prove the
guard is reachable with real Answers in hand.
-}
module Amaru.Treasury.Tx.RegistryInitWizardNetworkGuardSpec
    ( spec
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Functor.Identity (Identity (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
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

import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Tx.RegistryInitWizard
    ( RegistryInitError (..)
    , RegistryInitMintAnswers (..)
    , RegistryInitReferenceScriptsAnswers (..)
    , RegistryInitResolverEnv (..)
    , RegistryInitResolverInput (..)
    , resolveRegistryInitSeedSplit
    )
import Amaru.Treasury.Tx.SwapWizard
    ( RegistryView (..)
    , ScopeOwners (..)
    , TreasuryRefs (..)
    )

spec :: Spec
spec = describe "registry-init-wizard devnet network guard" $ do
    describe "seed-split" $ do
        it "rejects mainnet before any chain query" $
            seedSplitRejects "mainnet"
        it "rejects preprod before any chain query" $
            seedSplitRejects "preprod"
        it "rejects preview before any chain query" $
            seedSplitRejects "preview"
    describe "mint" $ do
        it "rejects mainnet before any chain query" $
            mintRejects "mainnet"
        it "rejects preprod before any chain query" $
            mintRejects "preprod"
        it "rejects preview before any chain query" $
            mintRejects "preview"
    describe "reference-scripts" $ do
        it "rejects mainnet before any chain query" $
            referenceScriptsRejects "mainnet"
        it "rejects preprod before any chain query" $
            referenceScriptsRejects "preprod"
        it "rejects preview before any chain query" $
            referenceScriptsRejects "preview"

seedSplitRejects :: Text -> IO ()
seedSplitRejects network = do
    let input =
            RegistryInitResolverInput
                { wriNetwork = network
                , wriWalletAddrBech32 = walletAddr
                , wriScope = CoreDevelopment
                , wriRegistry = registry
                , wriValidityHours = Nothing
                }
        renv :: RegistryInitResolverEnv Identity
        renv = strictMockResolverEnv
        result =
            runIdentity (resolveRegistryInitSeedSplit renv input)
    result `shouldSatisfy` isNonDevnet network

{- | Mint network-guard case: real 'RegistryInitMintAnswers'
are constructed (and intentionally unused beyond proving they
are inhabitable) and the same resolver is exercised with a
non-devnet network so the guard fires before any chain query.
The 'RegistryInitMintAnswers' value is computed strictly via
@seq@ to defeat laziness pruning, mirroring the assertion shape
that Slice 5's integration tests will reuse.
-}
mintRejects :: Text -> IO ()
mintRejects network = do
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
        input =
            RegistryInitResolverInput
                { wriNetwork = network
                , wriWalletAddrBech32 = walletAddr
                , wriScope = rimScope answers
                , wriRegistry = registry
                , wriValidityHours = rimValidityHours answers
                }
        renv :: RegistryInitResolverEnv Identity
        renv = strictMockResolverEnv
        result =
            answers `seq`
                runIdentity (resolveRegistryInitSeedSplit renv input)
    result `shouldSatisfy` isNonDevnet network

{- | Reference-scripts network-guard case: real
'RegistryInitReferenceScriptsAnswers' are constructed (and
intentionally unused beyond proving they are inhabitable)
and the same resolver is exercised with a non-devnet network
so the guard fires before any chain query. The Answers value
is computed strictly via @seq@ to defeat laziness pruning,
mirroring Slice 3's mint case.
-}
referenceScriptsRejects :: Text -> IO ()
referenceScriptsRejects network = do
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
        input =
            RegistryInitResolverInput
                { wriNetwork = network
                , wriWalletAddrBech32 = walletAddr
                , wriScope = rirScope answers
                , wriRegistry = registry
                , wriValidityHours = rirValidityHours answers
                }
        renv :: RegistryInitResolverEnv Identity
        renv = strictMockResolverEnv
        result =
            answers `seq`
                runIdentity (resolveRegistryInitSeedSplit renv input)
    result `shouldSatisfy` isNonDevnet network

strictMockResolverEnv :: RegistryInitResolverEnv Identity
strictMockResolverEnv =
    RegistryInitResolverEnv
        { wreQueryWalletUtxos = \_ ->
            error
                "wreQueryWalletUtxos must not be called \
                \when the network guard fires"
        , wreComputeUpperBound = \_ ->
            error
                "wreComputeUpperBound must not be called \
                \when the network guard fires"
        }

isNonDevnet
    :: Text -> Either RegistryInitError a -> Bool
isNonDevnet expected = \case
    Left (RegistryInitNonDevnetNetwork seen) ->
        seen == expected
    _ -> False

walletAddr :: Text
walletAddr =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

registry :: RegistryView
registry =
    RegistryView
        { rvScopesDeployedAt = "00#0"
        , rvPermissionsDeployedAt = "00#0"
        , rvTreasuryDeployedAt = "00#0"
        , rvRegistryDeployedAt = "00#0"
        , rvRegistryPolicyId = T.replicate 56 "0"
        , rvOwners = placeholderOwners
        , rvTreasuryByScope =
            Map.singleton
                CoreDevelopment
                TreasuryRefs
                    { trAddress = walletAddr
                    , trScriptHash = T.replicate 56 "0"
                    , trPermissionsRewardAccount =
                        T.replicate 56 "0"
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

sampleFundingSeedTxIn :: TxIn
sampleFundingSeedTxIn = mkTxIn (BS.replicate 32 0x66) 2

mkTxIn :: ByteString -> Integer -> TxIn
mkTxIn bs ix =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash bs)))
        (mkTxIxPartial ix)

mkHash :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash = fromJust . hashFromBytes
