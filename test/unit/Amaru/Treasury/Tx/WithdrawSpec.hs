{- |
Module      : Amaru.Treasury.Tx.WithdrawSpec
Description : Draft-only smoke test for the @withdraw@ builder
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Drafts 'withdrawProgram' with synthesized ledger inputs
and asserts the body has the expected shape:

* 1 wallet input (also the collateral)
* 2 reference inputs (treasury + registry)
* 1 withdrawal entry against the treasury reward account
* 1 output to the treasury contract address
* validity upper bound set

This is a structural test only — it does not run script
evaluation or balance the transaction. End-to-end
golden tests against a running cardano-node land in a
follow-up PR.
-}
module Amaru.Treasury.Tx.WithdrawSpec (spec) where

import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm, hashFromBytes)
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , Withdrawals (..)
    )
import Cardano.Ledger.Allegra.Scripts (ValidityInterval (..))
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , vldtTxBodyL
    , withdrawalsTxBodyL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    , mkTxIxPartial
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash (..), unsafeMakeSafeHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Word (Word8)
import Lens.Micro ((^.))
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Node.Client.TxBuild (draft)

import Amaru.Treasury.Tx.Withdraw
    ( WithdrawIntent (..)
    , withdrawProgram
    )

-- | Deterministic 32-byte hash.
mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 31 0 ++ [n]

-- | Deterministic 28-byte hash.
mkHash28 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash28 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 27 0 ++ [n]

mkTxIn :: Word8 -> TxIn
mkTxIn n =
    TxIn
        (TxId (unsafeMakeSafeHash (mkHash32 n)))
        (mkTxIxPartial 0)

scriptAddr :: Word8 -> Addr
scriptAddr n =
    Addr
        Mainnet
        (ScriptHashObj (ScriptHash (mkHash28 n)))
        ( StakeRefBase
            (ScriptHashObj (ScriptHash (mkHash28 n)))
        )

scriptRewardAcct :: Word8 -> AccountAddress
scriptRewardAcct n =
    AccountAddress
        Mainnet
        (AccountId (ScriptHashObj (ScriptHash (mkHash28 n))))

intent :: WithdrawIntent
intent =
    WithdrawIntent
        { wiWalletUtxo = mkTxIn 0
        , wiTreasuryRewardAccount = scriptRewardAcct 1
        , wiTreasuryAddress = scriptAddr 1
        , wiTreasuryDeployedAt = mkTxIn 2
        , wiRegistryDeployedAt = mkTxIn 3
        , wiRewardsAmount = Coin 12_500_000_000
        , wiUpperBound = SlotNo 1_000
        }

spec :: Spec
spec = describe "Amaru.Treasury.Tx.Withdraw" $ do
    let tx = draft emptyPParams (withdrawProgram intent)
        body = tx ^. bodyTxL
    it "spends exactly the wallet UTxO" $
        body ^. inputsTxBodyL `shouldBe` Set.singleton (mkTxIn 0)
    it "uses the wallet UTxO as collateral" $
        body
            ^. collateralInputsTxBodyL
            `shouldBe` Set.singleton (mkTxIn 0)
    it "carries 2 reference inputs (treasury + registry)" $
        Set.size (body ^. referenceInputsTxBodyL) `shouldBe` 2
    it "withdraws exactly the rewards amount" $
        body
            ^. withdrawalsTxBodyL
            `shouldBe` Withdrawals
                ( Map.singleton
                    (scriptRewardAcct 1)
                    (Coin 12_500_000_000)
                )
    it "produces exactly one output" $
        length (body ^. outputsTxBodyL) `shouldBe` 1
    it "sets the upper validity bound" $
        body
            ^. vldtTxBodyL
            `shouldSatisfy` \(ValidityInterval _ to) ->
                to == SJust (SlotNo 1_000)
