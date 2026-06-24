{- |
Module      : Amaru.Treasury.Swap.RerateSpec
Description : Structural tests for pure swap re-rate body building
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Drafts the pure re-rate program against synthesized inputs and pins the
cancel-and-reoffer body shape: wallet fuel, one script spend per
selected order, the Sundae order reference plus scope references,
withdraw-zero, required scope signers, one inline-datum replacement
order output per cancelled order, and one treasury return output per
cancelled order.
-}
module Amaru.Treasury.Swap.RerateSpec (spec) where

import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm, hashFromBytes)
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , Withdrawals (..)
    )
import Cardano.Ledger.Allegra.Scripts
    ( ValidityInterval (..)
    )
import Cardano.Ledger.Api.Era (ConwayEra)
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    , vldtTxBodyL
    , withdrawalsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    , mkTxIxPartial
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (TxOut, bodyTxL)
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
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.Plutus.Data
    ( Datum (..)
    , binaryDataToData
    , getPlutusData
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Word (Word8)
import Lens.Micro ((^.))
import PlutusCore.Data (Data)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Cardano.Tx.Build (draft)

import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Swap.Rerate
    ( RerateProgramInputs (..)
    , rerateProgram
    )
import Amaru.Treasury.Swap.Rerate.Plan (planRerate)
import Amaru.Treasury.Swap.Rerate.Types
    ( PlannedRerate
    , RerateIntent (..)
    , RerateOrder (..)
    , RerateScopeContext (..)
    )
import Amaru.Treasury.Tx.Swap
    ( SwapOrderDatumParams (..)
    , swapOrderDatum
    )

mkHash32 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash32 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 31 0 ++ [n]

mkHash28 :: (HashAlgorithm h) => Word8 -> Hash h a
mkHash28 n =
    fromJust . hashFromBytes . BS.pack $
        replicate 27 0 ++ [n]

hash28Bytes :: Word8 -> ByteString
hash28Bytes n = BS.pack $ replicate 27 0 ++ [n]

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

permissionsRewardAcct :: Word8 -> AccountAddress
permissionsRewardAcct n =
    AccountAddress
        Mainnet
        (AccountId (ScriptHashObj (ScriptHash (mkHash28 n))))

ownerKeys :: [KeyHash Guard]
ownerKeys =
    [ KeyHash (mkHash28 20)
    , KeyHash (mkHash28 21)
    , KeyHash (mkHash28 22)
    , KeyHash (mkHash28 23)
    ]

treasuryScriptHash :: ScriptHash
treasuryScriptHash = ScriptHash (mkHash28 99)

datumParams :: SwapOrderDatumParams
datumParams =
    SwapOrderDatumParams
        { sodPoolId = "pool-id"
        , sodCoreOwner = hash28Bytes 20
        , sodOpsOwner = hash28Bytes 21
        , sodNetworkComplianceOwner = hash28Bytes 22
        , sodMiddlewareOwner = hash28Bytes 23
        , sodSundaeProtocolFeeLovelace = 1_280_000
        , sodTreasuryScriptHash = hash28Bytes 99
        , sodUsdmPolicy = "policy"
        , sodUsdmToken = "USDM"
        }

scopeContext :: RerateScopeContext
scopeContext =
    RerateScopeContext
        { rscScope = NetworkCompliance
        , rscExpectedOwners = ownerKeys
        , rscTreasuryScriptHash = treasuryScriptHash
        , rscOrderExtraLovelace = Coin 3_280_000
        , rscDatumParams = datumParams
        }

programInputs :: RerateProgramInputs
programInputs =
    RerateProgramInputs
        { rpiWalletTxIn = mkTxIn 0
        , rpiExtraWalletTxIns = []
        , rpiOrderScriptRef = mkTxIn 40
        , rpiSwapOrderAddress = scriptAddr 50
        , rpiTreasuryAddress = scriptAddr 99
        , rpiPermissionsRewardAccount = permissionsRewardAcct 11
        , rpiScopesDeployedAt = mkTxIn 2
        , rpiPermissionsDeployedAt = mkTxIn 3
        , rpiTreasuryDeployedAt = mkTxIn 4
        , rpiRegistryDeployedAt = mkTxIn 5
        , rpiUpperBound = SlotNo 12_345
        }

intentWith :: [RerateOrder] -> RerateIntent
intentWith orders =
    RerateIntent
        { riScopeContext = scopeContext
        , riOrders = orders
        , riRateNumerator = 3
        , riRateDenominator = 10
        }

orderWith :: Word8 -> Integer -> RerateOrder
orderWith n offered =
    RerateOrder
        { rroTxIn = mkTxIn n
        , rroScope = NetworkCompliance
        , rroValue =
            MaryValue
                (Coin (offered + 3_280_000))
                (MultiAsset Map.empty)
        , rroDatum = orderDatum offered (offered `div` 4)
        }

order1 :: RerateOrder
order1 = orderWith 1 10_000_000

order2 :: RerateOrder
order2 = orderWith 2 20_000_000

orderDatum :: Integer -> Integer -> Data
orderDatum = swapOrderDatum datumParams

planned :: [RerateOrder] -> PlannedRerate
planned orders =
    case planRerate (intentWith orders) of
        Right p -> p
        Left err -> error $ "unexpected re-rate plan failure: " <> show err

replacementOutputs :: [RerateOrder] -> [TxOut ConwayEra]
replacementOutputs orders =
    toList $
        draft emptyPParams (rerateProgram programInputs (planned orders))
            ^. bodyTxL
                . outputsTxBodyL

inlineDatumData :: TxOut ConwayEra -> Maybe Data
inlineDatumData out =
    case out ^. datumTxOutL of
        Datum datum -> Just $ getPlutusData (binaryDataToData datum)
        _ -> Nothing

spec :: Spec
spec = describe "Amaru.Treasury.Swap.Rerate" $ do
    let tx = draft emptyPParams (rerateProgram programInputs (planned [order1]))
        body = tx ^. bodyTxL
        outs = toList (body ^. outputsTxBodyL)

    it "builds a single-order cancel-and-reoffer body" $ do
        body
            ^. inputsTxBodyL
            `shouldBe` Set.fromList [mkTxIn 0, mkTxIn 1]
        body
            ^. collateralInputsTxBodyL
            `shouldBe` Set.singleton (mkTxIn 0)
        body
            ^. referenceInputsTxBodyL
            `shouldBe` Set.fromList
                [ mkTxIn 2
                , mkTxIn 3
                , mkTxIn 4
                , mkTxIn 5
                , mkTxIn 40
                ]
        body
            ^. withdrawalsTxBodyL
            `shouldBe` Withdrawals
                (Map.singleton (permissionsRewardAcct 11) (Coin 0))
        body
            ^. reqSignerHashesTxBodyL
            `shouldBe` Set.fromList ownerKeys
        invalidHereafter (body ^. vldtTxBodyL)
            `shouldBe` SJust (SlotNo 12_345)
        length outs `shouldBe` 2
        case outs of
            [replacement, treasuryReturn] -> do
                inlineDatumData replacement
                    `shouldBe` Just (orderDatum 10_000_000 3_000_000)
                treasuryReturn
                    ^. addrTxOutL
                    `shouldBe` rpiTreasuryAddress programInputs
                treasuryReturn
                    ^. valueTxOutL
                    `shouldBe` rroValue order1
            _ -> expectationFailure "expected exactly two outputs"

    it "emits one replacement output per cancelled order" $ do
        let tx2 =
                draft
                    emptyPParams
                    (rerateProgram programInputs (planned [order1, order2]))
            body2 = tx2 ^. bodyTxL
        body2
            ^. inputsTxBodyL
            `shouldBe` Set.fromList [mkTxIn 0, mkTxIn 1, mkTxIn 2]
        length (toList (body2 ^. outputsTxBodyL)) `shouldBe` 4
        body2
            ^. reqSignerHashesTxBodyL
            `shouldBe` Set.fromList ownerKeys

    it "spends extra wallet fuel without making it collateral" $ do
        let extraWalletTxIn = mkTxIn 9
            inputs =
                programInputs
                    { rpiExtraWalletTxIns = [extraWalletTxIn]
                    }
            txExtra =
                draft
                    emptyPParams
                    (rerateProgram inputs (planned [order1]))
            bodyExtra = txExtra ^. bodyTxL
        bodyExtra
            ^. inputsTxBodyL
            `shouldBe` Set.fromList [mkTxIn 0, extraWalletTxIn, mkTxIn 1]
        bodyExtra
            ^. collateralInputsTxBodyL
            `shouldBe` Set.singleton (mkTxIn 0)

    it "preserves offered ADA plus the order extra lovelace" $ do
        case replacementOutputs [order1] of
            out : _ ->
                out
                    ^. valueTxOutL
                    `shouldBe` MaryValue
                        (Coin 13_280_000)
                        (MultiAsset Map.empty)
            _ -> expectationFailure "expected exactly one output"

    it "uses inline datums built at the new rate" $
        map inlineDatumData (take 2 (replacementOutputs [order1, order2]))
            `shouldBe` [ Just (orderDatum 10_000_000 3_000_000)
                       , Just (orderDatum 20_000_000 6_000_000)
                       ]
