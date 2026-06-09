{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Inspect.TreasurySpendProjectionSpec
Description : Blueprint-backed treasury spend redeemer projection tests
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Inspect.TreasurySpendProjectionSpec (spec) where

import Cardano.Ledger.Api.Scripts.Data (Data (..))
import Cardano.Ledger.Conway (ConwayEra)
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Inspect.TreasurySpendProjection
    ( ProjectedAsset (..)
    , ProjectedTreasurySpend (..)
    , projectTreasurySpendRedeemer
    )
import Amaru.Treasury.Redeemer
    ( disburseAdaRedeemer
    , disburseUsdmRedeemer
    , reorganizeRedeemer
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Inspect.TreasurySpendProjection" $ do
        it "projects a real ADA Disburse redeemer via the blueprint" $
            projectTreasurySpendRedeemer
                (Data (disburseAdaRedeemer 5000000) :: Data ConwayEra)
                `shouldBe` Right
                    ProjectedTreasurySpend
                        { ptsVariant = "Disburse"
                        , ptsAmount =
                            [ ProjectedAsset
                                { paPolicy = ""
                                , paAsset = ""
                                , paQuantity = 5000000
                                }
                            ]
                        }

        it "projects a USDM Disburse redeemer (ADA + asset entries)" $
            projectTreasurySpendRedeemer
                ( Data (disburseUsdmRedeemer "\196" "USDM" 95 1500000)
                    :: Data ConwayEra
                )
                `shouldBe` Right
                    ProjectedTreasurySpend
                        { ptsVariant = "Disburse"
                        , ptsAmount =
                            [ ProjectedAsset
                                { paPolicy = ""
                                , paAsset = ""
                                , paQuantity = 1500000
                                }
                            , ProjectedAsset
                                { paPolicy = "c4"
                                , paAsset = "5553444d"
                                , paQuantity = 95
                                }
                            ]
                        }

        it "projects a field-less Reorganize redeemer" $
            projectTreasurySpendRedeemer
                (Data reorganizeRedeemer :: Data ConwayEra)
                `shouldBe` Right
                    ProjectedTreasurySpend
                        { ptsVariant = "Reorganize"
                        , ptsAmount = []
                        }
