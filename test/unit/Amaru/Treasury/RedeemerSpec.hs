{- |
Module      : Amaru.Treasury.RedeemerSpec
Description : CBOR-byte assertions for the redeemers
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pins the canonical Plutus-data CBOR encoding produced by
'Codec.Serialise.serialise'. The expected hex strings
were captured once locally and committed; any future
change in 'Amaru.Treasury.Redeemer' or in the upstream
'PlutusCore.Data' encoder will fail one of these
assertions and surface a deliberate review.
-}
module Amaru.Treasury.RedeemerSpec (spec) where

import Codec.Serialise (deserialiseOrFail, serialise)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BL
import PlutusCore.Data (Data)
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Redeemer
    ( disburseAdaRedeemer
    , disburseRedeemer
    , emptyListRedeemer
    , reorganizeRedeemer
    , sundaeCancelRedeemer
    )

hex :: Data -> BS.ByteString
hex = B16.encode . BL.toStrict . serialise

roundTrip :: Data -> Data
roundTrip d = case deserialiseOrFail (serialise d) of
    Right d' -> d'
    Left e -> error (show e)

spec :: Spec
spec = describe "Amaru.Treasury.Redeemer" $ do
    it "encodes Reorganize as Constr 0 []" $ do
        hex reorganizeRedeemer `shouldBe` "d87980"

    it "encodes the empty-list redeemer as []" $ do
        hex emptyListRedeemer `shouldBe` "80"

    it "encodes the SundaeSwap V3 Cancel redeemer as Constr 1 []" $ do
        hex sundaeCancelRedeemer `shouldBe` "d87a80"

    it "encodes a 1 ADA disburse with empty policy/asset" $ do
        hex (disburseAdaRedeemer 1_000_000)
            `shouldBe` "d87c9fa140a1401a000f4240ff"

    it "encodes a USDM disburse with the deployed policy/asset" $ do
        let policy =
                BS.pack
                    "\xc4\x8c\xbb\x3d\x5e\x57\xed\x56\xe2\x76\xbc\x45\
                    \\xf9\x9a\xb3\x9a\xbe\x94\xe6\xcd\x7a\xc3\x9f\xb4\
                    \\x02\xda\x47\xad"
            asset =
                BS.pack
                    "\x00\x14\xdf\x10\x55\x53\x44\x4d"
        hex (disburseRedeemer policy asset 50_000_000)
            `shouldBe` "d87c9fa1581cc48cbb3d5e57ed56e276bc45f99a\
                       \b39abe94e6cd7ac39fb402da47ada1480014df10\
                       \5553444d1a02faf080ff"

    it "round-trips every redeemer through CBOR" $ do
        roundTrip reorganizeRedeemer `shouldBe` reorganizeRedeemer
        roundTrip emptyListRedeemer `shouldBe` emptyListRedeemer
        roundTrip sundaeCancelRedeemer `shouldBe` sundaeCancelRedeemer
        roundTrip (disburseAdaRedeemer 42)
            `shouldBe` disburseAdaRedeemer 42
