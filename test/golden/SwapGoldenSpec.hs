{- |
Module      : SwapGoldenSpec
Description : Offline byte-parity golden for the swap CBOR
License     : Apache-2.0

Loads the frozen swap fixture under
@test/fixtures/swap/@, parses it as a unified
'SomeTreasuryIntent', builds the tx via 'runFromIntent'
against the resulting frozen 'ChainContext', and
byte-diffs the CBOR against the checked-in target
tx body.

After T006 (issue #68), the post-fix tx body no longer
matches the original upstream bash/cardano-cli oracle
captured in @test/fixtures/swap/provenance.md@. Until
the bash recipe is updated to fund the per-chunk
overhead from the treasury (FR-008 / T008), the file
@target.tx.json@ holds the **Haskell-generated**
post-fix CBOR, not an independent bash oracle.
@expected.cbor@ must match @target.tx.json@'s
@cborHex@ (the byte-identity gate within the Haskell
side). The "Haskell ≡ live bash recipe" invariant is
restored once T008 regenerates the bash output to
this same target.

Set @UPDATE_GOLDENS=1@ to regenerate both files from
the current Haskell builder output.
-}
module SwapGoldenSpec (spec) where

import Data.Aeson
    ( FromJSON (..)
    , eitherDecodeStrict'
    , withObject
    , (.:)
    )
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import System.Environment (lookupEnv)
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.IntentJSON
    ( SomeTreasuryIntent
    , decodeTreasuryIntentFile
    )
import Amaru.Treasury.Report
    ( MetadataSummary (..)
    , ProducedOutput (..)
    , ProducedOutputRole (..)
    , ReportContext (..)
    , SignerRequirement (..)
    , SignerSource (..)
    , TransactionReport (..)
    , TxBuildOutput (..)
    , TxBuildOutputResult (..)
    , TxBuildSuccess (..)
    , TxCborHex
    , ValidationFacts (..)
    , ValidityInterval (..)
    , WalletAccounting (..)
    , buildTransactionReport
    , encodeBuildOutput
    , txCborHexFromBytes
    )
import Amaru.Treasury.TreasuryBuild
    ( TreasuryBuildResult (..)
    , runFromIntent
    )

fixtureDir :: FilePath
fixtureDir = "test/fixtures/swap"

newtype Target = Target Text

instance FromJSON Target where
    parseJSON =
        withObject "Target" $ \o ->
            Target <$> o .: "cborHex"

spec :: Spec
spec =
    describe "swap golden (frozen ChainContext)" $ do
        it "rebuilds the post-fix target tx body byte-for-byte" $ do
            si <-
                decodeTreasuryIntentFile
                    (fixtureDir <> "/intent.json")
            some <- case si of
                Left e -> error ("intent JSON: " <> e)
                Right v -> pure v
            fixture <- readSwapFixture fixtureDir
            let ctx = toFrozenContext fixture
            tbr <- runFromIntent ctx some
            let actualHex =
                    B16.encode
                        (BSL.toStrict (tbrCborBytes tbr))
            update <- lookupEnv "UPDATE_GOLDENS"
            case update of
                Just "1" -> do
                    -- Capture the current Haskell builder
                    -- output as the post-fix target. After
                    -- T008 the bash recipe under
                    -- pragma-org/amaru-treasury will be
                    -- updated to produce these bytes again,
                    -- restoring "Haskell ≡ bash" parity.
                    BS.writeFile
                        (fixtureDir <> "/expected.cbor")
                        actualHex
                    BS.writeFile
                        (fixtureDir <> "/target.tx.json")
                        ( "{\n    \"type\": \"Witnessed Tx ConwayEra\",\n    \"description\": \"Ledger Cddl Format\",\n    \"cborHex\": \""
                            <> actualHex
                            <> "\"\n}\n"
                        )
                _ -> pure ()
            Target targetText <-
                BS.readFile (fixtureDir <> "/target.tx.json")
                    >>= either
                        (error . ("target JSON: " <>))
                        pure
                        . eitherDecodeStrict'
            let targetHex = Text.encodeUtf8 targetText
            expected <-
                BS.readFile (fixtureDir <> "/expected.cbor")
            expected `shouldBe` targetHex
            actualHex `shouldBe` targetHex
        it "generates a byte-stable report for the swap fixture" $ do
            si <-
                decodeTreasuryIntentFile
                    (fixtureDir <> "/intent.json")
            some <- case si of
                Left e -> error ("intent JSON: " <> e)
                Right v -> pure v
            fixture <- readSwapFixture fixtureDir
            let ctx = toFrozenContext fixture
            first <- runFromIntent ctx some
            second <- runFromIntent ctx some
            let firstReport = swapReport first
                firstReportBytes =
                    encodeBuildOutput (swapBuildOutput some first)
                secondReportBytes =
                    encodeBuildOutput (swapBuildOutput some second)
            waNetSpendLovelace (trWalletAccounting firstReport)
                `shouldBe` vfFeeLovelace (trValidation firstReport)
            trValidation firstReport
                `shouldBe` expectedSwapValidation
            trReferenceInputs firstReport
                `shouldBe` expectedSwapReferenceInputs
            msAuxiliaryDataHash (trMetadata firstReport)
                `shouldBe` Just expectedSwapMetadataHash
            msCip1694LabelPresent (trMetadata firstReport)
                `shouldBe` True
            trSigners firstReport
                `shouldBe` [ SignerRequirement
                                { srKeyHash =
                                    "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
                                , srSource = SourceSelectedScopeOwner
                                , srScope =
                                    Just "network_compliance"
                                }
                           , SignerRequirement
                                { srKeyHash =
                                    "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
                                , srSource = SourceExtraSigner
                                , srScope = Nothing
                                }
                           ]
            assertSwapOutputCoverage firstReport
            update <- lookupEnv "UPDATE_GOLDENS"
            case update of
                Just "1" ->
                    BSL.writeFile
                        (fixtureDir <> "/report.golden.json")
                        firstReportBytes
                _ -> pure ()
            expectedReport <-
                BSL.readFile
                    (fixtureDir <> "/report.golden.json")
            firstReportBytes `shouldBe` secondReportBytes
            firstReportBytes `shouldBe` expectedReport
            tbrCborBytes first `shouldBe` tbrCborBytes second
        it
            "legacy intent without extraTxIns rebuilds byte-identical bytes"
            $ do
                si <-
                    decodeTreasuryIntentFile
                        (fixtureDir <> "/legacy/intent.json")
                some <- case si of
                    Left e ->
                        error ("legacy intent JSON: " <> e)
                    Right v -> pure v
                fixture <- readSwapFixture fixtureDir
                let ctx = toFrozenContext fixture
                tbr <- runFromIntent ctx some
                let actualHex =
                        B16.encode
                            (BSL.toStrict (tbrCborBytes tbr))
                expected <-
                    BS.readFile (fixtureDir <> "/expected.cbor")
                actualHex `shouldBe` expected

swapReport :: TreasuryBuildResult -> TransactionReport
swapReport =
    buildTransactionReport
        ReportContext
            { rcNetwork = "mainnet"
            , rcSocketNetworkMagic = 764_824_073
            , rcSelectedScopeOwner =
                Just
                    ( "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
                    , "network_compliance"
                    )
            , rcExtraSigners =
                [ "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
                ]
            , rcIntentRequiredSigners = []
            }

swapBuildOutput
    :: SomeTreasuryIntent -> TreasuryBuildResult -> TxBuildOutput
swapBuildOutput some result =
    TxBuildOutput
        { txoIntent = some
        , txoResult =
            TxBuildOutputSuccess
                TxBuildSuccess
                    { tbsTxCbor = txCborHex result
                    , tbsReport = swapReport result
                    }
        }

txCborHex :: TreasuryBuildResult -> TxCborHex
txCborHex =
    txCborHexFromBytes . tbrCborBytes

assertSwapOutputCoverage :: TransactionReport -> IO ()
assertSwapOutputCoverage report = do
    let outputs = trOutputs report
        roles = poRole <$> outputs
    length outputs `shouldBe` 35
    poIndex <$> outputs `shouldBe` [0 .. 34]
    take 33 roles `shouldBe` replicate 33 OutputSwapOrder
    drop 33 roles
        `shouldBe` [OutputTreasuryLeftover, OutputWalletChange]

expectedSwapValidation :: ValidationFacts
expectedSwapValidation =
    ValidationFacts
        { vfIntentNetwork = "mainnet"
        , vfSocketNetworkMagic = 764_824_073
        , vfNetworkMatches = True
        , vfFeeLovelace = 1_039_703
        , vfBodySizeBytes = 14_954
        , vfRedeemerCount = 2
        , vfRedeemerFailures = 0
        , vfValidationStatus = "ok"
        , vfValidityInterval =
            ValidityInterval
                { viInvalidBefore = Nothing
                , viInvalidHereafter = Just 186_796_799
                }
        }

expectedSwapReferenceInputs :: [Text]
expectedSwapReferenceInputs =
    [ "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#0"
    , "25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095#2"
    , "810bfcbde85ae72f27d7e8cd154c03c802de15d3fa0dd83a32a4b0fdba330b3c#0"
    , "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#2"
    ]

expectedSwapMetadataHash :: Text
expectedSwapMetadataHash =
    "1163dfe0f06e30a30353b706b988721fb0a6f5168db22402ef6a76b8e677868d"
