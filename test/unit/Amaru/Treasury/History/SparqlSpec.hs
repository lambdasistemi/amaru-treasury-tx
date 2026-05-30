{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.History.SparqlSpec
Description : Named RDF query and SHACL history tests
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.History.SparqlSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Word (Word64)

import Cardano.Node.Client.TxHistoryIndexer.Types
    ( HistoryScope (..)
    , TenantId (..)
    , TxDirection (..)
    , TxId (..)
    , TxRole (..)
    , TxSummaryEntry (..)
    , TxSummaryKey (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.History.Sparql
    ( HistoryQueryName (..)
    , HistoryQueryResult (..)
    , HistoryShaclResult (..)
    , HistoryShapeName (..)
    , historyShaclResultLines
    , parseHistoryShapeName
    , renderHistoryShapeName
    , runNamedHistoryQuery
    , runNamedHistoryShacl
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.History.Sparql" $ do
        it "parses and renders fixed SHACL shape names" $ do
            parseHistoryShapeName "history-entry"
                `shouldBe` Right HistoryEntryShape
            parseHistoryShapeName "indexed-tx-body"
                `shouldBe` Right IndexedTxBodyShape
            renderHistoryShapeName HistoryEntryShape
                `shouldBe` "history-entry"
            renderHistoryShapeName IndexedTxBodyShape
                `shouldBe` "indexed-tx-body"

        it "runs the metadata history query through Jena arq" $ do
            result <-
                runNamedHistoryQuery
                    HistoryEntriesQuery
                    [mkEntry 3 "0102" "disburse" "outbound"]
            case result of
                Right table -> do
                    table
                        `shouldBe` HistoryQueryResult
                            { hqrQuery = HistoryEntriesQuery
                            , hqrColumns =
                                [ "slot"
                                , "txid"
                                , "scope"
                                , "role"
                                , "direction"
                                ]
                            , hqrRows =
                                [
                                    [ "3"
                                    , "0102"
                                    , "core_development"
                                    , "disburse"
                                    , "outbound"
                                    ]
                                ]
                            }
                Left err ->
                    expectationFailure
                        ("expected history query success, got " <> show err)

        it "runs the metadata SHACL shape through Jena shacl" $ do
            result <-
                runNamedHistoryShacl
                    HistoryEntryShape
                    [mkEntry 3 "0102" "disburse" "outbound"]
            case result of
                Right report -> do
                    hsrShape report `shouldBe` HistoryEntryShape
                    hsrConforms report `shouldBe` True
                    historyShaclResultLines report
                        `shouldBe` [ "shape history-entry"
                                   , "conforms true"
                                   ]
                Left err ->
                    expectationFailure
                        ("expected SHACL success, got " <> show err)

mkEntry
    :: Word64
    -> ByteString
    -> ByteString
    -> ByteString
    -> TxSummaryEntry
mkEntry slot txid role direction =
    TxSummaryEntry
        { tseKey =
            TxSummaryKey
                { tskTenant = TenantId "treasury"
                , tskScope = HistoryScope "core_development"
                , tskSlot = SlotNo slot
                , tskTxId = TxId (hexBytes txid)
                , tskRole = TxRole role
                }
        , tsePayload = BS.empty
        , tseDirection = TxDirection direction
        }

hexBytes :: ByteString -> ByteString
hexBytes "0102" = BS.pack [0x01, 0x02]
hexBytes other = other
