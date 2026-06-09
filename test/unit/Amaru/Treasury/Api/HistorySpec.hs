{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.HistorySpec
Description : Indexed history API adapter tests
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Api.HistorySpec (spec) where

import Data.Aeson (decode, encode)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
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
    , TxSummaryOutput (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldReturn
    )

import Amaru.Treasury.Api.History
    ( outputFromSummary
    , outputScopeRoles
    , queryScopeHistoryResponse
    )
import Amaru.Treasury.Api.Types
    ( ScopeHistoryEntry (..)
    , ScopeHistoryResponse (..)
    , TxDetailOutput (..)
    )
import Amaru.Treasury.Cli.History (scopeHistoryScope)
import Amaru.Treasury.Indexer.Decoder (treasuryTenantId)
import Amaru.Treasury.Metadata (TreasuryMetadata, readMetadataFile)
import Amaru.Treasury.Report.Accounting (ValueSummary (..))
import Amaru.Treasury.Scope (ScopeId (..))

spec :: Spec
spec =
    describe "Amaru.Treasury.Api.History" $ do
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

        describe "tx-detail output resolution" $ do
            it "maps a known treasury address to its scope and role" $ do
                md <- loadMetadata
                Map.lookup
                    coreTreasuryAddress
                    (outputScopeRoles (Just md))
                    `shouldBe` Just ("core_development", "treasury")

            it "leaves external addresses unresolved" $ do
                md <- loadMetadata
                Map.lookup
                    externalAddress
                    (outputScopeRoles (Just md))
                    `shouldBe` Nothing

            it "labels a treasury output with scope, role, value" $ do
                md <- loadMetadata
                let roles = outputScopeRoles (Just md)
                    out =
                        outputFromSummary
                            roles
                            Nothing
                            0
                            (mkOutput coreTreasuryAddress 35000000)
                tdoAddress out `shouldBe` coreTreasuryAddress
                tdoScope out `shouldBe` Just "core_development"
                tdoRole out `shouldBe` Just "treasury"
                tdoValue out `shouldBe` mkValue 35000000

            it "leaves a non-treasury output unresolved" $ do
                let out =
                        outputFromSummary
                            Map.empty
                            Nothing
                            1
                            (mkOutput externalAddress 5000000)
                tdoScope out `shouldBe` Nothing
                tdoRole out `shouldBe` Nothing
                tdoValue out `shouldBe` mkValue 5000000

            it "carries scope, role, value through output JSON" $ do
                md <- loadMetadata
                let out =
                        outputFromSummary
                            (outputScopeRoles (Just md))
                            Nothing
                            0
                            (mkOutput coreTreasuryAddress 35000000)
                decode (encode out) `shouldBe` Just out

loadMetadata :: IO TreasuryMetadata
loadMetadata = readMetadataFile "test/fixtures/metadata.json"

-- | Mainnet @core_development@ treasury address from the fixture.
coreTreasuryAddress :: Text
coreTreasuryAddress =
    "addr1x90mk0jjjhppr36ethwj8kewpgyrxyc7q6qucl4gqru96dzlh\
    \vl999wzz8r4jhway0djuzsgxvf3up5pe3l2sq8ct56qtjz6ah"

-- | An address outside the treasury (a disburse beneficiary).
externalAddress :: Text
externalAddress =
    "addr1qy8achievementbeneficiaryexampleexternaladdr0000000"

-- | A pure-ADA 'ValueSummary' carrying the given lovelace.
mkValue :: Integer -> ValueSummary
mkValue lovelace =
    ValueSummary{vsLovelace = lovelace, vsAssets = Map.empty}

{- | A treasury output whose @value@ bytes are the structured
'ValueSummary' JSON the indexer decoder stores.
-}
mkOutput :: Text -> Integer -> TxSummaryOutput
mkOutput address lovelace =
    TxSummaryOutput
        { tsoAddress = TE.encodeUtf8 address
        , tsoValue = BSL.toStrict (encode (mkValue lovelace))
        , tsoDatum = Nothing
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
