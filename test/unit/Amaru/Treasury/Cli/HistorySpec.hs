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
    , appendSummaries
    , withInMemoryHistoryIndexer
    )
import Cardano.Node.Client.TxHistoryIndexer.Types
    ( HistoryScope
    , TenantId (..)
    , TxDirection (..)
    , TxId (..)
    , TxRole (..)
    , TxSummary (..)
    , TxSummaryEntry (..)
    , TxSummaryInput (..)
    , TxSummaryKey (..)
    , TxSummaryOutput (..)
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
    , TxDetailOpts (..)
    , queryScopeHistory
    , queryTxDetail
    , renderHistoryRows
    , renderTxDetail
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

        it "accepts tx-detail TXID --indexer-db" $
            case parseCliArgs
                [ "tx-detail"
                , replicate 64 'a'
                , "--indexer-db"
                , "/tmp/history-db"
                ] of
                Success (_, CmdTxDetail o) -> do
                    tdoTxId o `shouldBe` TxId (BS.replicate 32 0xaa)
                    tdoIndexerDb o `shouldBe` Just "/tmp/history-db"
                _ -> expectationFailure "expected CmdTxDetail parse"

        it "rejects a malformed tx-detail TXID" $
            isFailure ["tx-detail", "not-a-txid", "--indexer-db", "/x"]
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

    describe "tx-detail query" $
        it "uses the indexer tx-id lookup for the treasury tenant" $
            withInMemoryHistoryIndexer $ \idx -> do
                let summary =
                        mkSummary
                            treasuryTenantId
                            (scopeHistoryScope CoreDevelopment)
                            2
                            (BS.pack [0xdd])
                            "disburse"
                    otherTenant =
                        mkSummary
                            (TenantId "other")
                            (scopeHistoryScope CoreDevelopment)
                            2
                            (BS.pack [0xee])
                            "disburse"
                appendSummaries idx [otherTenant, summary]
                queryTxDetail idx (TxId (BS.pack [0xdd]))
                    `shouldReturn` Just summary

    describe "rendered rows" $ do
        it "are stable slot txid role direction ordered by the query" $
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
                    `shouldBe` [ "3 0102 swap direction=outbound"
                               , "7 abcd disburse direction=outbound"
                               ]

        it "renders no rows for an empty query" $
            renderHistoryRows [] `shouldBe` ([] :: [Text])

        it "renders inbound rows with a visible empty-role marker" $ do
            let entry =
                    ( mkEntry
                        treasuryTenantId
                        (scopeHistoryScope CoreDevelopment)
                        11
                        (BS.pack [0xde, 0xad])
                        BS.empty
                    )
                        { tseDirection = TxDirection "inbound"
                        }
            renderHistoryRows [entry]
                `shouldBe` ["11 dead - direction=inbound"]

    describe "tx-detail render" $
        it "prints the decoded detail fields" $ do
            let summary =
                    ( mkSummary
                        treasuryTenantId
                        (scopeHistoryScope CoreDevelopment)
                        9
                        (BS.pack [0x12, 0x34])
                        "withdraw"
                    )
                        { txsBlockHash = Just (BS.pack [0xab, 0xcd])
                        }
            renderTxDetail summary
                `shouldBe` [ "slot 9"
                           , "txid 1234"
                           , "scope core_development"
                           , "role withdraw"
                           , "direction outbound"
                           , "block-hash abcd"
                           , "fee 2"
                           , "required-signers signer-a,signer-b"
                           , "redeemer redeemer-summary"
                           , "input input#0 scope=core_development value=42 lovelace"
                           , "output 0 address=addr1... value=40 lovelace datum=inlineDatum"
                           ]

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

mkSummary
    :: TenantId
    -> HistoryScope
    -> Word64
    -> ByteString
    -> ByteString
    -> TxSummary
mkSummary tenant scope slot txid role =
    TxSummary
        { txsKey =
            TxSummaryKey
                { tskTenant = tenant
                , tskScope = scope
                , tskSlot = SlotNo slot
                , tskTxId = TxId txid
                , tskRole = TxRole role
                }
        , txsPayload = BS.empty
        , txsInputs =
            [ TxSummaryInput
                { tsiTxIn = "input#0"
                , tsiScope = Just scope
                , tsiValue = "42 lovelace"
                }
            ]
        , txsOutputs =
            [ TxSummaryOutput
                { tsoAddress = "addr1..."
                , tsoValue = "40 lovelace"
                , tsoDatum = Just "inlineDatum"
                }
            ]
        , txsRedeemer = Just "redeemer-summary"
        , txsFee = Just 2
        , txsRequiredSigners = ["signer-a", "signer-b"]
        , txsBlockHash = Nothing
        , txsDirection = TxDirection "outbound"
        }

isFailure :: [String] -> Bool
isFailure args = case parseCliArgs args of
    Failure{} -> True
    Success{} -> False
    CompletionInvoked{} -> False
