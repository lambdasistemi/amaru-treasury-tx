{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Inspect.SwapOrderProjectionSpec
Description : Blueprint-backed SundaeSwap order datum projection tests
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Inspect.SwapOrderProjectionSpec (spec) where

import Data.ByteString qualified as BS
import Data.Text qualified as T

import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Conway (ConwayEra)
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Inspect.SwapOrderProjection
    ( ProjectedSwapOrder (..)
    , projectSwapOrderDatum
    )
import Amaru.Treasury.Inspect.TreasurySpendProjection
    ( ProjectedAsset (..)
    )
import Amaru.Treasury.Tx.Swap
    ( SwapOrderDatumParams (..)
    , swapOrderDatum
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Inspect.SwapOrderProjection" $
        it "projects a real amaru swap order datum via the blueprint" $
            projectSwapOrderDatum
                ( Data (swapOrderDatum sampleParams 100000000 95)
                    :: Data ConwayEra
                )
                `shouldBe` Right
                    ProjectedSwapOrder
                        { psoRecipient = T.replicate 28 "ab"
                        , psoMinReceived =
                            ProjectedAsset
                                { paPolicy = T.replicate 28 "c4"
                                , paAsset = "5553444d"
                                , paQuantity = 95
                                }
                        , psoScooperFee = 2500000
                        }

{- | A swap-order datum parameter set with recognisable byte fills so
the projected recipient / asset / fee read off cleanly.
-}
sampleParams :: SwapOrderDatumParams
sampleParams =
    SwapOrderDatumParams
        { sodPoolId = BS.replicate 28 0x99
        , sodCoreOwner = BS.replicate 28 0x01
        , sodOpsOwner = BS.replicate 28 0x02
        , sodNetworkComplianceOwner = BS.replicate 28 0x03
        , sodMiddlewareOwner = BS.replicate 28 0x04
        , sodSundaeProtocolFeeLovelace = 2500000
        , sodTreasuryScriptHash = BS.replicate 28 0xab
        , sodUsdmPolicy = BS.replicate 28 0xc4
        , sodUsdmToken = "USDM"
        }
