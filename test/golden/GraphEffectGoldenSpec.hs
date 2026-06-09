{- |
Module      : GraphEffectGoldenSpec
Description : Golden for the unsigned-tx graph-effect payload (#345 S2)
License     : Apache-2.0

Builds a tx from a frozen 'ChainContext' fixture, projects it onto
the RDF lattice via 'Amaru.Treasury.Api.GraphEffect.graphEffect' with
the fixture's own UTxO set as the (hermetic) input resolver and the
mainnet treasury metadata, and byte-diffs the resolved spend→produce
JSON against a golden.

Two cases exercise the same scope-agnostic engine:

  * @disburse@ — the frozen @test/fixtures/disburse/ada@ context
    (scope @core_development@): a treasury spend → leftover + beneficiary.
    Stands in for the contingency disburse (no frozen contingency
    fixture exists; the resolution code path is identical).
  * @swap@ — the frozen @test/fixtures/swap@ context (scope
    @network_compliance@).

Set @UPDATE_GOLDENS=1@ to regenerate the @*.graph.json@ goldens.
-}
module GraphEffectGoldenSpec (spec) where

import Control.Monad (when)
import Data.Aeson (decode)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import System.Environment (lookupEnv)
import Test.Hspec (Spec, describe, it, shouldBe)

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.TxIn (TxIn)

import Amaru.Treasury.Api.GraphEffect (graphEffect)
import Amaru.Treasury.Build
    ( BuildResult (..)
    , runFromIntent
    )
import Amaru.Treasury.ChainContext.Fixture
    ( SwapFixture (..)
    , readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.Indexer.Decoder (decodeConwayTx)
import Amaru.Treasury.IntentJSON (decodeTreasuryIntentFile)
import Amaru.Treasury.Metadata (TreasuryMetadata, readMetadataFile)

spec :: Spec
spec =
    describe "Amaru.Treasury.Api.GraphEffect graph-effect golden" $ do
        it
            "projects the ada disburse spend→produce (scope core_development)"
            $ goldenCase
                "test/fixtures/disburse/ada"
                "test/fixtures/graph-effect/ada-disburse.graph.json"
        it
            "projects the swap spend→produce (scope network_compliance)"
            $ goldenCase
                "test/fixtures/swap"
                "test/fixtures/graph-effect/swap.graph.json"

{- | Build the fixture's tx, project it via 'graphEffect' with the
fixture UTxO set as the resolver, and assert the pretty JSON against
the golden at @goldenPath@.
-}
goldenCase :: FilePath -> FilePath -> IO ()
goldenCase fixtureDir goldenPath = do
    some <-
        decodeTreasuryIntentFile (fixtureDir <> "/intent.json")
            >>= either (error . ("intent JSON: " <>)) pure
    fixture <- readSwapFixture fixtureDir
    tbr <- runFromIntent (toFrozenContext fixture) some
    tx <-
        maybe
            (error "graph-effect golden: tx CBOR did not decode")
            pure
            (decodeConwayTx (BSL.toStrict (brCborBytes tbr)))
    md <- loadMetadata
    effect <- graphEffect (Just md) (fixtureResolver fixture) tx
    let actual = BSL.toStrict (encodePretty effect)
    update <- lookupEnv "UPDATE_GOLDENS"
    when (update == Just "1") (BS.writeFile goldenPath actual)
    expected <- BS.readFile goldenPath
    actual `shouldBe` expected
    -- The graph-effect JSON round-trips through its instances.
    decode (encodePretty effect) `shouldBe` Just effect

{- | Hermetic resolver: serve the produced TxOut for any input outref
the fixture's frozen UTxO set holds; omit the rest.
-}
fixtureResolver
    :: SwapFixture
    -> Set TxIn
    -> IO (Map TxIn (TxOut ConwayEra))
fixtureResolver fixture txIns =
    pure (Map.restrictKeys (sfUtxos fixture) txIns)

loadMetadata :: IO TreasuryMetadata
loadMetadata = readMetadataFile "test/fixtures/metadata.json"
