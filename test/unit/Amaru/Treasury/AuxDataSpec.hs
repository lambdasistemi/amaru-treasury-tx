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
import Data.Text qualified as T
import Data.Word (Word8)
import Test.Hspec (Spec, describe, it, shouldBe)

import Data.Text (Text)
import Data.Text.Encoding qualified as TE

import Amaru.Treasury.AuxData
    ( chunkRationale
    , disburseRationaleMetadatum
    , label1694
    , swapRationaleMetadatum
    )

utf8Len :: Text -> Int
utf8Len = BS.length . TE.encodeUtf8

{- | The chunks emitted under @body.description@ for a given
description string.
-}
descriptionChunks :: Text -> [Text]
descriptionChunks description =
    case disburseRationaleMetadatum
        "Contingency disburse"
        description
        "Contingency treasury"
        "why"
        policyId of
        Map kvs -> case lookup (S "body") kvs of
            Just (Map body) -> case lookup (S "description") body of
                Just (List chunks) -> [t | S t <- chunks]
                _ -> error "expected description list"
            _ -> error "expected body map"
        _ -> error "expected Map"

longDescription :: Text
longDescription =
    "Contingency redistribution to Core Development, Ops and "
        <> "Use Cases, and Network Compliance treasuries per the "
        <> "final allocation agreed for the 2026 budget cycle."

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
                    `shouldBe` Just (S (T.pack policyIdHex))
            _ -> error "expected Map"

    describe "chunkRationale (64-byte metadatum cap)" $ do
        it "leaves a within-cap string as a single chunk" $
            chunkRationale "short rationale"
                `shouldBe` ["short rationale"]
        it "splits an over-cap string into <=64-byte chunks" $ do
            let chunks = chunkRationale longDescription
            all ((<= 64) . utf8Len) chunks `shouldBe` True
            T.concat chunks `shouldBe` longDescription
        it "never splits across a multi-byte code point" $ do
            -- 40 × \"₳\" = 120 UTF-8 bytes (3 bytes each).
            let ada = T.replicate 40 "\x20B3"
                chunks = chunkRationale ada
            all ((<= 64) . utf8Len) chunks `shouldBe` True
            T.concat chunks `shouldBe` ada
            -- every chunk round-trips as valid UTF-8 (no broken
            -- code point): decode . encode is identity.
            map (TE.decodeUtf8 . TE.encodeUtf8) chunks
                `shouldBe` chunks

    describe "rationale metadatum honours the cap" $ do
        it "emits all description chunks within 64 bytes" $
            all ((<= 64) . utf8Len) (descriptionChunks longDescription)
                `shouldBe` True
        it "preserves a short description as one chunk" $
            descriptionChunks "Contingency split across three scopes"
                `shouldBe` ["Contingency split across three scopes"]
