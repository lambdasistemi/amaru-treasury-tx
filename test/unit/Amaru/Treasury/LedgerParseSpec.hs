{- |
Module      : Amaru.Treasury.LedgerParseSpec
Description : Round-trip and error tests for LedgerParse
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.LedgerParseSpec (spec) where

import Data.Text (Text)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.LedgerParse
    ( keyHashFromHex
    , scriptHashFromHex
    , txInFromText
    , txInToText
    )

-- | Real values lifted from journal/2026/metadata.json.
realScriptHashHex :: Text
realScriptHashHex =
    "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"

realOwnerHex :: Text
realOwnerHex =
    "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"

realDeployedAt :: Text
realDeployedAt =
    "810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c#00"

isRight :: Either a b -> Bool
isRight = either (const False) (const True)

isLeft :: Either a b -> Bool
isLeft = either (const True) (const False)

spec :: Spec
spec = describe "Amaru.Treasury.LedgerParse" $ do
    describe "scriptHashFromHex" $ do
        it "parses the network_compliance treasury hash" $
            scriptHashFromHex realScriptHashHex
                `shouldSatisfy` isRight
        it "rejects a 27-byte hex" $
            scriptHashFromHex
                "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa"
                `shouldSatisfy` isLeft
        it "rejects non-hex input" $
            scriptHashFromHex "not hex zzz"
                `shouldSatisfy` isLeft

    describe "keyHashFromHex" $ do
        it "parses the network_compliance owner keyhash" $
            keyHashFromHex realOwnerHex
                `shouldSatisfy` isRight
        it "rejects a 29-byte hex" $
            keyHashFromHex
                "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c100"
                `shouldSatisfy` isLeft

    describe "txInFromText" $ do
        it "parses a real deployed-at reference" $
            txInFromText realDeployedAt
                `shouldSatisfy` isRight
        it "rejects a missing '#' separator" $
            txInFromText
                "810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c"
                `shouldSatisfy` isLeft
        it "rejects a non-numeric index" $
            txInFromText
                "810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c#ff"
                `shouldSatisfy` isLeft
        it "rejects a too-short txid" $
            txInFromText "deadbeef#0"
                `shouldSatisfy` isLeft

    describe "txInToText" $ do
        it "round-trips against txInFromText for a real reference" $ do
            -- Parse → render → parse must be idempotent on the
            -- payload (the rendered ix is the canonical decimal
            -- form, which may differ from a zero-padded input
            -- like "#00" — so we round-trip via parse first to
            -- normalize, then assert render . parse-of-rendered
            -- == render).
            case txInFromText realDeployedAt of
                Left e -> error ("txInFromText: " <> e)
                Right txin -> do
                    let rendered = txInToText txin
                    case txInFromText rendered of
                        Left e ->
                            error
                                ("txInFromText (round-trip): " <> e)
                        Right txin' ->
                            txInToText txin' `shouldBe` rendered
        it "renders <64-hex-txid>#<ix> shape (no '#0' padding)" $ do
            case txInFromText realDeployedAt of
                Left e -> error ("txInFromText: " <> e)
                Right txin ->
                    txInToText txin
                        `shouldBe` "810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c#0"
