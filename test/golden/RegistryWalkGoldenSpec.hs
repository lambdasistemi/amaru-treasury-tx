{- |
Module      : RegistryWalkGoldenSpec
Description : Byte-parity golden for the registry-walk wizard JSON
License     : Apache-2.0

Runs 'verifyWithAnchors' against the checked-in metadata +
anchors fixtures, encodes the resulting 'VerifiedRegistry' as
the JSON snippet that downstream tx generation consumes, and
byte-diffs the output against
@test/fixtures/registry-walk/expected.json@.

Refresh the fixture by re-encoding when the projection changes
intentionally.
-}
module RegistryWalkGoldenSpec (spec) where

import Data.Aeson (eitherDecodeFileStrict)
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (Spaces)
    , NumberFormat (Generic)
    , encodePretty'
    )
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Set qualified as Set
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Registry.Metadata
    ( UpstreamMetadata
    , readUpstreamMetadataFile
    )
import Amaru.Treasury.Registry.Verify
    ( RegistryAnchors
    , verifyWithAnchors
    )
import Amaru.Treasury.Scope (ScopeId (CoreDevelopment))

fixtureDir :: FilePath
fixtureDir = "test/fixtures/registry-walk"

spec :: Spec
spec =
    describe "registry-walk golden (verifyWithAnchors)" $ do
        it "encodes VerifiedRegistry to expected.json byte-for-byte" $ do
            metadata <- loadMetadata
            anchors <- loadAnchors
            verified <-
                case verifyWithAnchors
                    metadata
                    anchors
                    (Set.singleton CoreDevelopment) of
                    Right v -> pure v
                    Left err ->
                        expectationFailure
                            ("verifyWithAnchors: " <> show err)
                            *> error "unreachable"
            let actual =
                    BSL.toStrict (encodePretty' goldenConfig verified)
            expected <- BS.readFile (fixtureDir <> "/expected.json")
            actual `shouldBe` expected

goldenConfig :: Config
goldenConfig =
    Config
        { confIndent = Spaces 2
        , confCompare = compare
        , confNumFormat = Generic
        , confTrailingNewline = True
        }

loadMetadata :: IO UpstreamMetadata
loadMetadata = do
    result <-
        readUpstreamMetadataFile
            (fixtureDir <> "/metadata.json")
    case result of
        Right m -> pure m
        Left err ->
            expectationFailure
                ("metadata fixture failed: " <> show err)
                *> error "unreachable"

loadAnchors :: IO RegistryAnchors
loadAnchors = do
    result <- eitherDecodeFileStrict (fixtureDir <> "/anchors.json")
    case result of
        Right a -> pure a
        Left err ->
            expectationFailure ("anchors fixture failed: " <> err)
                *> error "unreachable"
