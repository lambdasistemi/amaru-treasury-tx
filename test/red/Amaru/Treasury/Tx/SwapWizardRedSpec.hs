{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Amaru.Treasury.Tx.SwapWizardRedSpec
Description : T002 + T003 + T004 red-step coverage (FR-001, FR-002, FR-009)
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

* __FR-009 (T004)__: when the treasury UTxO can fund @chunk_total@
    but not @chunk_total + N * extraPerChunkLovelace@, the build
    must fail at construction time with a clear shortfall
    identifying the available and requested lovelace. The
    assertion runs the full pipeline
    @resolveWizardEnv → wizardToTreasuryIntent@ against a stub
    treasury whose lovelace exactly equals @chunk_total@, and
    checks that the resulting @Left e@ has @show e@ text
    containing the literal @\"Shortfall\"@, the available amount,
    and the requested target

    @
      amount + N * ncExtraPerChunkLovelace nc
    @

    derived from @networkConstants \"mainnet\"@ — the same
    authoritative overhead source the implementation reads from
    (FR-006). Whether the resolver, the wizard, or another check
    catches the shortfall is left to T006.

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
    , shouldContain
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
    ( NetworkConstants (..)
    , ResolverEnv (..)
    , ResolverInput (..)
    , SwapWizardQ (..)
    , WalletSelection (..)
    , WizardEnv (..)
    , networkConstants
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
spec = describe "SwapWizard red-step (T002 + T003 + T004)" $ do
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

    -- T004 / FR-009: when the treasury UTxO can fund `chunk_total`
    -- but not `chunk_total + N * extraPerChunkLovelace`, the
    -- builder must fail at construction time with a clear
    -- shortfall identifying the available and requested
    -- lovelace.
    --
    -- The assertion runs the **full pipeline**
    -- (`resolveWizardEnv → wizardToTreasuryIntent`) so the test
    -- exercises a construction boundary that has both the
    -- treasury input value (from the resolver stub) and the swap
    -- intent's chunk/overhead information (from `SwapWizardQ` and
    -- the env's `NetworkConstants`). The expected target is
    -- derived from `ncExtraPerChunkLovelace` of the
    -- `networkConstants "mainnet"` table — the same authoritative
    -- source the implementation reads from (FR-006 single-source
    -- rule).
    --
    -- Today's `resolveWizardEnv` passes `target = riAmountLovelace`
    -- to `selectTreasury` (overhead omitted); a treasury UTxO that
    -- exactly equals `chunk_total` therefore resolves to
    -- `tsLeftoverLovelace = 0`, the wizard accepts the buggy
    -- env, and the pipeline returns `Right intent` — exactly
    -- issue #68's bug. Post-fix the pipeline must return `Left e`
    -- whose `show e` text:
    --
    --   * contains the literal string @"Shortfall"@ (the failure
    --     mode, regardless of which T006 boundary catches it —
    --     resolver, wizard, or otherwise);
    --   * contains the available lovelace amount (the treasury
    --     total, i.e. @amount@); and
    --   * contains the requested target amount derived as
    --     @amount + N * ncExtraPerChunkLovelace nc@.
    describe "FR-009 shortfall when treasury cannot fund overhead" $ do
        nc :: NetworkConstants <-
            runIO $ case networkConstants "mainnet" of
                Right ok -> pure ok
                Left e -> error (show e)
        let extraPerChunk :: Integer
            extraPerChunk = ncExtraPerChunkLovelace nc

            stubAtTreasuryTotal :: Integer -> ResolverEnv IO
            stubAtTreasuryTotal total =
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
                                , total
                                , False
                                )
                            ]
                    , reEnvCurrentTip = pure 186342942
                    }

            -- \| Run the full builder pipeline against a treasury UTxO
            -- whose lovelace exactly equals @amount@.
            runPipelineAtChunkTotal
                :: Integer
                -- \^ amount lovelace
                -> Integer
                -- \^ chunk size lovelace
                -> IO (Either String ())
            runPipelineAtChunkTotal amount chunkSize = do
                let stub = stubAtTreasuryTotal amount
                    ri =
                        ResolverInput
                            { riNetwork = "mainnet"
                            , riWalletAddrBech32 =
                                "addr1q802wxt6cg6aw0nl0vdzfxavu65rxu3yzhvgayw7chfxymduzkt66uw9t5kspx5jwjecx80dz4g33htknafhdhkvzd5st4f9xu"
                            , riScope = CoreDevelopment
                            , riAmountLovelace = amount
                            , riRegistry = weRegistry env
                            }
                resolved <- resolveWizardEnv stub ri
                case resolved of
                    Left e ->
                        -- Resolver caught the shortfall first
                        -- (post-fix design A).
                        pure (Left ("resolver: " <> show e))
                    Right env' -> do
                        let envOver =
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
                                    { wqAmountLovelace =
                                        amount
                                    , wqChunkSizeLovelace =
                                        chunkSize
                                    }
                        case wizardToTreasuryIntent envOver q of
                            Left e ->
                                -- Wizard caught the shortfall
                                -- post-resolution (post-fix
                                -- design B).
                                pure
                                    ( Left
                                        ( "wizard: " <> show e
                                        )
                                    )
                            Right _ ->
                                -- Pipeline silently produced an
                                -- intent — today's bug, FR-009
                                -- violation.
                                pure (Right ())

            checkShortfall
                :: String
                -> Integer
                -- \^ amount lovelace
                -> Integer
                -- \^ chunk size lovelace
                -> Integer
                -- \^ expected N (number of chunks)
                -> Spec
            checkShortfall desc amount chunkSize expectedN =
                it desc $ do
                    r <- runPipelineAtChunkTotal amount chunkSize
                    let expectedTarget =
                            amount + expectedN * extraPerChunk
                    case r of
                        Left errStr -> do
                            -- The error must identify a
                            -- shortfall, name the available
                            -- amount, and name the requested
                            -- target derived from
                            -- ncExtraPerChunkLovelace.
                            errStr `shouldContain` "Shortfall"
                            errStr `shouldContain` show amount
                            errStr `shouldContain` show expectedTarget
                        Right () ->
                            error
                                ( "expected pipeline to fail per FR-009 "
                                    <> "when treasury cannot fund "
                                    <> "chunk_total + N * extraPerChunkLovelace; "
                                    <> "today's builder silently accepts the "
                                    <> "shortfall and produces a Right intent."
                                )

        checkShortfall
            "no-split case (N = 1): treasury exactly = chunk_total fails to fund overhead"
            100_000_000
            100_000_000
            1
        checkShortfall
            "issue capture (N = 12): treasury exactly = chunk_total fails to fund overhead"
            1_200_000_000
            100_000_000
            12
