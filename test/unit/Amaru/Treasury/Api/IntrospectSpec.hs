{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.IntrospectSpec
Description : Unit tests for stateless transaction introspection
License     : Apache-2.0
-}
module Amaru.Treasury.Api.IntrospectSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Either (isLeft)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Api.Introspect (introspectTx)
import Amaru.Treasury.Api.Types
    ( IntrospectRequest (..)
    , IntrospectResponse (..)
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/118-vault-witness"

spec :: Spec
spec = describe "Amaru.Treasury.Api.Introspect" $ do
    it "extracts txid, required signers, TTL, and scope from a tx body" $ do
        cborHex <-
            T.strip <$> TIO.readFile (fixtureDir <> "/unsigned.cbor.hex")
        keyHash <- T.strip <$> TIO.readFile (fixtureDir <> "/key.hash")

        introspectTx Nothing (IntrospectRequest cborHex)
            `shouldBe` Right
                IntrospectResponse
                    { irTxid =
                        "62151187a797e6afee6f5d88f10d36f992ce4bb60ff7a5f741d127984fa35661"
                    , irRequiredSigners = [keyHash]
                    , irInvalidHereafter = Nothing
                    , irScope = Nothing
                    }

    it "extracts a non-null TTL from a full disburse transaction" $ do
        cborHex <- readRequestCborHex "test/fixtures/disburse/ada/body.cbor"

        fmap
            ( \r ->
                ( irRequiredSigners r
                , irInvalidHereafter r
                , irScope r
                )
            )
            (introspectTx Nothing (IntrospectRequest cborHex))
            `shouldBe` Right
                (
                    [ "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
                    , "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
                    ]
                , Just 186796799
                , Nothing
                )

    it "rejects garbage transaction CBOR" $
        introspectTx Nothing (IntrospectRequest "zz")
            `shouldSatisfy` isLeft

readRequestCborHex :: FilePath -> IO T.Text
readRequestCborHex path = do
    bytes <- BS.readFile path
    pure (TE.decodeUtf8 (B16.encode (rawCborBytes bytes)))

rawCborBytes :: BS.ByteString -> BS.ByteString
rawCborBytes bytes =
    case B16.decode bytes of
        Right decoded -> decoded
        Left _ -> bytes
