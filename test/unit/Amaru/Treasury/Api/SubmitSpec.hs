{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.SubmitSpec
Description : Unit tests for preflighted stateless submit
License     : Apache-2.0
-}
module Amaru.Treasury.Api.SubmitSpec (spec) where

import Data.ByteString.Base16 qualified as B16
import Data.IORef
    ( IORef
    , atomicModifyIORef'
    , newIORef
    , readIORef
    )
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Node.Client.TxHistoryIndexer.BlockExtract
    ( BlockTx (..)
    )

import Amaru.Treasury.Api.Submit
    ( SubmitDependencies (..)
    , classifyTreasuryTx
    , submitTx
    )
import Amaru.Treasury.Api.Types
    ( ApiError (..)
    , SubmitRequest (..)
    , SubmitResponse (..)
    )
import Amaru.Treasury.Indexer.DecoderFixtures
    ( RoleFixture (..)
    , disburseFixture
    )

spec :: Spec
spec = describe "Amaru.Treasury.Api.Submit" $ do
    it "rejects non-treasury transactions before broadcast" $ do
        calls <- newIORef (0 :: Int)
        nonTreasury <- loadText nonTreasuryFixture

        result <-
            submitTx
                (testDeps calls)
                (SubmitRequest nonTreasury)

        result `shouldSatisfy` isApiError
        apiErrorField result `shouldBe` Just "cborHex"
        readIORef calls >>= (`shouldBe` 0)

    it "rejects Phase-1 failures before broadcast" $ do
        calls <- newIORef (0 :: Int)
        let phase1Error =
                ApiError
                    { aeMessage = "Phase-1 validation rejected"
                    , aeField = Just "cborHex"
                    }
            deps =
                (testDeps calls)
                    { sdPreflightPhase1 = \_ ->
                        pure (Left phase1Error)
                    }

        result <- submitTx deps (SubmitRequest treasuryFixtureHex)

        result `shouldBe` Left phase1Error
        readIORef calls >>= (`shouldBe` 0)

    it "broadcasts a treasury-shaped transaction after preflight" $ do
        calls <- newIORef (0 :: Int)

        result <-
            submitTx
                (testDeps calls)
                (SubmitRequest treasuryFixtureHex)

        result `shouldBe` Right (SubmitResponse sampleTxId)
        readIORef calls >>= (`shouldBe` 1)

testDeps :: IORef Int -> SubmitDependencies
testDeps calls =
    SubmitDependencies
        { sdClassifyTreasury = classifyTreasuryTx [] []
        , sdPreflightPhase1 = \_ -> pure (Right ())
        , sdBroadcast = \_ -> do
            atomicModifyIORef' calls $ \n -> (n + 1, ())
            pure (Right sampleTxId)
        }

isApiError :: Either ApiError a -> Bool
isApiError = \case
    Left _ -> True
    Right _ -> False

apiErrorField :: Either ApiError a -> Maybe Text
apiErrorField = \case
    Left ApiError{aeField} -> aeField
    Right _ -> Nothing

treasuryFixtureHex :: Text
treasuryFixtureHex =
    TE.decodeUtf8 (B16.encode (unBlockTx (fixtureTx disburseFixture)))

nonTreasuryFixture :: FilePath
nonTreasuryFixture = "test/fixtures/118-vault-witness/signed.expected.cbor.hex"

sampleTxId :: Text
sampleTxId =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

loadText :: FilePath -> IO Text
loadText = TIO.readFile
