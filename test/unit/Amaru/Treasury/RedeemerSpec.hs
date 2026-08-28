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
import Data.ByteString qualified as StrictBS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BS
import Data.ByteString.Lazy qualified as BL
import PlutusCore.Data (Data (B, Constr, I, Map))
import Test.Hspec (Spec, describe, it, shouldBe, shouldNotBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
    ( Property
    , arbitrary
    , conjoin
    , counterexample
    , forAll
    , property
    , (===)
    )
import Test.QuickCheck.Gen
    ( Gen
    , choose
    , chooseInteger
    , elements
    , frequency
    , vectorOf
    )

import Amaru.Treasury.Redeemer
    ( disburseAdaRedeemer
    , disburseRedeemer
    , disburseUsdmRedeemer
    , emptyListRedeemer
    , otcSwapRedeemer
    , reorganizeRedeemer
    , sundaeCancelRedeemer
    )

-- Mehen USDM, as deployed on mainnet.
usdmPolicy :: BS.ByteString
usdmPolicy =
    BS.pack
        "\xc4\x8c\xbb\x3d\x5e\x57\xed\x56\xe2\x76\xbc\x45\
        \\xf9\x9a\xb3\x9a\xbe\x94\xe6\xcd\x7a\xc3\x9f\xb4\
        \\x02\xda\x47\xad"

usdmAsset :: BS.ByteString
usdmAsset = BS.pack "\x00\x14\xdf\x10\x55\x53\x44\x4d"

hex :: Data -> BS.ByteString
hex = B16.encode . BL.toStrict . serialise

roundTrip :: Data -> Data
roundTrip d = case deserialiseOrFail (serialise d) of
    Right d' -> d'
    Left e -> error (show e)

{- | One generated OTC trade: policy id, asset name, positive
incoming quantity, positive lovelace out.
-}
type OtcLegs =
    (StrictBS.ByteString, StrictBS.ByteString, Integer, Integer)

{- | Positive 'Integer' across magnitudes: small values, values at
and just above the 32-bit boundary, and values far above 2^32.
-}
genPositiveInteger :: Gen Integer
genPositiveInteger =
    frequency
        [ (3, chooseInteger (1, 1_000_000))
        , (1, elements [1, 2 ^ (32 :: Int), 2 ^ (32 :: Int) + 1])
        , (2, chooseInteger (2 ^ (32 :: Int) + 2, 2 ^ (128 :: Int)))
        ]

{- | Minting-policy ids: sometimes empty, often 28-byte
mainnet-shaped, sometimes another length.
-}
genPolicyId :: Gen StrictBS.ByteString
genPolicyId = do
    n <-
        frequency
            [ (1, pure 0)
            , (1, pure 28)
            , (2, choose (1, 40))
            ]
    StrictBS.pack <$> vectorOf n arbitrary

-- | Asset names: empty, USDM-length, and other lengths.
genAssetName :: Gen StrictBS.ByteString
genAssetName = do
    n <-
        frequency
            [ (1, pure 0)
            , (1, pure 8)
            , (2, choose (1, 64))
            ]
    StrictBS.pack <$> vectorOf n arbitrary

{- | Generated positive legs for the OTC swap: the encoder's stated
precondition (@q > 0@, @l > 0@) over varying policy and asset
shapes.
-}
genPositiveOtcLegs :: Gen OtcLegs
genPositiveOtcLegs = do
    p <- genPolicyId
    a <- genAssetName
    q <- genPositiveInteger
    l <- genPositiveInteger
    pure (p, a, q, l)

{- | Oracle property: for generated legs, the OTC encoder is exactly
the disburse encoder with the incoming leg negated.
-}
prop_otcSwapMatchesDisburseOracle :: Property
prop_otcSwapMatchesDisburseOracle =
    forAll genPositiveOtcLegs $ \(p, a, q, l) ->
        otcSwapRedeemer p a q l
            === disburseUsdmRedeemer p a (negate q) l

{- | Structural property on generated input: constructor 3; the ADA
leg comes FIRST in the map, keyed on empty bytes with @I l@,
@l > 0@; the asset leg is keyed on the generated policy and name
with @I (negate q)@, strictly negative for @q > 0@. Key order is
load-bearing for byte identity (audit finding F1, submission 1).
-}
prop_otcSwapLegs :: Property
prop_otcSwapLegs =
    forAll genPositiveOtcLegs $ \(p, a, q, l) ->
        case otcSwapRedeemer p a q l of
            Constr tag [Map entries] ->
                conjoin
                    [ tag === 3
                    , entries
                        === [ (B "", Map [(B "", I l)])
                            , (B p, Map [(B a, I (negate q))])
                            ]
                    , property (l > 0)
                    , property (negate q < 0)
                    ]
            other ->
                counterexample
                    ("unexpected Data shape: " <> show other)
                    False

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

    it "encodes a USDM disburse with treasury-funded min-UTxO lovelace" $ do
        let policy =
                BS.pack
                    "\xc4\x8c\xbb\x3d\x5e\x57\xed\x56\xe2\x76\xbc\x45\
                    \\xf9\x9a\xb3\x9a\xbe\x94\xe6\xcd\x7a\xc3\x9f\xb4\
                    \\x02\xda\x47\xad"
            asset =
                BS.pack
                    "\x00\x14\xdf\x10\x55\x53\x44\x4d"
        hex (disburseUsdmRedeemer policy asset 50_000_000 2_000_000)
            `shouldBe` "d87c9fa240a1401a001e8480581cc48cbb3d5e57\
                       \ed56e276bc45f99ab39abe94e6cd7ac39fb402da\
                       \47ada1480014df105553444d1a02faf080ff"

    -- Issue #499. The expected bytes below are NOT captured from this
    -- encoder: they are lifted from the spend redeemer of mainnet
    -- transaction 9ed505b48df617716423f58687283ee5e130684d8b3b6c9f2ed03b473c0154f1,
    -- an OTC swap the treasury validator accepted on 2026-08-28
    -- (10.000000 USDM into ops_and_use_cases for 47.619047 ADA out).
    -- Agreeing with it is evidence about the chain, not about us.
    describe "otcSwapRedeemer (#499)" $ do
        it "reproduces the on-chain reference redeemer byte-for-byte" $ do
            hex (otcSwapRedeemer usdmPolicy usdmAsset 10_000_000 47_619_047)
                `shouldBe` "d87c9fa240a1401a02d69be7581cc48cbb3d5e57\
                           \ed56e276bc45f99ab39abe94e6cd7ac39fb402da\
                           \47ada1480014df105553444d3a0098967fff"

        -- Negative control for the assertion above: the sign of the
        -- incoming leg is the entire mechanism, so a positive leg must
        -- NOT reproduce the on-chain bytes. Without this, the pin above
        -- could pass for a build that never negates anything.
        it "does not match when the incoming leg is left positive" $ do
            let onChain =
                    "d87c9fa240a1401a02d69be7581cc48cbb3d5e57\
                    \ed56e276bc45f99ab39abe94e6cd7ac39fb402da\
                    \47ada1480014df105553444d3a0098967fff"
            hex (disburseUsdmRedeemer usdmPolicy usdmAsset 10_000_000 47_619_047)
                `shouldNotBe` onChain

        it "negates the incoming leg and leaves the ADA leg positive" $ do
            otcSwapRedeemer usdmPolicy usdmAsset 10_000_000 47_619_047
                `shouldBe` disburseUsdmRedeemer
                    usdmPolicy
                    usdmAsset
                    (-10_000_000)
                    47_619_047

        -- The single vector above is the tie to reality; these two
        -- properties make the encoder a function over all positive
        -- legs, not a lookup table for one tuple (audit finding F1).
        prop
            "equals the disburse oracle on generated positive legs"
            prop_otcSwapMatchesDisburseOracle

        prop
            "keeps the ADA leg first-positive and the asset leg negative"
            prop_otcSwapLegs

    it "round-trips every redeemer through CBOR" $ do
        roundTrip reorganizeRedeemer `shouldBe` reorganizeRedeemer
        roundTrip emptyListRedeemer `shouldBe` emptyListRedeemer
        roundTrip sundaeCancelRedeemer `shouldBe` sundaeCancelRedeemer
        roundTrip (disburseAdaRedeemer 42)
            `shouldBe` disburseAdaRedeemer 42
        roundTrip (otcSwapRedeemer usdmPolicy usdmAsset 42 43)
            `shouldBe` otcSwapRedeemer usdmPolicy usdmAsset 42 43
