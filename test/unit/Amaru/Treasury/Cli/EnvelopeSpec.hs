{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.EnvelopeSpec
Description : CLI parser tests for cardano-cli envelope filters
License     : Apache-2.0
-}
module Amaru.Treasury.Cli.EnvelopeSpec (spec) where

import Options.Applicative
    ( ParserResult (..)
    , defaultPrefs
    , execParserPure
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

import Amaru.Treasury.Cli
    ( Cmd (..)
    , opts
    )
import Amaru.Treasury.Cli.Envelope
    ( runEnvelopeFilter
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

        it "leaves attach-witness on its raw-hex option shape" $
            parseCmd ["attach-witness", "--witness", "deadbeef"]
                `shouldBe` Right "attach-witness"

        it "leaves submit on its raw-hex option shape" $
            parseCmd ["submit", "--tx", "signed.cbor"]
                `shouldBe` Right "submit"

        it "leaves tx-build on its existing option shape" $
            parseCmd ["tx-build", "--out", "-"]
                `shouldBe` Right "tx-build"

        it "filters stdin bytes into an envelope" $
            runEnvelopeFilter Tx "deadbeef\n"
                `shouldBe` "{\n    \"type\": \"Tx ConwayEra\",\n    \"description\": \"Ledger Cddl Format\",\n    \"cborHex\": \"deadbeef\"\n}\n"

parseCmd :: [String] -> Either String String
parseCmd args =
    case execParserPure defaultPrefs opts args of
        Success (_, cmd) -> Right (cmdTag cmd)
        Failure{} -> Left "parse failure"
        CompletionInvoked{} -> Left "completion invoked"

cmdTag :: Cmd -> String
cmdTag = \case
    CmdEnvelopeTx -> "envelope-tx"
    CmdEnvelopeWitness -> "envelope-witness"
    CmdEnvelopeSignedTx -> "envelope-signed-tx"
    CmdAttachWitness{} -> "attach-witness"
    CmdSubmit{} -> "submit"
    CmdTxBuild{} -> "tx-build"
    CmdSwapWizard{} -> "swap-wizard"
    CmdSwapQuote{} -> "swap-quote"
    CmdDisburseWizard{} -> "disburse-wizard"
    CmdWithdrawWizard{} -> "withdraw-wizard"
    CmdReportRender{} -> "report-render"
