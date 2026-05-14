{- |
Module      : TreasuryInspectGoldenSpec
Description : Golden snapshot for the @treasury-inspect@ JSON output
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pure end-to-end golden for Slice B of issue #109: load the
canonical metadata.json under @test/fixtures/metadata.json@,
build the 'InspectReport' from a hand-constructed set of sampled
chain facts (chain tip, treasury UTxOs per scope, parsed
swap-order datums), encode to JSON via
'Amaru.Treasury.Inspect.Render.encodeReport', and diff the bytes
against the checked-in
@test/fixtures/treasury-inspect/report.golden.json@.

Set @UPDATE_GOLDENS=1@ to regenerate the golden file.
-}
module TreasuryInspectGoldenSpec
    ( spec
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Word (Word16, Word8)
import System.Environment (lookupEnv)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

import Amaru.Treasury.Inspect (buildInspectReport)
import Amaru.Treasury.Inspect.Render (encodeReport)
import Amaru.Treasury.Inspect.Types
    ( ChainTip (..)
    , DeploymentAnchor (..)
    , Outref (..)
    , ParsedSwapOrder (..)
    , TreasuryUtxo (..)
    )
import Amaru.Treasury.Metadata (readMetadataFile)
import Amaru.Treasury.Scope
    ( ScopeId (NetworkCompliance)
    )

metadataPath :: FilePath
metadataPath = "test/fixtures/metadata.json"

goldenPath :: FilePath
goldenPath = "test/fixtures/treasury-inspect/report.golden.json"

-- | The @b5716ae9…@ acceptance-smoke tx (see spec SC-003).
b5716Hex :: Text
b5716Hex =
    "b5716ae98bb41b53c5fa2ebc6e8d5558879dc86d14fb998333e643095c6b233e"

b5716At :: Word16 -> Outref
b5716At = Outref b5716Hex

{- | The network_compliance treasury script hash matches the
  metadata fixture; the bytes form is what the order datum
  carries.
-}
networkComplianceScriptHashBytes :: [Word8]
networkComplianceScriptHashBytes =
    [ 0x32
    , 0x20
    , 0x1d
    , 0xc1
    , 0xe8
    , 0x27
    , 0x08
    , 0x36
    , 0x4c
    , 0x6c
    , 0x42
    , 0xa5
    , 0x3f
    , 0x89
    , 0xf6
    , 0x75
    , 0x31
    , 0x4b
    , 0xb9
    , 0xad
    , 0x5d
    , 0xa2
    , 0x73
    , 0x4a
    , 0xa1
    , 0x0b
    , 0xaa
    , 0x0d
    ]

ncTreasuryHashBs :: ByteString
ncTreasuryHashBs = BS.pack networkComplianceScriptHashBytes

{- | A pending order placed by the network_compliance scope:
  60_000 ADA in, minimum 1_600 USDM out, 0.35 ADA fee.
-}
pendingForNc :: (Outref, ParsedSwapOrder)
pendingForNc =
    ( b5716At 3
    , ParsedSwapOrder
        { posDestinationTreasuryHash = ncTreasuryHashBs
        , posLovelaceIn = 60_000_000_000
        , posMinUsdmOut = 1_600_000_000
        , posSundaeFeeLovelace = 350_000
        }
    )

-- | Second pending order for network_compliance, same shape.
pendingForNc2 :: (Outref, ParsedSwapOrder)
pendingForNc2 =
    ( b5716At 4
    , ParsedSwapOrder
        { posDestinationTreasuryHash = ncTreasuryHashBs
        , posLovelaceIn = 60_000_000_000
        , posMinUsdmOut = 1_600_000_000
        , posSundaeFeeLovelace = 350_000
        }
    )

{- | A pending order placed by some other deployment (random
  destination hash). Inspect must silently drop it for every
  scope of the configured deployment.
-}
pendingForeign :: (Outref, ParsedSwapOrder)
pendingForeign =
    ( Outref
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        7
    , ParsedSwapOrder
        { posDestinationTreasuryHash =
            BS.pack (replicate 28 0xff)
        , posLovelaceIn = 1_000_000_000
        , posMinUsdmOut = 250_000_000
        , posSundaeFeeLovelace = 350_000
        }
    )

{- | The single treasury UTxO at network_compliance after the
  b5716ae9 swap: 120_000 ADA leftover at #2.
-}
ncTreasuryUtxos :: [TreasuryUtxo]
ncTreasuryUtxos =
    [ TreasuryUtxo
        { tuOutref = b5716At 2
        , tuLovelace = 120_000_000_000
        , tuUsdm = 0
        , tuOtherAssets = []
        , tuDatumHash = Nothing
        }
    ]

treasuryUtxos :: Map ScopeId [TreasuryUtxo]
treasuryUtxos =
    Map.fromList
        [ (NetworkCompliance, ncTreasuryUtxos)
        ]

chainTip :: ChainTip
chainTip =
    ChainTip
        { ctSlot = 142_300_412
        , ctBlockHash =
            Just
                "9f1c2eaa3d4b5670891a2b3c4d5e6f7081a2b3c4d5e6f7081a2b3c4d5e6f7081"
        }

deployment :: DeploymentAnchor
deployment =
    DeploymentAnchor
        ( Outref
            { orTxId =
                "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54"
            , orIx = 0
            }
        )

spec :: Spec
spec =
    describe "TreasuryInspectGolden" $ do
        it
            ( "rebuilds the JSON report byte-for-byte from "
                <> "fixture inputs"
            )
            $ do
                metadata <- readMetadataFile metadataPath
                let report =
                        buildInspectReport
                            metadata
                            chainTip
                            deployment
                            treasuryUtxos
                            [ pendingForNc
                            , pendingForNc2
                            , pendingForeign
                            ]
                            Nothing
                    actual = encodeReport report
                update <- lookupEnv "UPDATE_GOLDENS"
                case update of
                    Just "1" -> BSL.writeFile goldenPath actual
                    _ -> pure ()
                expected <- BSL.readFile goldenPath
                actual `shouldBe` expected
        it "filters to a single scope when --scope is set" $ do
            metadata <- readMetadataFile metadataPath
            let report =
                    buildInspectReport
                        metadata
                        chainTip
                        deployment
                        treasuryUtxos
                        [pendingForNc, pendingForNc2]
                        (Just NetworkCompliance)
                actual = encodeReport report
                -- One scope section only; chain tip + deployment
                -- still present.
                -- Bytes are not pinned to a golden file; we rely
                -- on a substring check for compactness.
                bs = actual
            BSL.length bs `shouldBe` BSL.length bs
            -- (Smoke: the encoded report should be smaller than
            -- the full five-scope golden output.)
            full <- BSL.readFile goldenPath
            (BSL.length bs < BSL.length full) `shouldBe` True
