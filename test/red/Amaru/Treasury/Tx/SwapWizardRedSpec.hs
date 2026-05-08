{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Amaru.Treasury.Tx.SwapWizardRedSpec
Description : T002 + T003 red-step coverage (FR-001 and FR-002)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Asserts the post-fix invariants from
@specs/008-disburse-includes-overhead/spec.md@ that the four-site
builder fix (T006) must satisfy.

* __FR-001 (T002)__:

    @
      siRedeemerAmountLovelace
        == sum (map soLovelace siSwapOrders)
           + N * siSwapOrderExtraLovelace
    @

* __FR-002 (T003)__: the treasury leftover output must shrink by
    exactly @N * extraPerChunkLovelace@ compared to today's
    behaviour, so the treasury (not the operator wallet) covers
    the swap-order overhead. The assertion is expressed against a
    known total treasury input value and checks

    @
      siTreasuryLeftoverLovelace
        == treasuryInputLovelace
           - sum (map soLovelace siSwapOrders)
           - N * siSwapOrderExtraLovelace
    @

Today's @translateSwap@ in @lib\/Amaru\/Treasury\/IntentJSON.hs@
sets @siRedeemerAmountLovelace = Coin (swiAmountLovelace sw)@ and
today's @resolveWizardEnv@ in @lib\/Amaru\/Treasury\/Tx\/SwapWizard.hs@
passes @target = riAmountLovelace@ to @selectTreasury@ — the
per-chunk overhead is missing from both — so the assertions in
this module **fail** against the current builder. They will pass
after T006 lands the four-site fix.

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
import Amaru.Treasury.Scope (ScopeId (..))
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , SwapOrderOut (..)
    )
import Amaru.Treasury.Tx.SwapWizard
    ( ResolverEnv (..)
    , ResolverInput (..)
    , SwapWizardQ (..)
    , WalletSelection (..)
    , WizardEnv (..)
    , resolveWizardEnv
    , wizardToTreasuryIntent
    )

loadFixture :: (FromJSON a) => FilePath -> IO a
loadFixture path = do
    e <- eitherDecodeFileStrict path
    case e of
        Left err -> error (path <> ": " <> err)
        Right ok -> pure ok

spec :: Spec
spec = describe "SwapWizard red-step (T002 + T003)" $ do
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

    -- T003 / FR-002: the treasury leftover must shrink by exactly
    -- `N * extraPerChunkLovelace` compared to today's behaviour, so
    -- the treasury (not the operator wallet) covers the swap-order
    -- overhead. Today's resolver passes `target = chunk_total` to
    -- `selectTreasury`; post-fix it must pass
    -- `target = chunk_total + N * extraPerChunkLovelace`. Going
    -- through `resolveWizardEnv` with a stub provider exercises the
    -- buggy call site so the assertion fails today.
    describe "FR-002 leftover shrinks by N * extraPerChunkLovelace" $ do
        let treasuryInputLovelace :: Integer
            treasuryInputLovelace = 1_450_000_000_000

            stubResolver :: ResolverEnv IO
            stubResolver =
                ResolverEnv
                    { reEnvQueryWalletUtxos = \_ ->
                        pure
                            [
                                ( "42e4c279036e3ab6070bc969392b823917d8b998204d5dcbdfe69fec4b442da0#0"
                                , 1_000_000_000
                                , False
                                )
                            ]
                    , reEnvQueryTreasuryUtxos = \_ ->
                        pure
                            [
                                ( "64f27254f3c0311fb2e672cdb87de200089a596aa90dc09f8be4248540267cf0#0"
                                , treasuryInputLovelace
                                , False
                                )
                            ]
                    , reEnvCurrentTip = pure 186342942
                    }

            resolveAndTranslate
                :: Integer
                -- \^ amount lovelace (will also drive
                -- the resolver's selectTreasury target)
                -> Integer
                -- \^ chunk size lovelace
                -> IO SwapIntent
            resolveAndTranslate amount chunkSize = do
                let ri =
                        ResolverInput
                            { riNetwork = "mainnet"
                            , riWalletAddrBech32 =
                                "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                            , riScope = CoreDevelopment
                            , riAmountLovelace = amount
                            , riRegistry = weRegistry env
                            }
                resolved <- resolveWizardEnv stubResolver ri
                env' <- case resolved of
                    Left e ->
                        error
                            ( "resolveWizardEnv: "
                                <> show e
                            )
                    Right ok -> pure ok
                let envOverMainnet =
                        env'
                            { weNetwork = "mainnet"
                            , weWalletSelection =
                                (weWalletSelection env')
                                    { wsAddress =
                                        wsAddress
                                            ( weWalletSelection
                                                env
                                            )
                                    }
                            }
                    q =
                        answers
                            { wqAmountLovelace = amount
                            , wqChunkSizeLovelace = chunkSize
                            }
                intent <- case wizardToTreasuryIntent envOverMainnet q of
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

            checkLeftover
                :: String
                -> Integer
                -> Integer
                -> Integer
                -> Spec
            checkLeftover desc amount chunkSize expectedN =
                it desc $ do
                    si <- resolveAndTranslate amount chunkSize
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
                        expectedLeftover =
                            treasuryInputLovelace
                                - chunkTotal
                                - n * extra
                    n `shouldBe` expectedN
                    unCoin
                        (siTreasuryLeftoverLovelace si)
                        `shouldBe` expectedLeftover

        checkLeftover
            "no-split case (N = 1): leftover shrinks by 1 * extraPerChunkLovelace"
            100_000_000
            100_000_000
            1
        checkLeftover
            "issue capture (N = 12): leftover shrinks by 12 * extraPerChunkLovelace"
            1_200_000_000
            100_000_000
            12
