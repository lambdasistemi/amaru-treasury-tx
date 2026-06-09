{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.EnvelopeSpec
Description : CLI parser tests for cardano-cli envelope filters
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.EnvelopeSpec (spec) where

import Data.List (isInfixOf)
import Data.Text qualified as T
import Options.Applicative
    ( ParserResult (..)
    , renderFailure
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
    , parseCliArgs
    )
import Amaru.Treasury.Cli.DisburseWizard
    ( DisburseWizardInput (..)
    )
import Amaru.Treasury.Cli.Envelope
    ( DeEnvelopeFilterResult (..)
    , runDeEnvelopeFilter
    , runEnvelopeFilter
    )
import Amaru.Treasury.IntentJSON
    ( RationaleReferenceJSON (..)
    )
import Amaru.Treasury.LedgerParse (txInToText)
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

        it "parses serve --config as the API service surface" $
            parseCmd ["serve", "--config", "service.yaml"]
                `shouldBe` Right "serve"

        it "leaves tx-build on its existing option shape" $
            parseCmd ["tx-build", "--out", "-"]
                `shouldBe` Right "tx-build"

        it "parses generic disburse-wizard for an owned scope" $
            parseCmd disburseWizardArgs `shouldBe` Right "disburse-wizard"

        it "defaults disburse-wizard references to []" $
            parseDisburseReferences disburseWizardArgs
                `shouldBe` Right []

        it "parses one disburse-wizard reference with default @type" $
            parseDisburseReferences
                ( disburseWizardArgs
                    ++ [ "--reference-uri"
                       , "ipfs://one"
                       , "--reference-label"
                       , "Invoice 3508"
                       ]
                )
                `shouldBe` Right
                    [ RationaleReferenceJSON
                        { rjrUri = "ipfs://one"
                        , rjrType = "Other"
                        , rjrLabel = "Invoice 3508"
                        }
                    ]

        it "leaves labelless disburse-wizard references to intent validation" $
            parseDisburseReferences
                ( disburseWizardArgs
                    ++ [ "--reference-uri"
                       , "ipfs://one"
                       ]
                )
                `shouldBe` Right
                    [ RationaleReferenceJSON
                        { rjrUri = "ipfs://one"
                        , rjrType = "Other"
                        , rjrLabel = ""
                        }
                    ]

        it "parses two disburse-wizard reference slots" $
            parseDisburseReferences
                ( disburseWizardArgs
                    ++ [ "--reference-uri"
                       , "ipfs://one"
                       , "--reference-label"
                       , "Invoice 3508"
                       , "--reference-uri"
                       , "ipfs://two"
                       , "--reference-label"
                       , "Signed agreement"
                       ]
                )
                `shouldBe` Right
                    [ RationaleReferenceJSON
                        { rjrUri = "ipfs://one"
                        , rjrType = "Other"
                        , rjrLabel = "Invoice 3508"
                        }
                    , RationaleReferenceJSON
                        { rjrUri = "ipfs://two"
                        , rjrType = "Other"
                        , rjrLabel = "Signed agreement"
                        }
                    ]

        it "rejects stray disburse-wizard --reference-label" $ do
            let result =
                    parseDisburseFailure
                        ( disburseWizardArgs
                            ++ [ "--reference-label"
                               , "Missing URI"
                               ]
                        )
            resultExit result `shouldBe` ExitFailure 2
            resultBody result
                `shouldSatisfy` isInfixOf
                    "--reference-label requires a preceding --reference-uri"

        it "rejects stray disburse-wizard --reference-type" $ do
            let result =
                    parseDisburseFailure
                        ( disburseWizardArgs
                            ++ [ "--reference-type"
                               , "Invoice"
                               ]
                        )
            resultExit result `shouldBe` ExitFailure 2
            resultBody result
                `shouldSatisfy` isInfixOf
                    "--reference-type requires a preceding --reference-uri"

        it "keeps unrelated executable parser failures at exit 1" $ do
            let result =
                    parseCliFailure
                        [ "withdraw-wizard"
                        , "--reference-label"
                        , "Missing URI"
                        ]
            resultExit result `shouldBe` ExitFailure 1
            resultBody result
                `shouldSatisfy` not
                    . isInfixOf
                        "--reference-label requires a preceding --reference-uri"

        it "lets later disburse-wizard --reference-type win" $
            parseDisburseReferences
                ( disburseWizardArgs
                    ++ [ "--reference-uri"
                       , "ipfs://one"
                       , "--reference-type"
                       , "Agreement"
                       , "--reference-type"
                       , "Invoice"
                       , "--reference-label"
                       , "Invoice 3508"
                       ]
                )
                `shouldBe` Right
                    [ RationaleReferenceJSON
                        { rjrUri = "ipfs://one"
                        , rjrType = "Invoice"
                        , rjrLabel = "Invoice 3508"
                        }
                    ]

        it "parses the Cyber Castellum four-reference input" $
            parseDisburseReferences cyberCastellumArgs
                `shouldBe` Right cyberCastellumReferences

        it "parses repeatable disburse-wizard treasury TxIn selectors" $
            parseDisburseTreasuryTxIns
                ( disburseWizardArgs
                    ++ [ "--treasury-txin"
                       , goodTxIn1
                       , "--treasury-utxo"
                       , goodTxIn2
                       ]
                )
                `shouldBe` Right [goodTxIn1, goodTxIn2]

        it "parses --scope contingency --to as a disburse-wizard command" $
            parseCmd contingencyDisburseArgs
                `shouldBe` Right "disburse-wizard"

        it "parses contingency --to ADA into lovelace" $
            parseContingencyDisburse contingencyDisburseArgs
                `shouldBe` Right (NetworkCompliance, 200000500000)

        it "rejects contingency as a --to destination" $
            parseCmd
                ( replaceArg
                    "network_compliance:200000.5"
                    "contingency:200000.5"
                    contingencyDisburseArgs
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
    case parseCliArgs args of
        Success (_, cmd) -> Right (cmdTag cmd)
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

parseContingencyDisburse
    :: [String] -> Either String (ScopeId, Integer)
parseContingencyDisburse args =
    case parseCliArgs args of
        Success (_, CmdDisburseWizard o) ->
            case dwiDestinations o of
                (d : _) -> Right d
                [] -> Left "no destinations"
        Success{} -> Left "wrong command"
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

parseDisburseTreasuryTxIns :: [String] -> Either String [String]
parseDisburseTreasuryTxIns args =
    case parseCliArgs args of
        Success (_, CmdDisburseWizard o) ->
            Right (T.unpack . txInToText <$> dwiTreasuryTxIns o)
        Success{} -> Left "wrong command"
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

parseDisburseReferences
    :: [String] -> Either String [RationaleReferenceJSON]
parseDisburseReferences args =
    case parseCliArgs args of
        Success (_, CmdDisburseWizard o) ->
            Right (dwiReferences o)
        Success{} -> Left "wrong command"
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

data ParserFailureResult = ParserFailureResult
    { resultBody :: !String
    , resultExit :: !ExitCode
    }
    deriving stock (Eq, Show)

parseDisburseFailure :: [String] -> ParserFailureResult
parseDisburseFailure = parseCliFailure

parseCliFailure :: [String] -> ParserFailureResult
parseCliFailure args =
    case parseCliArgs args of
        Failure failure ->
            let (body, code) = renderFailure failure "amaru-treasury-tx"
            in  ParserFailureResult body code
        Success{} ->
            errorWithoutStackTrace "expected parse failure"
        CompletionInvoked{} ->
            errorWithoutStackTrace "expected parse failure, got completion"

cmdTag :: Cmd -> String
cmdTag = \case
    CmdEnvelopeTx -> "envelope-tx"
    CmdEnvelopeWitness -> "envelope-witness"
    CmdEnvelopeSignedTx -> "envelope-signed-tx"
    CmdDeEnvelope -> "de-envelope"
    CmdAttachWitness{} -> "attach-witness"
    CmdSubmit{} -> "submit"
    CmdServe{} -> "serve"
    CmdTxBuild{} -> "tx-build"
    CmdSwapWizard{} -> "swap-wizard"
    CmdSwapQuote{} -> "swap-quote"
    CmdSwapCancel{} -> "swap-cancel"
    CmdDisburseWizard{} -> "disburse-wizard"
    CmdWithdrawWizard{} -> "withdraw-wizard"
    CmdReorganizeWizard{} -> "reorganize-wizard"
    CmdRegistryInitWizard{} -> "registry-init-wizard"
    CmdStakeRewardInitWizard{} -> "stake-reward-init-wizard"
    CmdGovernanceWithdrawalInitWizard{} ->
        "governance-withdrawal-init-wizard"
    CmdReportRender{} -> "report-render"
    CmdTreasuryInspect{} -> "treasury-inspect"
    CmdHistory{} -> "history"
    CmdTxDetail{} -> "tx-detail"
    CmdVaultCreate{} -> "vault-create"
    CmdWitness{} -> "witness"

contingencyDisburseArgs :: [String]
contingencyDisburseArgs =
    [ "disburse-wizard"
    , "--wallet-addr"
    , "addr1qx9aqvsf6gne2640jec828s25gzhk5wp2day8u24kf8mrs2v0zyuvk80fay35dx008p45ts0u6cdrv9g2maetq8jm8psznjcrz"
    , "--metadata"
    , "metadata-mainnet.json"
    , "--scope"
    , "contingency"
    , "--to"
    , "network_compliance:200000.5"
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

cyberCastellumArgs :: [String]
cyberCastellumArgs =
    replaceArg "1" "18750000000"
        $ replaceArg
            "Vendor payment"
            "Cyber Castellum Whitehacking Milestone 1 - 18750 USDM"
        $ replaceArg
            "Approved invoice"
            "Required to pay Cyber Castellum as vendor; payment instruction confirmed by CAG 2026-05-21"
        $ replaceArg
            "Vendor"
            "Crypto Accounting Group off-ramp wallet"
        $ disburseWizardArgs
            ++ concatMap referenceArgs cyberCastellumReferences

referenceArgs :: RationaleReferenceJSON -> [String]
referenceArgs ref =
    [ "--reference-uri"
    , T.unpack (rjrUri ref)
    , "--reference-label"
    , T.unpack (rjrLabel ref)
    ]

cyberCastellumReferences :: [RationaleReferenceJSON]
cyberCastellumReferences =
    [ RationaleReferenceJSON
        { rjrUri =
            "ipfs://bafybeib3jef34ndw6oe24mkmifdvxe5jrv7ulh63rdllovyth27mqfj2da"
        , rjrType = "Other"
        , rjrLabel =
            "Whitehacking Agreement - Cyber Castellum 2026-03-31"
        }
    , RationaleReferenceJSON
        { rjrUri =
            "ipfs://bafybeigy37ui2ikn7bim2vw6cojcbxkcndpjwh7cj5fv3vzs4cszezipxu"
        , rjrType = "Other"
        , rjrLabel =
            "Invoice 3508 - Cyber Castellum Whitehacking M1"
        }
    , RationaleReferenceJSON
        { rjrUri =
            "ipfs://bafybeibx32gm7wefhtvvhojoqjrkjbhntknqkgfu7ryrhptbnmjgz7jvga"
        , rjrType = "Other"
        , rjrLabel = "CAG MSA - 2026-04-09"
        }
    , RationaleReferenceJSON
        { rjrUri =
            "ipfs://bafkreihl2qvl4coduzqwg4hhh7l7go5ym7y5d7w3flzb5kpxvvquj3i3qm"
        , rjrType = "Other"
        , rjrLabel =
            "CAG payment confirmation - Laura Dugan email 2026-05-21"
        }
    ]

goodTxIdHex1 :: String
goodTxIdHex1 =
    "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

goodTxIdHex2 :: String
goodTxIdHex2 =
    "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"

goodTxIn1 :: String
goodTxIn1 = goodTxIdHex1 <> "#0"

goodTxIn2 :: String
goodTxIn2 = goodTxIdHex2 <> "#1"

replaceArg :: String -> String -> [String] -> [String]
replaceArg old new =
    fmap (\arg -> if arg == old then new else arg)
