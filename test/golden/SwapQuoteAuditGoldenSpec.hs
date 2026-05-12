{- |
Module      : SwapQuoteAuditGoldenSpec
Description : Golden test scaffold for quote-derived swap audit output
License     : Apache-2.0
-}
module SwapQuoteAuditGoldenSpec (spec) where

import Data.ByteString.Lazy qualified as BSL
import Data.Ratio ((%))
import Test.Hspec (Spec, describe, it, shouldBe)

import Amaru.Treasury.Tx.SwapQuote
    ( AffordabilitySummary (..)
    , DerivedSwapParameters (..)
    , QuoteObservation (..)
    , QuotePair (..)
    , QuoteProvenance (..)
    , SlippageBps (..)
    , SwapQuoteAudit (..)
    , SwapQuoteAuditRequest (..)
    , SwapQuoteOutputs (..)
    , SwapQuoteRequestChunk (..)
    , SwapQuoteStatus (..)
    , encodeSwapQuoteAudit
    )

spec :: Spec
spec =
    describe "swap-quote audit JSON" $ do
        it "matches the built params.json golden" $ do
            let actual = normalize (encodeSwapQuoteAudit builtAudit)
            expected <-
                normalize
                    <$> BSL.readFile
                        "test/fixtures/swap-quote/params.built.expected.json"
            actual `shouldBe` expected

        it "matches the affordability-failed params.json golden" $ do
            let actual =
                    normalize (encodeSwapQuoteAudit affordabilityFailedAudit)
            expected <-
                normalize
                    <$> BSL.readFile
                        "test/fixtures/swap-quote/params.affordability-failed.expected.json"
            actual `shouldBe` expected

normalize :: BSL.ByteString -> BSL.ByteString
normalize bytes =
    if BSL.null bytes || BSL.last bytes == 10
        then bytes
        else bytes <> "\n"

builtAudit :: SwapQuoteAudit
builtAudit =
    SwapQuoteAudit
        { sqaStatus = SwapQuoteBuilt
        , sqaObservedAt = "2026-05-09T10:00:00Z"
        , sqaDerived = sampleDerivedParameters
        , sqaRequest = sampleRequest
        , sqaAffordability =
            AffordabilitySummary
                { asDerived = sampleDerivedParameters
                , asChunkCount = 34
                , asExtraPerChunkLovelace = 3_280_000
                , asRequiredLovelace = 124_462_256_421
                , asAvailableLovelace = 1_450_000_000_000
                , asShortfallLovelace = 0
                }
        , sqaOutputs =
            SwapQuoteOutputs
                { sqoIntentJson = "swap-run-2026-05-09/intent.json"
                , sqoUnsignedCborHex =
                    Just "swap-run-2026-05-09/swap.cbor.hex"
                , sqoWizardLog = "swap-run-2026-05-09/wizard.log"
                , sqoBuildLog = Just "swap-run-2026-05-09/build.log"
                }
        }

affordabilityFailedAudit :: SwapQuoteAudit
affordabilityFailedAudit =
    builtAudit
        { sqaStatus = SwapQuoteAffordabilityFailed
        , sqaAffordability =
            AffordabilitySummary
                { asDerived = sampleDerivedParameters
                , asChunkCount = 34
                , asExtraPerChunkLovelace = 3_280_000
                , asRequiredLovelace = 124_462_256_421
                , asAvailableLovelace = 124_462_256_420
                , asShortfallLovelace = 1
                }
        , sqaOutputs =
            SwapQuoteOutputs
                { sqoIntentJson = "swap-run-2026-05-09/intent.json"
                , sqoUnsignedCborHex = Nothing
                , sqoWizardLog = "swap-run-2026-05-09/wizard.log"
                , sqoBuildLog = Nothing
                }
        }

sampleDerivedParameters :: DerivedSwapParameters
sampleDerivedParameters =
    DerivedSwapParameters
        { dspQuote =
            QuoteObservation
                { qoPair = AdaUsd
                , qoQuote = 8123 % 10_000
                , qoProvenance = OperatorOverride
                }
        , dspSlippageBps = SlippageBps 100
        , dspRateNumerator = 804_177
        , dspRateDenominator = 1_000_000
        , dspAmountLovelace = 124_350_736_421
        , dspChunkSizeLovelace = 3_768_204_133
        }

sampleRequest :: SwapQuoteAuditRequest
sampleRequest =
    SwapQuoteAuditRequest
        { sqarNetwork = "mainnet"
        , sqarScope = "network_compliance"
        , sqarRequestedUsdm = 100_000
        , sqarChunk = SplitInto 33
        , sqarValidityHours = Just 28
        , sqarExtraSigners = ["core_development"]
        }
