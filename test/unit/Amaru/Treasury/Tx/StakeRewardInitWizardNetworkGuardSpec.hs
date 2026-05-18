{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.StakeRewardInitWizardNetworkGuardSpec
Description : Devnet-only guard for the stake-reward-init-wizard
License     : Apache-2.0

Slice 2 of #159 wired the @script-account@ resolver. The
devnet network guard fires BEFORE any chain query AND before
the registry-file parse, so a non-devnet @--network@ never
reads the registry, never queries the wallet, and never asks
the chain for an upper-bound slot.

Slice 3 adds the @plain-account@ case: same guard, exercised
via 'resolveStakeRewardInitPlainAccount' on real
'StakeRewardInitPlainAccountAnswers'. The resolver pipeline
is shared between the two sub-actions; the test pair pins
the short-circuit behavior independently on both entry
points so a future divergence would surface here.

The mock resolver env raises with 'error' from every backend
hook; the tests pass iff the resolver short-circuits at the
network guard.
-}
module Amaru.Treasury.Tx.StakeRewardInitWizardNetworkGuardSpec
    ( spec
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Functor.Identity (Identity (..))
import Data.Maybe (fromJust)
import Data.Text (Text)
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
    ( unsafeMakeSafeHash
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Amaru.Treasury.Tx.StakeRewardInitWizard
    ( StakeRewardInitError (..)
    , StakeRewardInitPlainAccountAnswers (..)
    , StakeRewardInitResolverEnv (..)
    , StakeRewardInitResolverInput (..)
    , StakeRewardInitScriptAccountAnswers (..)
    , resolveStakeRewardInitPlainAccount
    , resolveStakeRewardInitScriptAccount
    )

spec :: Spec
spec = describe "stake-reward-init-wizard devnet network guard" $ do
    describe "script-account" $ do
        it "rejects mainnet before any chain query" $
            scriptAccountRejects "mainnet"
        it "rejects preprod before any chain query" $
            scriptAccountRejects "preprod"
        it "rejects preview before any chain query" $
            scriptAccountRejects "preview"
    describe "plain-account" $ do
        it "rejects mainnet before any chain query" $
            plainAccountRejects "mainnet"
        it "rejects preprod before any chain query" $
            plainAccountRejects "preprod"
        it "rejects preview before any chain query" $
            plainAccountRejects "preview"

scriptAccountRejects :: Text -> IO ()
scriptAccountRejects network = do
    let answers =
            StakeRewardInitScriptAccountAnswers
                { sasaValidityHours = Nothing
                , sasaFundingSeedTxIn = sampleSeedTxIn
                }
        input =
            StakeRewardInitResolverInput
                { sriNetwork = network
                , sriWalletAddrBech32 = walletAddr
                , sriRegistryPath = "(unused)"
                , sriValidityHours = sasaValidityHours answers
                }
        renv :: StakeRewardInitResolverEnv Identity
        renv = strictMockResolverEnv
        result =
            answers `seq`
                runIdentity
                    (resolveStakeRewardInitScriptAccount renv input)
    result `shouldSatisfy` isNonDevnet network

{- | Plain-account network-guard case: exercises
'resolveStakeRewardInitPlainAccount' on real
'StakeRewardInitPlainAccountAnswers'; the resolver is fed a
non-devnet network so the guard fires before any chain
query. The strict mock env raises if any backend hook is
called.
-}
plainAccountRejects :: Text -> IO ()
plainAccountRejects network = do
    let answers =
            StakeRewardInitPlainAccountAnswers
                { spaaValidityHours = Nothing
                , spaaFundingSeedTxIn = sampleSeedTxIn
                }
        input =
            StakeRewardInitResolverInput
                { sriNetwork = network
                , sriWalletAddrBech32 = walletAddr
                , sriRegistryPath = "(unused)"
                , sriValidityHours = spaaValidityHours answers
                }
        renv :: StakeRewardInitResolverEnv Identity
        renv = strictMockResolverEnv
        result =
            answers `seq`
                runIdentity
                    (resolveStakeRewardInitPlainAccount renv input)
    result `shouldSatisfy` isNonDevnet network

strictMockResolverEnv :: StakeRewardInitResolverEnv Identity
strictMockResolverEnv =
    StakeRewardInitResolverEnv
        { sreQueryWalletUtxos = \_ ->
            error
                "sreQueryWalletUtxos must not be called \
                \when the network guard fires"
        , sreComputeUpperBound = \_ ->
            error
                "sreComputeUpperBound must not be called \
                \when the network guard fires"
        , sreReadRegistry = \_ ->
            error
                "sreReadRegistry must not be called when \
                \the network guard fires"
        }

isNonDevnet
    :: Text -> Either StakeRewardInitError a -> Bool
isNonDevnet expected = \case
    Left (StakeRewardInitNonDevnetNetwork seen) ->
        seen == expected
    _ -> False

walletAddr :: Text
walletAddr =
    "addr_test1vq3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zyg3zygswahgq5"

sampleSeedTxIn :: TxIn
sampleSeedTxIn = mkTxIn (BS.replicate 32 0xaa) 0

mkTxIn :: ByteString -> Integer -> TxIn
mkTxIn bs ix =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash bs)))
        (mkTxIxPartial ix)

mkHash :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash = fromJust . hashFromBytes
