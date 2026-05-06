{- |
Module      : Amaru.Treasury.Tx.DisburseSpec
Description : Draft-only smoke test for the @disburse@ builder
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Drafts 'disburseAdaProgram' with synthesized ledger
inputs and asserts the body has the expected shape.
Structural only — byte-level golden against the
@swap.sh@ output lands with 'Tx.Swap'.
-}
module Amaru.Treasury.Tx.DisburseSpec (spec) where

import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm, hashFromBytes)
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , Withdrawals (..)
    )
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    , withdrawalsTxBodyL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , mkTxIxPartial
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (bodyTxL)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys (KeyRole (..))
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

import Amaru.Treasury.Tx.Disburse
    ( DisburseAdaPayload (..)
    , DisburseIntentFields (..)
    , disburseAdaProgram
    )

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 31 0 ++ [n]

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

keyAddr :: Word8 -> Addr
keyAddr n =
    Addr
        Mainnet
        (KeyHashObj (KeyHash (mkHash28 n)))
        StakeRefNull

permissionsRewardAcct :: Word8 -> AccountAddress
permissionsRewardAcct n =
    AccountAddress
        Mainnet
        (AccountId (ScriptHashObj (ScriptHash (mkHash28 n))))

fields :: DisburseIntentFields
fields =
    DisburseIntentFields
        { difWalletUtxo = mkTxIn 0
        , difBeneficiaryAddress = keyAddr 99
        , difTreasuryUtxos = [mkTxIn 1]
        , difTreasuryAddress = scriptAddr 10
        , difPermissionsRewardAccount = permissionsRewardAcct 11
        , difScopesDeployedAt = mkTxIn 2
        , difPermissionsDeployedAt = mkTxIn 3
        , difTreasuryDeployedAt = mkTxIn 4
        , difRegistryDeployedAt = mkTxIn 5
        , difSigners =
            [ KeyHash (mkHash28 20)
            , KeyHash (mkHash28 21)
            ]
        , difUpperBound = SlotNo 1_000
        }

payload :: DisburseAdaPayload
payload =
    DisburseAdaPayload
        { dapAmountLovelace = Coin 50_000_000
        , dapLeftoverLovelace = Coin 1_400_000_000_000
        }

spec :: Spec
spec = describe "Amaru.Treasury.Tx.Disburse" $ do
    let tx =
            draft
                emptyPParams
                (disburseAdaProgram fields payload)
        body = tx ^. bodyTxL
    it "spends wallet UTxO + the treasury UTxO" $
        body
            ^. inputsTxBodyL
            `shouldBe` Set.fromList [mkTxIn 0, mkTxIn 1]
    it "uses the wallet UTxO as collateral" $
        body
            ^. collateralInputsTxBodyL
            `shouldBe` Set.singleton (mkTxIn 0)
    it
        "carries 4 reference inputs (scopes, permissions, treasury, registry)"
        $ Set.size (body ^. referenceInputsTxBodyL) `shouldBe` 4
    it "withdraw-zero against the permissions reward account" $
        body
            ^. withdrawalsTxBodyL
            `shouldBe` Withdrawals
                ( Map.singleton
                    (permissionsRewardAcct 11)
                    (Coin 0)
                )
    it "produces exactly two outputs (leftover + beneficiary)" $
        length (body ^. outputsTxBodyL) `shouldBe` 2
    it "requires both scope-owner signers" $
        body
            ^. reqSignerHashesTxBodyL
            `shouldSatisfy` \s -> Set.size s == 2
