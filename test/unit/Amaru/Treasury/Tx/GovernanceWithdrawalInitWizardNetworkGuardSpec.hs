{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.GovernanceWithdrawalInitWizardNetworkGuardSpec
Description : Devnet-only guard for governance-withdrawal-init-wizard
License     : Apache-2.0

Slice 2 of #160 wires the @proposal@ resolver. The devnet
network guard fires BEFORE any chain query, before the
registry parse, before the stake-reward-accounts parse,
before the cross-validation, before the pparams query, and
before the wallet query.

The mock resolver env raises with 'error' from every
backend hook AND from 'gwireDepositComponents'; the tests
pass iff the resolver short-circuits at the network guard.
The materialization arm is still a stub at Slice 2 (its
resolver lands in Slice 3), so the network-guard pair
covers @proposal@ only here.
-}
module Amaru.Treasury.Tx.GovernanceWithdrawalInitWizardNetworkGuardSpec
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

import Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard
    ( GovernanceWithdrawalInitError (..)
    , GovernanceWithdrawalInitMaterializationResolverEnv (..)
    , GovernanceWithdrawalInitResolverEnv (..)
    , GovernanceWithdrawalInitResolverInput (..)
    , resolveGovernanceWithdrawalInitMaterialization
    , resolveGovernanceWithdrawalInitProposal
    )

spec :: Spec
spec =
    describe "governance-withdrawal-init-wizard devnet network guard" $ do
        describe "proposal" $ do
            it "rejects mainnet before any chain query or artifact parse" $
                proposalRejects "mainnet"
            it "rejects preprod before any chain query or artifact parse" $
                proposalRejects "preprod"
            it "rejects preview before any chain query or artifact parse" $
                proposalRejects "preview"
        describe "materialization" $ do
            it "rejects mainnet before any chain query or artifact parse" $
                materializationRejects "mainnet"
            it "rejects preprod before any chain query or artifact parse" $
                materializationRejects "preprod"
            it "rejects preview before any chain query or artifact parse" $
                materializationRejects "preview"

proposalRejects :: Text -> IO ()
proposalRejects network = do
    let input =
            GovernanceWithdrawalInitResolverInput
                { gwiriNetwork = network
                , gwiriWalletAddrBech32 = walletAddr
                , gwiriRegistryPath = "(unused)"
                , gwiriAccountsPath = "(unused)"
                , gwiriValidityHours = Nothing
                }
        renv :: GovernanceWithdrawalInitResolverEnv Identity
        renv = strictMockResolverEnv
        result =
            runIdentity
                (resolveGovernanceWithdrawalInitProposal renv input)
    -- proposalSeedTxIn unused — included only to make the
    -- assertion explicit that the resolver never touched the
    -- wallet/seed plumbing.
    sampleSeedTxIn `seq`
        result `shouldSatisfy` isNonDevnet network

strictMockResolverEnv
    :: GovernanceWithdrawalInitResolverEnv Identity
strictMockResolverEnv =
    GovernanceWithdrawalInitResolverEnv
        { gwireQueryWalletUtxos = \_ ->
            error
                "gwireQueryWalletUtxos must not be called \
                \when the network guard fires"
        , gwireComputeUpperBound = \_ ->
            error
                "gwireComputeUpperBound must not be called \
                \when the network guard fires"
        , gwireReadRegistry = \_ ->
            error
                "gwireReadRegistry must not be called when \
                \the network guard fires"
        , gwireReadAccounts = \_ ->
            error
                "gwireReadAccounts must not be called when \
                \the network guard fires"
        , gwireDepositComponents =
            error
                "gwireDepositComponents must not be called \
                \when the network guard fires"
        }

materializationRejects :: Text -> IO ()
materializationRejects network = do
    let input =
            GovernanceWithdrawalInitResolverInput
                { gwiriNetwork = network
                , gwiriWalletAddrBech32 = walletAddr
                , gwiriRegistryPath = "(unused)"
                , gwiriAccountsPath = "(unused)"
                , gwiriValidityHours = Nothing
                }
        renv :: GovernanceWithdrawalInitMaterializationResolverEnv Identity
        renv = strictMockMaterializationResolverEnv
        result =
            runIdentity
                ( resolveGovernanceWithdrawalInitMaterialization
                    renv
                    input
                )
    sampleSeedTxIn `seq`
        result `shouldSatisfy` isNonDevnet network

{- | Mirror of 'strictMockResolverEnv' for the
materialization arm. Every backend hook raises so the
network-guard test fails loudly the moment the resolver
reaches any one of them. 'gwimreFloorComponents' is a pure
field (not @m@-wrapped), so a benign value is fine — the
guard fires before it is consumed.
-}
strictMockMaterializationResolverEnv
    :: GovernanceWithdrawalInitMaterializationResolverEnv Identity
strictMockMaterializationResolverEnv =
    GovernanceWithdrawalInitMaterializationResolverEnv
        { gwimreQueryWalletUtxos = \_ ->
            error
                "gwimreQueryWalletUtxos must not be called \
                \when the network guard fires"
        , gwimreComputeUpperBound = \_ ->
            error
                "gwimreComputeUpperBound must not be called \
                \when the network guard fires"
        , gwimreReadRegistry = \_ ->
            error
                "gwimreReadRegistry must not be called when \
                \the network guard fires"
        , gwimreReadAccounts = \_ ->
            error
                "gwimreReadAccounts must not be called when \
                \the network guard fires"
        , gwimreFloorComponents =
            error
                "gwimreFloorComponents must not be evaluated \
                \when the network guard fires"
        }

isNonDevnet
    :: Text -> Either GovernanceWithdrawalInitError a -> Bool
isNonDevnet expected = \case
    Left (GovernanceWithdrawalInitNonDevnetNetwork seen) ->
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
