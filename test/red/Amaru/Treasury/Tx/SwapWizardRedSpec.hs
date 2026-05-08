{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Amaru.Treasury.Tx.SwapWizardRedSpec
Description : T002 / FR-001 red-step coverage
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Asserts the post-fix invariant from
@specs/008-disburse-includes-overhead/spec.md@ FR-001:

@
  siRedeemerAmountLovelace
    == sum (map soLovelace siSwapOrders)
       + N * siSwapOrderExtraLovelace
@

Today's @translateSwap@ in @lib\/Amaru\/Treasury\/IntentJSON.hs@
sets @siRedeemerAmountLovelace = Coin (swiAmountLovelace sw)@ —
the per-chunk overhead is missing — so the assertions in this
module **fail** against the current builder. They will pass after
T006 lands the four-site fix.

This suite is intentionally separate from @unit-tests@ so the
default review gate (@nix build .#checks.unit@) stays green
while the failing assertions remain available as an executable
red proof. Run @just red@ or @cabal test red-tests@ to see the
diff between current and post-fix behavior.
-}
module Amaru.Treasury.Tx.SwapWizardRedSpec (spec) where

import Data.Aeson (FromJSON, eitherDecodeFileStrict)
import Test.Hspec
    ( Spec
    , describe
    , it
    , runIO
    , shouldBe
    )

import Cardano.Ledger.Coin (Coin (..))

import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , translateIntent
    )
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , SwapOrderOut (..)
    )
import Amaru.Treasury.Tx.SwapWizard
    ( SwapWizardQ (..)
    , WizardEnv
    , wizardToTreasuryIntent
    )

loadFixture :: (FromJSON a) => FilePath -> IO a
loadFixture path = do
    e <- eitherDecodeFileStrict path
    case e of
        Left err -> error (path <> ": " <> err)
        Right ok -> pure ok

spec :: Spec
spec = describe "SwapWizard red-step (T002 / FR-001)" $ do
    env :: WizardEnv <-
        runIO
            (loadFixture "test/fixtures/swap-wizard/env.json")
    answers :: SwapWizardQ <-
        runIO
            (loadFixture "test/fixtures/swap-wizard/answers.json")

    let translateWith
            :: Integer
            -- \^ amount lovelace
            -> Integer
            -- \^ chunk size lovelace
            -> IO SwapIntent
        translateWith amount chunkSize = do
            let q =
                    answers
                        { wqAmountLovelace = amount
                        , wqChunkSizeLovelace = chunkSize
                        }
            intent <- case wizardToTreasuryIntent env q of
                Left e ->
                    error
                        ( "wizardToTreasuryIntent: "
                            <> show e
                        )
                Right ok -> pure ok
            case translateIntent SSwap intent of
                Left e ->
                    error ("translateIntent: " <> e)
                Right (_, si) -> pure si

        -- \| @check desc amount chunkSize expectedN@ asserts
        -- that the disburse redeemer amount produced by the
        -- full wizard → typed-intent pipeline equals
        -- @sum (map soLovelace siSwapOrders) + N * siSwapOrderExtraLovelace@.
        check
            :: String
            -> Integer
            -> Integer
            -> Integer
            -> Spec
        check desc amount chunkSize expectedN =
            it desc $ do
                si <- translateWith amount chunkSize
                let n = toInteger (length (siSwapOrders si))
                    chunkTotal =
                        sum
                            ( map
                                ( unCoin
                                    . soLovelace
                                )
                                (siSwapOrders si)
                            )
                    extra =
                        unCoin (siSwapOrderExtraLovelace si)
                n `shouldBe` expectedN
                unCoin (siRedeemerAmountLovelace si)
                    `shouldBe` chunkTotal + n * extra

    check
        "no-split case (N = 1): redeemer = chunk_total + 1 * extraPerChunkLovelace"
        100_000_000
        100_000_000
        1
    check
        "issue capture (N = 12): redeemer = chunk_total + 12 * extraPerChunkLovelace"
        1_200_000_000
        100_000_000
        12
