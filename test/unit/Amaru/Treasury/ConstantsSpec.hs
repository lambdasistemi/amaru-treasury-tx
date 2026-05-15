{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.ConstantsSpec
Description : Tests for shared treasury constants
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.ConstantsSpec (spec) where

import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Credential (Credential (..))

import Amaru.Treasury.Constants
    ( sundaeOrderAddressMainnet
    , sundaeOrderScriptHashMainnet
    , sundaeOrderScriptRefMainnet
    )
import Amaru.Treasury.LedgerParse (addrFromText)
import Amaru.Treasury.Registry.Derive
    ( scriptHashOfBlob
    , scriptHashToHex
    )
import Amaru.Treasury.Sundae.Contracts
    ( sundaeOrderValidatorBlob
    , sundaeOrderValidatorScriptHashHex
    , sundaeOrderValidatorSourceCommit
    , sundaeOrderValidatorTitle
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Constants" $ do
        it "pins the Sundae mainnet order validator hash" $
            sundaeOrderScriptHashMainnet
                `shouldBe` "fa6a58bbe2d0ff05534431c8e2f0ef2cbdc1602a8456e4b13c8f3077"

        it "pins the Sundae mainnet order validator reference UTxO" $
            sundaeOrderScriptRefMainnet
                `shouldBe` "f5f1bdfad3eb4d67d2fc36f36f47fc2938cf6f001689184ab320735a28642cf2#0"

        it "keeps the order validator hash aligned with the order address" $
            case addrFromText sundaeOrderAddressMainnet of
                Right (Addr _ (ScriptHashObj scriptHash) _) ->
                    scriptHashToHex scriptHash
                        `shouldBe` sundaeOrderScriptHashMainnet
                Right _ ->
                    expectationFailure
                        "Sundae order address is not a script address"
                Left e ->
                    expectationFailure e

        it "pins the public SundaeSwap V3 order.spend artifact" $ do
            sundaeOrderValidatorSourceCommit
                `shouldBe` "be33466b7dbe0f8e6c0e0f46ff23737897f45835"
            sundaeOrderValidatorTitle `shouldBe` "order.spend"
            sundaeOrderValidatorScriptHashHex
                `shouldBe` "02eee6c4d128c9700c178922163645f1fdb381bbdce071acbbd49465"
            case scriptHashOfBlob sundaeOrderValidatorBlob of
                Right scriptHash ->
                    scriptHashToHex scriptHash
                        `shouldBe` sundaeOrderValidatorScriptHashHex
                Left e ->
                    expectationFailure e
