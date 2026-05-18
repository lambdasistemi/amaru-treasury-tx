{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.RegistryInitWizardNetworkGuardSpec
Description : Devnet-only guard for the registry-init-wizard
License     : Apache-2.0

Slice 2 of #158. The seed-split resolver MUST fire
'RegistryInitNonDevnetNetwork' for every non-devnet network
(mainnet, preprod, preview) BEFORE any chain query happens.

The mock resolver env's @wreQueryWalletUtxos@ raises with
'error' if invoked — the tests pass iff the resolver
short-circuits at the network guard.

Mint and reference-scripts placeholder cases are scaffolded
in comments; Slices 3 and 4 refine them to real Answers.
-}
module Amaru.Treasury.Tx.RegistryInitWizardNetworkGuardSpec
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
    , shouldSatisfy
    )

import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Tx.RegistryInitWizard
    ( RegistryInitError (..)
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

-- TODO Slice 3: refine mint cases here from placeholder
-- Answers to real Answers. The guard logic is identical.
-- TODO Slice 4: refine reference-scripts cases here from
-- placeholder Answers to real Answers.

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
        renv =
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
        result =
            runIdentity (resolveRegistryInitSeedSplit renv input)
    result `shouldSatisfy` isNonDevnet network

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
