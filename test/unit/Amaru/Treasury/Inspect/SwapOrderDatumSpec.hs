{- |
Module      : Amaru.Treasury.Inspect.SwapOrderDatumSpec
Description : Round-trip tests for the SundaeSwap order datum parser
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Inspect.SwapOrderDatumSpec
    ( spec
    ) where

import PlutusCore.Data (Data (..))
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Inspect.SwapOrderDatum
    ( parseSwapOrderDatum
    )
import Amaru.Treasury.Inspect.Types
    ( ParsedSwapOrder (..)
    )
import Amaru.Treasury.Tx.Swap
    ( SwapOrderDatumParams (..)
    , swapOrderDatum
    )

testParams :: SwapOrderDatumParams
testParams =
    SwapOrderDatumParams
        { sodPoolId = "pool-id"
        , sodCoreOwner = "core-owner"
        , sodOpsOwner = "ops-owner"
        , sodNetworkComplianceOwner = "netc-owner"
        , sodMiddlewareOwner = "midw-owner"
        , sodSundaeProtocolFeeLovelace = 350_000
        , sodTreasuryScriptHash = "treasury-hash"
        , sodUsdmPolicy = "usdm-policy"
        , sodUsdmToken = "USDM"
        }

spec :: Spec
spec = describe "Amaru.Treasury.Inspect.SwapOrderDatum" $ do
    it "round-trips a datum produced by swapOrderDatum" $ do
        let lovelace = 12_500_000_000
            usdm = 3_062_500_000
            d = swapOrderDatum testParams lovelace usdm
        parseSwapOrderDatum d
            `shouldBe` Just
                ParsedSwapOrder
                    { posDestinationTreasuryHash = "treasury-hash"
                    , posLovelaceIn = lovelace
                    , posMinUsdmOut = usdm
                    , posSundaeFeeLovelace = 350_000
                    }

    it "rejects a datum with the wrong outer constructor" $ do
        parseSwapOrderDatum (Constr 99 []) `shouldBe` Nothing

    it "rejects a datum with too few fields" $ do
        parseSwapOrderDatum (Constr 0 [I 1])
            `shouldBe` Nothing

    it
        ( "rejects a datum whose destination field is not a "
            <> "well-shaped credential"
        )
        $ do
            let d =
                    Constr
                        0
                        [ Constr 0 [B "pool-id"]
                        , Constr 1 [List []]
                        , I 1_000_000
                        , I 42 -- should be Constr 0 [...] addr shape
                        , Constr
                            1
                            [ List [B "", B "", I 100]
                            , List [B "p", B "t", I 50]
                            ]
                        , Constr 0 []
                        ]
            parseSwapOrderDatum d `shouldBe` Nothing

    it "rejects a datum whose swap-params block is malformed" $ do
        let d =
                Constr
                    0
                    [ Constr 0 [B "pool-id"]
                    , Constr 1 [List []]
                    , I 1_000_000
                    , Constr
                        0
                        [ Constr
                            0
                            [ Constr 1 [B "treasury-hash"]
                            , Constr 0 []
                            ]
                        , Constr 0 []
                        ]
                    , I 999 -- should be Constr 1 [List, List]
                    , Constr 0 []
                    ]
        parseSwapOrderDatum d `shouldBe` Nothing
