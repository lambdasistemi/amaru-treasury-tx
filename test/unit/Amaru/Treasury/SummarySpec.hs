{- |
Module      : Amaru.Treasury.SummarySpec
Description : JSON shape regression for 'TxSummary'
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.SummarySpec (spec) where

import Data.ByteString.Lazy.Char8 qualified as BL
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Summary
    ( ExUnitsView (..)
    , RedeemerPurpose (..)
    , RedeemerSummary (..)
    , TxSummary (..)
    , encodeSummary
    )

example :: TxSummary
example =
    TxSummary
        { tsTxId =
            "0000000000000000000000000000000000000000000000000000000000000000"
        , tsFeeLovelace = 285217
        , tsRedeemers =
            [ RedeemerSummary
                { rsPurpose = RpSpend
                , rsIndex = 0
                , rsExUnits =
                    ExUnitsView
                        { euvMem = 12345
                        , euvSteps = 67890
                        }
                }
            , RedeemerSummary
                { rsPurpose = RpWithdraw
                , rsIndex = 0
                , rsExUnits =
                    ExUnitsView
                        { euvMem = 1
                        , euvSteps = 2
                        }
                }
            ]
        }

expected :: BL.ByteString
expected =
    BL.unlines
        [ "{"
        , "  \"txid\": \"00000000000000000000000000000000\
          \00000000000000000000000000000000\","
        , "  \"fee_lovelace\": 285217,"
        , "  \"redeemers\": ["
        , "    {"
        , "      \"purpose\": \"spend\","
        , "      \"index\": 0,"
        , "      \"ex_units\": {"
        , "        \"mem\": 12345,"
        , "        \"steps\": 67890"
        , "      }"
        , "    },"
        , "    {"
        , "      \"purpose\": \"withdraw\","
        , "      \"index\": 0,"
        , "      \"ex_units\": {"
        , "        \"mem\": 1,"
        , "        \"steps\": 2"
        , "      }"
        , "    }"
        , "  ]"
        , "}"
        ]

spec :: Spec
spec = describe "Amaru.Treasury.Summary" $ do
    it "renders a stable, schema-aligned JSON layout" $ do
        encodeSummary example `shouldBe` expected
