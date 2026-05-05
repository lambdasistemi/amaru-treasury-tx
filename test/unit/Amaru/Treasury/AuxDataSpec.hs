{- |
Module      : Amaru.Treasury.AuxDataSpec
Description : Structural tests for the rationale metadatum
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Verifies that 'swapRationaleMetadatum' produces the
JSON-source field order @cardano-cli@ encodes
(@body@, @\@context@, @instance@, @hashAlgorithm@) and
that the @instance@ string is the hex of the registry
policy id.
-}
module Amaru.Treasury.AuxDataSpec (spec) where

import Cardano.Ledger.Metadata (Metadatum (..))
import Data.ByteString qualified as BS
import Data.Word (Word8)
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.AuxData
    ( label1694
    , swapRationaleMetadatum
    )

policyId :: BS.ByteString
policyId =
    BS.pack
        ( [0x38, 0xc6, 0x27, 0xd4]
            ++ replicate 24 (0 :: Word8)
        )

policyIdHex :: String
policyIdHex =
    "38c627d40000000000000000"
        ++ "00000000000000000000000000000000"

metadatum :: Metadatum
metadatum =
    swapRationaleMetadatum
        "Swapping ADA for $100k at a rate of $0.245 per ADA"
        "Network Compliance's treasury"
        "Required to pay Antithesis as vendor"
        policyId

topLevelKeys :: Metadatum -> [String]
topLevelKeys (Map kvs) =
    [ k
    | (S t, _) <- kvs
    , let k = show t
    ]
topLevelKeys _ = []

spec :: Spec
spec = describe "Amaru.Treasury.AuxData" $ do
    it "label is 1694" $
        label1694 `shouldBe` 1694
    it "top-level fields appear in JSON-source order" $
        topLevelKeys metadatum
            `shouldBe` map
                show
                ( ["body", "@context", "instance", "hashAlgorithm"]
                    :: [String]
                )
    it "instance is the hex of the registry policy id" $
        case metadatum of
            Map kvs ->
                lookup (S "instance") kvs
                    `shouldBe` Just (S (read (show policyIdHex)))
            _ -> error "expected Map"
