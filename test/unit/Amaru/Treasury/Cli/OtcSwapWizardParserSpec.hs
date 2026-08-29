{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Cli.OtcSwapWizardParserSpec
Description : Parser-shape tests for otc-swap-wizard (issue #499 slice D)
License     : Apache-2.0

Pins the documented operator command shape: named assets and decimal
amounts in, hex and base units only in the emitted intent; the
repeatable @--counterparty-txin@ and @--treasury-txin@ restricts
accumulate in flag order; there is no default asset.
-}
module Amaru.Treasury.Cli.OtcSwapWizardParserSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
    ( ParserInfo
    , ParserPrefs
    , ParserResult (..)
    , defaultPrefs
    , execParserPure
    , info
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Cli.OtcSwapWizard
    ( OtcSwapWizardOpts (..)
    , otcSwapWizardOptsP
    )
import Amaru.Treasury.Scope
    ( ScopeId (..)
    )

isFailure :: ParserResult a -> Bool
isFailure = \case
    Failure _ -> True
    _ -> False

spec :: Spec
spec =
    describe "OtcSwapWizardParser" $ do
        it "parses the documented command shape" $
            case parseOpts
                [ "--wallet-addr"
                , walletAddr
                , "--metadata"
                , "metadata.json"
                , "--scope"
                , "network_compliance"
                , "--counterparty-addr"
                , counterpartyAddr
                , "--incoming"
                , "10"
                , "--incoming-asset"
                , "usdm"
                , "--ada-out"
                , "47.619047"
                , "--price"
                , "0.21"
                , "--description"
                , "Buy USDM"
                , "--justification"
                , "OTC window"
                , "--destination-label"
                , "NC treasury"
                , "--extra-signer"
                , "ops_and_use_cases"
                , "--validity-hours"
                , "48"
                , "--out"
                , "rundir/intent.json"
                ] of
                Success o -> do
                    oswWalletAddr o `shouldBe` walletAddr
                    oswScope o `shouldBe` NetworkCompliance
                    oswCounterpartyAddr o `shouldBe` counterpartyAddr
                    oswAdaOut o `shouldBe` "47.619047"
                    oswIncomingAsset o `shouldBe` "usdm"
                    oswIncomingQuantity o `shouldBe` "10"
                    oswPrice o `shouldBe` "0.21"
                    oswValidityHours o `shouldBe` Just 48
                    oswDescription o `shouldBe` "Buy USDM"
                    oswJustification o `shouldBe` "OTC window"
                    oswDestinationLabel o `shouldBe` "NC treasury"
                    oswSigners o `shouldBe` ["ops_and_use_cases"]
                    oswOut o `shouldBe` Just "rundir/intent.json"
                    oswEvent o `shouldBe` Nothing
                    oswLabel o `shouldBe` Nothing
                    oswCounterpartyTxIns o `shouldBe` []
                    oswTreasuryTxIns o `shouldBe` []
                r ->
                    error ("parse failed: " <> show r)

        it "accumulates repeatable restricts in flag order" $
            case parseOpts
                [ "--wallet-addr"
                , walletAddr
                , "--metadata"
                , "m.json"
                , "--scope"
                , "core_development"
                , "--counterparty-addr"
                , counterpartyAddr
                , "--counterparty-txin"
                , "aa#0"
                , "--counterparty-txin"
                , "bb#1"
                , "--treasury-txin"
                , "cc#2"
                , "--ada-out"
                , "1"
                , "--incoming-asset"
                , "aa.00"
                , "--incoming"
                , "5"
                , "--price"
                , "0.5"
                , "--description"
                , "d"
                , "--justification"
                , "j"
                , "--destination-label"
                , "l"
                ] of
                Success o -> do
                    oswCounterpartyTxIns o `shouldBe` ["aa#0", "bb#1"]
                    oswTreasuryTxIns o `shouldBe` ["cc#2"]
                    oswScope o `shouldBe` CoreDevelopment
                r ->
                    error ("parse failed: " <> show r)

        it "accepts raw <policyHex>.<assetNameHex> assets" $
            case parseOpts
                ( baseArgs
                    [ "--incoming-asset"
                    , T.replicate 56 "a" <> ".1f"
                    ]
                ) of
                Success o ->
                    oswIncomingAsset o
                        `shouldBe` T.replicate 56 "a" <> ".1f"
                r ->
                    error ("parse failed: " <> show r)

        it "rejects an invocation without the asset" $
            parseOpts (baseArgs [])
                `shouldSatisfy` isFailure

{- | Required flags EXCEPT @--incoming-asset@: there is no default,
so tests append their asset choice explicitly and the bare @[]@
form must fail to parse.
-}
baseArgs :: [Text] -> [Text]
baseArgs extra =
    [ "--wallet-addr"
    , walletAddr
    , "--metadata"
    , "m.json"
    , "--scope"
    , "network_compliance"
    , "--counterparty-addr"
    , counterpartyAddr
    , "--incoming"
    , "10"
    , "--ada-out"
    , "1"
    , "--price"
    , "0.1"
    , "--description"
    , "d"
    , "--justification"
    , "j"
    , "--destination-label"
    , "l"
    ]
        <> extra

walletAddr :: Text
walletAddr =
    "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"

counterpartyAddr :: Text
counterpartyAddr =
    "addr1qy8ac7qqy0vtulyl7wntmsxc6wex80gvcyjy33qffrhm7sh927ysx5sftuw0dlft05dz3c7revpf7jx0xnlcjz3g69mq4afdhv"

parseOpts :: [Text] -> ParserResult OtcSwapWizardOpts
parseOpts args =
    execParserPure prefs parserInfo (fmap T.unpack args)
  where
    prefs :: ParserPrefs
    prefs = defaultPrefs

    parserInfo :: ParserInfo OtcSwapWizardOpts
    parserInfo = info otcSwapWizardOptsP mempty
