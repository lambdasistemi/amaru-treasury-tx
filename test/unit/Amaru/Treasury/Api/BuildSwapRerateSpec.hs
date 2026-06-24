{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.BuildSwapRerateSpec
Description : Runner tests for POST /v1/build/swap-rerate
License     : Apache-2.0
-}
module Amaru.Treasury.Api.BuildSwapRerateSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Ouroboros.Network.Magic (NetworkMagic (..))
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Api.BuildSwapRerate
    ( SwapRerateBuildRequest (..)
    , SwapRerateBuildResponse (..)
    , runBuildSwapRerate
    )
import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Cli.Common (GlobalOpts (..))
import Amaru.Treasury.Scope (ScopeId (..))

spec :: Spec
spec = describe "Amaru.Treasury.Api.BuildSwapRerate" $ do
    it "returns a within-budget single transaction response" $ do
        resp <- runFixture singleRequest
        srrDecision resp `shouldBe` Just "single_tx"
        srrCborHex resp `shouldSatisfy` maybe False (not . T.null)
        srrCborEnvelope resp
            `shouldSatisfy` maybe False ("Tx ConwayEra" `T.isInfixOf`)
        srrReport resp
            `shouldSatisfy` maybe False ("\"status\":\"single_tx\"" `T.isInfixOf`)
        srrFailureTag resp `shouldBe` Nothing
        srrFailureReason resp `shouldBe` Nothing

    it "returns a split fallback response without CBOR" $ do
        resp <- runFixture splitRequest
        srrDecision resp `shouldBe` Just "split"
        srrCborHex resp `shouldBe` Nothing
        srrCborEnvelope resp `shouldBe` Nothing
        srrReason resp `shouldBe` Just "RerateOverExecutionMemory"
        srrReport resp
            `shouldSatisfy` maybe False ("\"status\":\"split\"" `T.isInfixOf`)
        srrReport resp
            `shouldSatisfy` maybe False ("\"groups\"" `T.isInfixOf`)
        srrFailureTag resp `shouldBe` Nothing

    it "returns a typed failure for an empty selected order list" $ do
        resp <- runFixture singleRequest{srrSelectedOrders = []}
        srrDecision resp `shouldBe` Nothing
        srrCborHex resp `shouldBe` Nothing
        srrFailureTag resp `shouldBe` Just "InputInvalid"
        srrFailureReason resp
            `shouldSatisfy` maybe False ("selectedOrders" `T.isInfixOf`)

    it "returns a typed failure for a non-positive rate" $ do
        resp <- runFixture singleRequest{srrNewRate = 0}
        srrDecision resp `shouldBe` Nothing
        srrCborHex resp `shouldBe` Nothing
        srrFailureTag resp `shouldBe` Just "InputOutOfRange"
        srrFailureReason resp
            `shouldSatisfy` maybe False ("newRate" `T.isInfixOf`)

    it "returns a typed failure for a wrong-scope selected order" $ do
        resp <- runFixture singleRequest{srrScope = Middleware}
        srrDecision resp `shouldBe` Nothing
        srrCborHex resp `shouldBe` Nothing
        srrFailureTag resp `shouldBe` Just "wrong_scope"
        srrFailureReason resp
            `shouldSatisfy` maybe False ("network_compliance" `T.isInfixOf`)
        srrFailureReason resp
            `shouldSatisfy` maybe False ("middleware" `T.isInfixOf`)

runFixture :: SwapRerateBuildRequest -> IO SwapRerateBuildResponse
runFixture =
    runBuildSwapRerate
        mainnetOpts
        "test/fixtures/metadata.json"
        unusedBackend

mainnetOpts :: GlobalOpts
mainnetOpts =
    GlobalOpts
        { goSocketPath = Nothing
        , goNetworkMagic = NetworkMagic 764_824_073
        , goNetworkName = Just "mainnet"
        }

unusedBackend :: Backend
unusedBackend =
    error "offline swap-rerate runner must not touch the backend"

singleRequest :: SwapRerateBuildRequest
singleRequest =
    SwapRerateBuildRequest
        { srrScope = NetworkCompliance
        , srrSelectedOrders = [syntheticOrderTxIn]
        , srrNewRate = 0.3
        , srrWalletTxIn =
            "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"
        , srrCollateralTxIn = Nothing
        }

splitRequest :: SwapRerateBuildRequest
splitRequest =
    singleRequest{srrSelectedOrders = manyOrderTxIns}

syntheticOrderTxIn :: Text
syntheticOrderTxIn =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#0"

manyOrderTxIns :: [Text]
manyOrderTxIns =
    [ T.justifyRight 64 '0' (T.pack (show n)) <> "#0"
    | n <- [100 .. 140 :: Int]
    ]
