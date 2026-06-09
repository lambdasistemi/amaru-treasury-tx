{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.History.SparqlSpec
Description : Named RDF query and SHACL history tests
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.History.SparqlSpec (spec) where

import Control.Exception (bracket_)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.Foldable (for_)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import System.Directory
    ( Permissions (executable)
    , getPermissions
    , setPermissions
    )
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)

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
    ( HistoryFilter (..)
    , HistoryQueryName (..)
    , HistoryQueryResult (..)
    , HistoryShaclResult (..)
    , HistoryShapeName (..)
    , buildHistoryLattice
    , emptyHistoryFilter
    , filterHistoryEntries
    , historyShaclResultLines
    , parseHistoryQueryName
    , parseHistoryShapeName
    , renderHistoryQueryName
    , renderHistoryShapeName
    , runNamedHistoryQuery
    , runNamedHistoryShacl
    )
import Amaru.Treasury.Metadata
    ( TreasuryMetadata
    , readMetadataFile
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
                    Nothing
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

        describe "filterHistoryEntries" $
            it "applies non-asset filters without RDF executables" $ do
                let disburseOutbound =
                        mkEntry 3 "0102" "disburse" "outbound"
                    reorganizeInbound =
                        mkEntry 5 "0203" "reorganize" "inbound"
                    disburseInbound =
                        mkEntry 7 "0304" "disburse" "inbound"
                    entries =
                        [ disburseOutbound
                        , reorganizeInbound
                        , disburseInbound
                        ]
                    cases =
                        [
                            ( emptyHistoryFilter
                            , entries
                            )
                        ,
                            ( emptyHistoryFilter{hfRole = Just "disburse"}
                            , [disburseOutbound, disburseInbound]
                            )
                        ,
                            ( emptyHistoryFilter{hfDirection = Just "inbound"}
                            , [reorganizeInbound, disburseInbound]
                            )
                        ,
                            ( emptyHistoryFilter
                                { hfSince = Just 4
                                , hfUntil = Just 6
                                }
                            , [reorganizeInbound]
                            )
                        ,
                            ( emptyHistoryFilter{hfLimit = Just 2}
                            , take 2 entries
                            )
                        ]
                withSystemTempDirectory "atx-empty-path" $ \emptyPath ->
                    withPath emptyPath $
                        for_ cases $ \(flt, expected) -> do
                            result <- filterHistoryEntries flt entries
                            result `shouldBe` Right expected

        it "runs the metadata SHACL shape through Jena shacl" $ do
            result <-
                runNamedHistoryShacl
                    HistoryEntryShape
                    Nothing
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

        it "skips a transaction body when cq-rdf exits non-zero" $ do
            withSystemTempDirectory "atx-failing-cq-rdf" $ \binDir -> do
                let cqRdf = binDir </> "cq-rdf"
                BS.writeFile
                    cqRdf
                    "#!/bin/sh\necho bad treasury tx >&2\nexit 23\n"
                perms <- getPermissions cqRdf
                setPermissions cqRdf perms{executable = True}
                withPathPrefix binDir $ do
                    result <-
                        runNamedHistoryQuery
                            TxCountQuery
                            Nothing
                            [ mkEntryWithPayload
                                3
                                "0102"
                                "disburse"
                                "outbound"
                                "not-cbor"
                            ]
                    result
                        `shouldBe` Right
                            HistoryQueryResult
                                { hqrQuery = TxCountQuery
                                , hqrColumns = ["transactions"]
                                , hqrRows = [["0"]]
                                }

        describe "address resolution" $ do
            it "parses and renders the resolver query name" $ do
                parseHistoryQueryName "address-resolution"
                    `shouldBe` Right AddressResolutionQuery
                renderHistoryQueryName AddressResolutionQuery
                    `shouldBe` "address-resolution"

            it "emits a treasury address→entity triple from metadata" $ do
                md <- loadMetadata
                lattice <- buildHistoryLattice False (Just md) []
                case lattice of
                    Right ttl -> do
                        let turtle = TE.decodeUtf8 ttl
                        for_
                            [ "atx:TreasuryEntity"
                            , "atx:address " <> quoted coreTreasuryAddress
                            , "atx:scope \"core_development\""
                            , "atx:role \"treasury\""
                            , "atx:label \"core_development treasury\""
                            ]
                            $ \needle ->
                                (needle, needle `T.isInfixOf` turtle)
                                    `shouldBe` (needle, True)
                    Left err ->
                        expectationFailure
                            ("expected lattice success, got " <> show err)

            it "resolves a treasury address to scope/role/label" $ do
                md <- loadMetadata
                result <-
                    runNamedHistoryQuery
                        AddressResolutionQuery
                        (Just md)
                        []
                case result of
                    Right table -> do
                        hqrColumns table
                            `shouldBe` ["address", "scope", "role", "label"]
                        case find
                            ((== coreTreasuryAddress) . headOr)
                            (hqrRows table) of
                            Just row ->
                                row
                                    `shouldBe` [ coreTreasuryAddress
                                               , "core_development"
                                               , "treasury"
                                               , "core_development treasury"
                                               ]
                            Nothing ->
                                expectationFailure
                                    ( "no resolver row for treasury "
                                        <> "address; rows: "
                                        <> show (hqrRows table)
                                    )
                    Left err ->
                        expectationFailure
                            ("expected resolver success, got " <> show err)

loadMetadata :: IO TreasuryMetadata
loadMetadata = readMetadataFile "test/fixtures/metadata.json"

-- | Mainnet @core_development@ treasury address from the fixture.
coreTreasuryAddress :: Text
coreTreasuryAddress =
    "addr1x90mk0jjjhppr36ethwj8kewpgyrxyc7q6qucl4gqru96dzlh\
    \vl999wzz8r4jhway0djuzsgxvf3up5pe3l2sq8ct56qtjz6ah"

quoted :: Text -> Text
quoted t = "\"" <> t <> "\""

headOr :: [Text] -> Text
headOr [] = ""
headOr (x : _) = x

mkEntry
    :: Word64
    -> ByteString
    -> ByteString
    -> ByteString
    -> TxSummaryEntry
mkEntry slot txid role direction =
    mkEntryWithPayload slot txid role direction BS.empty

mkEntryWithPayload
    :: Word64
    -> ByteString
    -> ByteString
    -> ByteString
    -> ByteString
    -> TxSummaryEntry
mkEntryWithPayload slot txid role direction payload =
    TxSummaryEntry
        { tseKey =
            TxSummaryKey
                { tskTenant = TenantId "treasury"
                , tskScope = HistoryScope "core_development"
                , tskSlot = SlotNo slot
                , tskTxId = TxId (hexBytes txid)
                , tskRole = TxRole role
                }
        , tsePayload = payload
        , tseDirection = TxDirection direction
        }

hexBytes :: ByteString -> ByteString
hexBytes "0102" = BS.pack [0x01, 0x02]
hexBytes other = other

withPath :: FilePath -> IO a -> IO a
withPath path action = do
    original <- lookupEnv "PATH"
    bracket_
        (setEnv "PATH" path)
        (restorePath original)
        action

restorePath :: Maybe String -> IO ()
restorePath Nothing = unsetEnv "PATH"
restorePath (Just path) = setEnv "PATH" path

withPathPrefix :: FilePath -> IO a -> IO a
withPathPrefix path action = do
    original <- lookupEnv "PATH"
    bracket_
        (setEnv "PATH" (path <> maybe "" (":" <>) original))
        (restorePath original)
        action
