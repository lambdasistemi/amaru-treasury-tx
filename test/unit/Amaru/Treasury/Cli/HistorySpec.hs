{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.HistorySpec
Description : Parser, query, and render tests for @history@
License     : Apache-2.0

Slice-4 contract for the local @history@ read path. Proves:

  * the top-level parser accepts
    @history --scope core_development --indexer-db PATH@ and binds
    the scope and database options;
  * a missing or unknown @--scope@ is rejected by optparse;
  * an in-memory history query filters by the fixed treasury tenant
    and the selected scope;
  * rendered rows are the stable @slot txid role@ form, ordered by
    the upstream indexer query regardless of append order;
  * an empty query renders no rows.
-}
module Amaru.Treasury.Cli.HistorySpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Text (Text)
import Data.Word (Word64)

import Cardano.Node.Client.TxHistoryIndexer.Indexer
    ( appendHistory
    , withInMemoryHistoryIndexer
    )
import Cardano.Node.Client.TxHistoryIndexer.Types
    ( HistoryScope
    , TenantId (..)
    , TxId (..)
    , TxRole (..)
    , TxSummaryEntry (..)
    , TxSummaryKey (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Options.Applicative (ParserResult (..))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldReturn
    )

import Amaru.Treasury.Cli (Cmd (..), parseCliArgs)
import Amaru.Treasury.Cli.History
    ( HistoryOpts (..)
    , queryScopeHistory
    , renderHistoryRows
    , scopeHistoryScope
    )
import Amaru.Treasury.Indexer.Decoder (treasuryTenantId)
import Amaru.Treasury.Scope (ScopeId (..))

spec :: Spec
spec = describe "Amaru.Treasury.Cli.History" $ do
    describe "top-level parser" $ do
        it "accepts history --scope core_development --indexer-db" $
            case parseCliArgs
                [ "history"
                , "--scope"
                , "core_development"
                , "--indexer-db"
                , "/tmp/history-db"
                ] of
                Success (_, CmdHistory o) -> do
                    hoScope o `shouldBe` CoreDevelopment
                    hoIndexerDb o `shouldBe` Just "/tmp/history-db"
                _ -> expectationFailure "expected CmdHistory parse"

        it "rejects a missing --scope" $
            isFailure ["history"] `shouldBe` True

        it "rejects an unknown --scope" $
            isFailure
                ["history", "--scope", "bogus", "--indexer-db", "/x"]
                `shouldBe` True

    describe "in-memory query" $
        it "filters by treasury tenant and selected scope" $
            withInMemoryHistoryIndexer $ \idx -> do
                let eCore =
                        mkEntry
                            treasuryTenantId
                            (scopeHistoryScope CoreDevelopment)
                            1
                            (BS.pack [0xaa])
                            "disburse"
                    eMid =
                        mkEntry
                            treasuryTenantId
                            (scopeHistoryScope Middleware)
                            1
                            (BS.pack [0xbb])
                            "withdraw"
                    eOther =
                        mkEntry
                            (TenantId "other")
                            (scopeHistoryScope CoreDevelopment)
                            1
                            (BS.pack [0xcc])
                            "disburse"
                appendHistory idx [eCore, eMid, eOther]
                queryScopeHistory idx CoreDevelopment
                    `shouldReturn` [eCore]

    describe "rendered rows" $ do
        it "are stable slot txid role ordered by the query" $
            withInMemoryHistoryIndexer $ \idx -> do
                let later =
                        mkEntry
                            treasuryTenantId
                            (scopeHistoryScope CoreDevelopment)
                            7
                            (BS.pack [0xab, 0xcd])
                            "disburse"
                    earlier =
                        mkEntry
                            treasuryTenantId
                            (scopeHistoryScope CoreDevelopment)
                            3
                            (BS.pack [0x01, 0x02])
                            "swap"
                appendHistory idx [later, earlier]
                rows <-
                    renderHistoryRows
                        <$> queryScopeHistory idx CoreDevelopment
                rows
                    `shouldBe` [ "3 0102 swap"
                               , "7 abcd disburse"
                               ]

        it "renders no rows for an empty query" $
            renderHistoryRows [] `shouldBe` ([] :: [Text])

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
        }

isFailure :: [String] -> Bool
isFailure args = case parseCliArgs args of
    Failure{} -> True
    Success{} -> False
    CompletionInvoked{} -> False
