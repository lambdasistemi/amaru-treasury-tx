{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.HistorySpec
Description : Indexed history API adapter tests
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Api.HistorySpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Word (Word64)

import Cardano.Node.Client.TxHistoryIndexer.Indexer
    ( appendHistory
    , withInMemoryHistoryIndexer
    )
import Cardano.Node.Client.TxHistoryIndexer.Types
    ( HistoryScope
    , TenantId (..)
    , TxDirection (..)
    , TxId (..)
    , TxRole (..)
    , TxSummaryEntry (..)
    , TxSummaryKey (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Test.Hspec (Spec, describe, it, shouldReturn)

import Amaru.Treasury.Api.History
    ( queryScopeHistoryResponse
    )
import Amaru.Treasury.Api.Types
    ( ScopeHistoryEntry (..)
    , ScopeHistoryResponse (..)
    )
import Amaru.Treasury.Cli.History (scopeHistoryScope)
import Amaru.Treasury.Indexer.Decoder (treasuryTenantId)
import Amaru.Treasury.Scope (ScopeId (..))

spec :: Spec
spec =
    describe "Amaru.Treasury.Api.History" $
        it "serves treasury tenant rows for the selected scope" $
            withInMemoryHistoryIndexer $ \idx -> do
                let core =
                        mkEntry
                            treasuryTenantId
                            (scopeHistoryScope CoreDevelopment)
                            3
                            (BS.pack [0x01, 0x02])
                            "disburse"
                    middleware =
                        mkEntry
                            treasuryTenantId
                            (scopeHistoryScope Middleware)
                            4
                            (BS.pack [0xaa])
                            "withdraw"
                    otherTenant =
                        mkEntry
                            (TenantId "other")
                            (scopeHistoryScope CoreDevelopment)
                            5
                            (BS.pack [0xbb])
                            "swap"
                appendHistory idx [middleware, otherTenant, core]
                queryScopeHistoryResponse idx CoreDevelopment
                    `shouldReturn` ScopeHistoryResponse
                        { shrScope = CoreDevelopment
                        , shrEntries =
                            [ ScopeHistoryEntry
                                { sheSlot = 3
                                , sheTxId = "0102"
                                , sheRole = "disburse"
                                , sheDirection = "outbound"
                                }
                            ]
                        }

mkEntry
    :: TenantId
    -> HistoryScope
    -> Word64
    -> ByteString
    -> ByteString
    -> TxSummaryEntry
mkEntry tenant scope slot txid role =
    TxSummaryEntry
        { tseKey =
            TxSummaryKey
                { tskTenant = tenant
                , tskScope = scope
                , tskSlot = SlotNo slot
                , tskTxId = TxId txid
                , tskRole = TxRole role
                }
        , tsePayload = BS.empty
        , tseDirection = TxDirection "outbound"
        }
