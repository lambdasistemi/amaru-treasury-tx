{- |
Module      : Amaru.Treasury.Tx.SwapCancelSpec
Description : Structural tests for SundaeSwap order cancellation
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pins the safe subset used by Amaru-generated SundaeSwap V3 orders:
the order owner is an @AllOf@ list of signature key hashes and the
destination is the treasury script address.
-}
module Amaru.Treasury.Tx.SwapCancelSpec (spec) where

import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm, hashFromBytes)
import Cardano.Ledger.Address
    ( Addr (..)
    )
import Cardano.Ledger.Allegra.Scripts
    ( ValidityInterval (..)
    )
import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( valueTxOutL
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
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.String (fromString)
import Data.Text (Text)
import Data.Word (Word8)
import Lens.Micro ((^.))
import Numeric (showHex)
import PlutusCore.Data (Data (..))
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

import Cardano.Node.Client.TxBuild (draft)

import Amaru.Treasury.Tx.SwapCancel
    ( SwapCancelIntent (..)
    , swapCancelProgram
    )
import Amaru.Treasury.Tx.SwapCancel.Datum
    ( ParsedSwapOrderDatum (..)
    , SwapOrderDatumError (..)
    , parseSwapOrderDatum
    , renderSwapOrderDatumError
    , validateSwapOrderDatum
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

ownerKeys :: [KeyHash Guard]
ownerKeys =
    [ KeyHash (mkHash28 20)
    , KeyHash (mkHash28 21)
    , KeyHash (mkHash28 22)
    , KeyHash (mkHash28 23)
    ]

treasuryScriptHash :: ScriptHash
treasuryScriptHash = ScriptHash (mkHash28 99)

wrongTreasuryScriptHash :: ScriptHash
wrongTreasuryScriptHash = ScriptHash (mkHash28 98)

orderDatum :: Data
orderDatum =
    orderDatumWithOwner $
        Constr
            1
            [ List
                [ Constr 0 [B (hash28Bytes 20)]
                , Constr 0 [B (hash28Bytes 21)]
                , Constr 0 [B (hash28Bytes 22)]
                , Constr 0 [B (hash28Bytes 23)]
                ]
            ]

orderDatumWithOwner :: Data -> Data
orderDatumWithOwner owner =
    Constr
        0
        [ Constr 0 [B "pool-id"]
        , owner
        , I 1_280_000
        , treasuryDestination (hash28Bytes 99)
        , Constr
            1
            [ List [B "", B "", I 10_000_000]
            , List [B "policy", B "USDM", I 2_500_000]
            ]
        , Constr 0 []
        ]

treasuryDestination :: ByteString -> Data
treasuryDestination scriptHash =
    Constr
        0
        [ Constr
            0
            [ Constr 1 [B scriptHash]
            , Constr
                0
                [ Constr
                    0
                    [ Constr 1 [B scriptHash]
                    ]
                ]
            ]
        , Constr 0 []
        ]

cancelIntent :: SwapCancelIntent
cancelIntent =
    SwapCancelIntent
        { sciWalletTxIn = mkTxIn 1
        , sciOrderTxIn = mkTxIn 2
        , sciOrderValue =
            MaryValue
                (Coin 28_000_000)
                (MultiAsset Map.empty)
        , sciOrderScriptRef = mkTxIn 3
        , sciTreasuryAddress = scriptAddr 99
        , sciRequiredSigners = ownerKeys
        , sciUpperBound = SlotNo 12345
        }

spec :: Spec
spec = describe "Amaru.Treasury.Tx.SwapCancel" $ do
    describe "order datum parsing" $ do
        it "extracts all required owner signers from the Amaru AllOf policy" $ do
            parsedOrderRequiredSigners <$> parseSwapOrderDatum orderDatum
                `shouldBe` Right ownerKeys

        it "extracts the treasury destination payment script hash" $ do
            parsedOrderDestinationScript <$> parseSwapOrderDatum orderDatum
                `shouldBe` Right treasuryScriptHash

        it "validates the expected owner and destination" $ do
            validateSwapOrderDatum
                ownerKeys
                treasuryScriptHash
                orderDatum
                `shouldBe` Right
                    ParsedSwapOrderDatum
                        { parsedOrderRequiredSigners = ownerKeys
                        , parsedOrderDestinationScript =
                            treasuryScriptHash
                        }

        it "rejects owner policies outside the safe Amaru subset" $ do
            let unsupported =
                    orderDatumWithOwner $
                        Constr
                            2
                            [List [Constr 0 [B (hash28Bytes 20)]]]
            parseSwapOrderDatum unsupported
                `shouldBe` Left UnsupportedOwnerPolicy

        it "rejects an order with the wrong owner set" $ do
            validateSwapOrderDatum
                [KeyHash (mkHash28 20)]
                treasuryScriptHash
                orderDatum
                `shouldBe` Left
                    ( OrderOwnerMismatch
                        [KeyHash (mkHash28 20)]
                        ownerKeys
                    )

        it "rejects an order with the wrong treasury destination" $ do
            validateSwapOrderDatum
                ownerKeys
                wrongTreasuryScriptHash
                orderDatum
                `shouldBe` Left
                    ( OrderDestinationMismatch
                        wrongTreasuryScriptHash
                        treasuryScriptHash
                    )

        it "renders stable validation diagnostics" $ do
            renderSwapOrderDatumError UnsupportedOwnerPolicy
                `shouldBe` "unsupported owner policy; expected Amaru AllOf signatures"
            renderSwapOrderDatumError
                ( OrderOwnerMismatch
                    [KeyHash (mkHash28 20)]
                    ownerKeys
                )
                `shouldBe` ( "order owner mismatch; expected "
                                <> keyListText [20]
                                <> "; actual "
                                <> keyListText [20, 21, 22, 23]
                           )
            renderSwapOrderDatumError
                ( OrderDestinationMismatch
                    wrongTreasuryScriptHash
                    treasuryScriptHash
                )
                `shouldBe` ( "order destination mismatch; expected "
                                <> scriptHashText 98
                                <> "; actual "
                                <> scriptHashText 99
                           )

    describe "pure cancellation program" $ do
        let tx = draft emptyPParams (swapCancelProgram cancelIntent)
            body = tx ^. bodyTxL
            outs = toList (body ^. outputsTxBodyL)

        it "spends wallet fuel and the pending order" $
            body
                ^. inputsTxBodyL
                `shouldBe` Set.fromList [mkTxIn 1, mkTxIn 2]

        it "uses wallet fuel as collateral" $
            body
                ^. collateralInputsTxBodyL
                `shouldBe` Set.singleton (mkTxIn 1)

        it "references the SundaeSwap order script" $
            body
                ^. referenceInputsTxBodyL
                `shouldBe` Set.singleton (mkTxIn 3)

        it "returns the full order value to the treasury address" $ do
            case outs of
                [out] ->
                    out ^. valueTxOutL
                        `shouldBe` sciOrderValue cancelIntent
                _ -> length outs `shouldBe` 1

        it "requires all order owner signers" $
            body
                ^. reqSignerHashesTxBodyL
                `shouldBe` Set.fromList ownerKeys

        it "sets the validity upper bound" $
            invalidHereafter (body ^. vldtTxBodyL)
                `shouldBe` SJust (sciUpperBound cancelIntent)

keyListText :: [Word8] -> Text
keyListText ns =
    "[" <> foldMapWithSep "," keyHashText ns <> "]"

keyHashText :: Word8 -> Text
keyHashText n =
    "000000000000000000000000000000000000000000000000000000"
        <> digitText n

scriptHashText :: Word8 -> Text
scriptHashText = keyHashText

digitText :: Word8 -> Text
digitText n
    | n < 16 = "0" <> fromString (showHex n "")
    | otherwise = fromString (showHex n "")

foldMapWithSep :: (Monoid m) => m -> (a -> m) -> [a] -> m
foldMapWithSep _ _ [] = mempty
foldMapWithSep _ f [x] = f x
foldMapWithSep sep f (x : xs) =
    f x <> sep <> foldMapWithSep sep f xs
