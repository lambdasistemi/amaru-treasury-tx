{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.AttachSpec
Description : Unit tests for stateless witness attachment
License     : Apache-2.0
-}
module Amaru.Treasury.Api.AttachSpec (spec) where

import Data.Either (isLeft)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as TIO
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Api.Attach (attachTx)
import Amaru.Treasury.Api.Introspect (introspectTx)
import Amaru.Treasury.Api.Types
    ( ApiError (..)
    , AttachRequest (..)
    , AttachResponse (..)
    , IntrospectRequest (..)
    , IntrospectResponse (..)
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/118-vault-witness"

spec :: Spec
spec = describe "Amaru.Treasury.Api.Attach" $ do
    it "attaches a raw vkey witness and returns signed CBOR hex" $ do
        unsignedTx <- loadText "unsigned.cbor.hex"
        witness <- loadText "witness.expected.hex"
        expected <- loadText "signed.expected.cbor.hex"

        attachTx (AttachRequest unsignedTx [witness])
            `shouldBe` Right (AttachResponse expected)

    it "attaches a cardano-cli envelope vkey witness" $ do
        unsignedTx <- loadText "unsigned.cbor.hex"
        witness <- loadText "witness.expected.hex"
        expected <- loadText "signed.expected.cbor.hex"

        attachTx (AttachRequest unsignedTx ["8200" <> witness])
            `shouldBe` Right (AttachResponse expected)

    it "preserves the unsigned transaction body txid" $ do
        unsignedTx <- loadText "unsigned.cbor.hex"
        witness <- loadText "witness.expected.hex"
        AttachResponse signedTx <-
            either failApi pure $
                attachTx (AttachRequest unsignedTx [witness])

        signedTxid <- txidOf signedTx
        unsignedTxid <- txidOf unsignedTx
        signedTxid `shouldBe` unsignedTxid

    it "rejects malformed transaction hex as an API validation error" $ do
        witness <- loadText "witness.expected.hex"
        let result = attachTx (AttachRequest "zz" [witness])

        result `shouldSatisfy` isLeft
        apiErrorField result `shouldBe` Just "unsignedTx"

    it "rejects malformed witness hex as an API validation error" $ do
        unsignedTx <- loadText "unsigned.cbor.hex"
        let result = attachTx (AttachRequest unsignedTx ["zz"])

        result `shouldSatisfy` isLeft
        apiErrorField result `shouldBe` Just "witnesses"

    it "rejects an empty witness list as an API validation error" $ do
        unsignedTx <- loadText "unsigned.cbor.hex"
        let result = attachTx (AttachRequest unsignedTx [])

        result `shouldSatisfy` isLeft
        apiErrorField result `shouldBe` Just "witnesses"
        apiErrorMessage result
            `shouldSatisfy` maybe False (T.isInfixOf "at least one")

loadText :: FilePath -> IO Text
loadText file = T.strip <$> TIO.readFile (fixtureDir <> "/" <> file)

txidOf :: Text -> IO Text
txidOf cborHex =
    case introspectTx Nothing (IntrospectRequest cborHex) of
        Right IntrospectResponse{irTxid} -> pure irTxid
        Left err -> failApi err

apiErrorField :: Either ApiError a -> Maybe Text
apiErrorField = \case
    Left ApiError{aeField} -> aeField
    Right _ -> Nothing

apiErrorMessage :: Either ApiError a -> Maybe Text
apiErrorMessage = \case
    Left ApiError{aeMessage} -> Just aeMessage
    Right _ -> Nothing

failApi :: ApiError -> IO a
failApi err =
    expectationFailure (show err) *> fail "api error"
