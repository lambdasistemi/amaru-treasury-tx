{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.EnvelopeSpec
Description : CLI parser tests for cardano-cli envelope filters
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.EnvelopeSpec (spec) where

import Data.Text qualified as T
import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    )
import System.Exit (ExitCode (..))
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Cli
    ( Cmd (..)
    , opts
    )
import Amaru.Treasury.Cli.DisburseWizard
    ( EmergencyTopUpOpts (..)
    )
import Amaru.Treasury.Cli.Envelope
    ( DeEnvelopeFilterResult (..)
    , runDeEnvelopeFilter
    , runEnvelopeFilter
    )
import Amaru.Treasury.Scope
    ( ScopeId (NetworkCompliance)
    )
import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind (..)
    )

spec :: Spec
spec =
    describe "cardano-cli envelope CLI" $ do
        it "parses envelope-tx as a raw-hex wrapper" $
            parseCmd ["envelope-tx"] `shouldBe` Right "envelope-tx"

        it "parses envelope-witness as a raw-witness wrapper" $
            parseCmd ["envelope-witness"]
                `shouldBe` Right "envelope-witness"

        it "parses envelope-signed-tx as a signed-tx wrapper" $
            parseCmd ["envelope-signed-tx"]
                `shouldBe` Right "envelope-signed-tx"

        it "parses de-envelope as a raw-hex extractor" $
            parseCmd ["de-envelope"] `shouldBe` Right "de-envelope"

        it "leaves attach-witness on its raw-hex option shape" $
            parseCmd ["attach-witness", "--witness", "deadbeef"]
                `shouldBe` Right "attach-witness"

        it "leaves submit on its raw-hex option shape" $
            parseCmd ["submit", "--tx", "signed.cbor"]
                `shouldBe` Right "submit"

        it "leaves tx-build on its existing option shape" $
            parseCmd ["tx-build", "--out", "-"]
                `shouldBe` Right "tx-build"

        it "parses generic disburse-wizard for owned scopes only" $
            parseCmd disburseWizardArgs `shouldBe` Right "disburse-wizard"

        it "rejects contingency on generic disburse-wizard" $
            parseCmd
                ( replaceArg
                    "network_compliance"
                    "contingency"
                    disburseWizardArgs
                )
                `shouldBe` Left "parse failure"

        it "parses emergency-top-up-wizard as a contingency ADA top-up" $
            parseCmd emergencyTopUpArgs
                `shouldBe` Right "emergency-top-up-wizard"

        it "parses emergency-top-up-wizard ADA into lovelace" $
            parseEmergencyTopUp emergencyTopUpArgs
                `shouldBe` Right (NetworkCompliance, 200000500000)

        it "rejects contingency as an emergency-top-up-wizard destination" $
            parseCmd
                ( replaceArg
                    "network_compliance"
                    "contingency"
                    emergencyTopUpArgs
                )
                `shouldBe` Left "parse failure"

        it "filters stdin bytes into an envelope" $
            runEnvelopeFilter Tx "deadbeef\n"
                `shouldBe` "{\n    \"type\": \"Tx ConwayEra\",\n    \"description\": \"Ledger Cddl Format\",\n    \"cborHex\": \"deadbeef\"\n}\n"

        it "de-envelope filters envelope JSON to raw hex stdout" $
            runDeEnvelopeFilter
                "{\"type\":\"Tx ConwayEra\",\"cborHex\":\"deadbeef\"}"
                `shouldBe` DeEnvelopeFilterResult
                    { defrExitCode = ExitSuccess
                    , defrStdout = "deadbeef\n"
                    , defrStderr = ""
                    }

        it "de-envelope reports failure with empty stdout and exit code 1" $ do
            let result = runDeEnvelopeFilter "deadbeef"
            defrExitCode result `shouldBe` ExitFailure 1
            defrStdout result `shouldBe` ""
            defrStderr result
                `shouldSatisfy` T.isPrefixOf "de-envelope: "

        it "de-envelope stderr includes stale era diagnostics" $ do
            let result =
                    runDeEnvelopeFilter
                        "{\"type\":\"Tx BabbageEra\",\"cborHex\":\"deadbeef\"}"
            defrExitCode result `shouldBe` ExitFailure 1
            defrStdout result `shouldBe` ""
            defrStderr result
                `shouldSatisfy` T.isInfixOf "BabbageEra"

parseCmd :: [String] -> Either String String
parseCmd args =
    case execParserPure defaultPrefs opts args of
        Success (_, cmd) -> Right (cmdTag cmd)
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

parseEmergencyTopUp :: [String] -> Either String (ScopeId, Integer)
parseEmergencyTopUp args =
    case execParserPure defaultPrefs opts args of
        Success (_, CmdEmergencyTopUp etu) ->
            Right
                ( etuOptsDestinationScope etu
                , etuOptsAdaLovelace etu
                )
        Success{} -> Left "wrong command"
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

cmdTag :: Cmd -> String
cmdTag = \case
    CmdEnvelopeTx -> "envelope-tx"
    CmdEnvelopeWitness -> "envelope-witness"
    CmdEnvelopeSignedTx -> "envelope-signed-tx"
    CmdDeEnvelope -> "de-envelope"
    CmdAttachWitness{} -> "attach-witness"
    CmdSubmit{} -> "submit"
    CmdTxBuild{} -> "tx-build"
    CmdSwapWizard{} -> "swap-wizard"
    CmdSwapQuote{} -> "swap-quote"
    CmdDisburseWizard{} -> "disburse-wizard"
    CmdEmergencyTopUp{} -> "emergency-top-up-wizard"
    CmdWithdrawWizard{} -> "withdraw-wizard"
    CmdReportRender{} -> "report-render"
    CmdTreasuryInspect{} -> "treasury-inspect"

emergencyTopUpArgs :: [String]
emergencyTopUpArgs =
    [ "emergency-top-up-wizard"
    , "--wallet-addr"
    , "addr1qx9aqvsf6gne2640jec828s25gzhk5wp2day8u24kf8mrs2v0zyuvk80fay35dx008p45ts0u6cdrv9g2maetq8jm8psznjcrz"
    , "--metadata"
    , "metadata-mainnet.json"
    , "--destination-scope"
    , "network_compliance"
    , "--ada"
    , "200000.5"
    , "--description"
    , "Top up Network Compliance"
    , "--justification"
    , "Emergency reallocation"
    ]

disburseWizardArgs :: [String]
disburseWizardArgs =
    [ "disburse-wizard"
    , "--wallet-addr"
    , "addr1qx9aqvsf6gne2640jec828s25gzhk5wp2day8u24kf8mrs2v0zyuvk80fay35dx008p45ts0u6cdrv9g2maetq8jm8psznjcrz"
    , "--metadata"
    , "metadata-mainnet.json"
    , "--scope"
    , "network_compliance"
    , "--amount"
    , "1"
    , "--beneficiary-addr"
    , "addr1qx9aqvsf6gne2640jec828s25gzhk5wp2day8u24kf8mrs2v0zyuvk80fay35dx008p45ts0u6cdrv9g2maetq8jm8psznjcrz"
    , "--description"
    , "Vendor payment"
    , "--justification"
    , "Approved invoice"
    , "--destination-label"
    , "Vendor"
    ]

replaceArg :: String -> String -> [String] -> [String]
replaceArg old new =
    fmap (\arg -> if arg == old then new else arg)
