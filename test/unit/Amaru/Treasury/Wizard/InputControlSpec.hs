{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.InputControlSpec
Description : RED-then-GREEN unit tests for the shared
              @--exclude-utxo@ / @--extra-tx-in@ helper.
License     : Apache-2.0

Backs T001/T002/T003 of Slice 1 of the
[issue #184](https://github.com/lambdasistemi/amaru-treasury-tx/issues/184)
plan. Every public export of
'Amaru.Treasury.Wizard.InputControl' is exercised here so the
project's @-Werror -Wunused-top-binds@ regime stays green.
-}
module Amaru.Treasury.Wizard.InputControlSpec
    ( spec
    ) where

import Data.Either (isLeft, isRight)
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
    ( ParserResult (Failure, Success)
    , defaultPrefs
    , execParserPure
    , fullDesc
    , helper
    , info
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Wizard.InputControl
    ( ExclusionSet (ExclusionSet)
    , ForcedInclusionSet (ForcedInclusionSet)
    , InputControlError (Contradiction)
    , OutRef
    , excludeUtxoP
    , extraTxInP
    , filterPool
    , outRefText
    , parseOutRef
    , renderInputControlError
    , renderShortfallWithExcludes
    , validateInputControl
    )
import Amaru.Treasury.Wizard.InputControlTestHelpers
    ( candidateRef
    , hashA
    , hashB
    , hashC
    , mkCandidate
    , outRefA0
    , outRefB1
    , outRefC2
    , sampleCandidates
    )

spec :: Spec
spec = do
    parseOutRefSpec
    validateInputControlSpec
    filterPoolSpec
    renderSpec
    parsersSpec

-- ----------------------------------------------------------------------
-- T001 — parseOutRef
-- ----------------------------------------------------------------------

parseOutRefSpec :: Spec
parseOutRefSpec = describe "parseOutRef" $ do
    it "accepts valid 64-char lowercase hex + # + index 0" $ do
        let raw = hashA <> "#0"
        case parseOutRef raw of
            Right r -> outRefText r `shouldBe` raw
            Left e -> error (T.unpack e)
    it "accepts a non-trivial positive index" $ do
        let raw = hashB <> "#1"
        case parseOutRef raw of
            Right r -> outRefText r `shouldBe` raw
            Left e -> error (T.unpack e)
    it "rejects uppercase hex" $
        parseOutRef (T.toUpper hashA <> "#0") `shouldSatisfy` isLeft
    it "rejects missing #" $
        parseOutRef hashA `shouldSatisfy` isLeft
    it "rejects non-numeric index" $
        parseOutRef (hashA <> "#abc") `shouldSatisfy` isLeft
    it "rejects negative index" $
        parseOutRef (hashA <> "#-1") `shouldSatisfy` isLeft
    it "accepts index with leading zeros" $
        parseOutRef (hashA <> "#007") `shouldSatisfy` isRight
    it "rejects surplus chars after the index" $
        parseOutRef (hashA <> "#0xyz") `shouldSatisfy` isLeft
    it "rejects hash shorter than 64 chars" $
        parseOutRef (T.drop 1 hashA <> "#0") `shouldSatisfy` isLeft
    it "rejects hash longer than 64 chars" $
        parseOutRef (hashA <> "ab" <> "#0") `shouldSatisfy` isLeft
    it "rejects empty string" $
        parseOutRef "" `shouldSatisfy` isLeft

-- ----------------------------------------------------------------------
-- T002 — validateInputControl
-- ----------------------------------------------------------------------

validateInputControlSpec :: Spec
validateInputControlSpec =
    describe "validateInputControl" $ do
        it "passes when sets are disjoint" $
            validateInputControl
                (ExclusionSet [outRefA0])
                (ForcedInclusionSet [outRefB1])
                `shouldBe` Right ()
        it "passes when both sets are empty" $
            validateInputControl
                (ExclusionSet [])
                (ForcedInclusionSet [])
                `shouldBe` Right ()
        it "fails with Contradiction naming a single overlap" $
            validateInputControl
                (ExclusionSet [outRefA0])
                (ForcedInclusionSet [outRefA0])
                `shouldBe` Left (Contradiction [outRefA0])
        it
            "fails with Contradiction naming both overlaps \
            \in deterministic order (input order of exclusion set)"
            $ validateInputControl
                (ExclusionSet [outRefA0, outRefB1])
                (ForcedInclusionSet [outRefB1, outRefA0])
                `shouldBe` Left
                    (Contradiction [outRefA0, outRefB1])

-- ----------------------------------------------------------------------
-- T003 — filterPool
-- ----------------------------------------------------------------------

filterPoolSpec :: Spec
filterPoolSpec = describe "filterPool" $ do
    let pool = sampleCandidates
        excl = ExclusionSet
        force = ForcedInclusionSet

    it "empty exclusion set is a no-op (no hits, no inert, no extras)" $
        filterPool candidateRef (excl []) (force []) pool
            `shouldBe` (pool, [], [], [])

    it "single match removes one element and records it as a hit" $ do
        let (remaining, hits, inert, extras) =
                filterPool
                    candidateRef
                    (excl [outRefA0])
                    (force [])
                    pool
        map candidateRef remaining `shouldBe` [outRefB1, outRefC2]
        hits `shouldBe` [outRefA0]
        inert `shouldBe` []
        extras `shouldBe` []

    it "multi match preserves remaining order" $ do
        let (remaining, hits, _inert, _extras) =
                filterPool
                    candidateRef
                    (excl [outRefA0, outRefC2])
                    (force [])
                    pool
        map candidateRef remaining `shouldBe` [outRefB1]
        hits `shouldBe` [outRefA0, outRefC2]

    it "no match returns the original list unchanged" $ do
        let ghost =
                case parseOutRef
                    ( T.replicate 64 "e"
                        <> "#9"
                    ) of
                    Right r -> r
                    Left e -> error (T.unpack e)
            (remaining, hits, inert, extras) =
                filterPool
                    candidateRef
                    (excl [ghost])
                    (force [])
                    pool
        remaining `shouldBe` pool
        hits `shouldBe` []
        inert `shouldBe` [ghost]
        extras `shouldBe` []

    it
        "exclude-not-present-in-pool returns original list AND \
        \records the inert excluded ref (per spec Edge Case)"
        $ do
            let ghost =
                    case parseOutRef
                        ( T.replicate 64 "f"
                            <> "#3"
                        ) of
                        Right r -> r
                        Left e -> error (T.unpack e)
                (remaining, hits, inert, _) =
                    filterPool
                        candidateRef
                        (excl [outRefA0, ghost])
                        (force [])
                        pool
            map candidateRef remaining `shouldBe` [outRefB1, outRefC2]
            hits `shouldBe` [outRefA0]
            inert `shouldBe` [ghost]

    it
        "forced-inclusion ref present in pool is removed from pool \
        \and emitted into extras exactly once (FR-006 dedup)"
        $ do
            let (remaining, _hits, _inert, extras) =
                    filterPool
                        candidateRef
                        (excl [])
                        (force [outRefB1])
                        pool
            map candidateRef remaining `shouldBe` [outRefA0, outRefC2]
            extras `shouldBe` [outRefB1]

    it
        "multi-ref --extra-tx-in ordering is preserved in \
        \input order (FR-006 no silent reordering)"
        $ do
            let extraNew =
                    case parseOutRef
                        ( T.replicate 64 "d"
                            <> "#5"
                        ) of
                        Right r -> r
                        Left e -> error (T.unpack e)
                (_, _, _, extras) =
                    filterPool
                        candidateRef
                        (excl [])
                        (force [outRefC2, extraNew, outRefA0])
                        pool
            extras `shouldBe` [outRefC2, extraNew, outRefA0]

    it "exercises mkCandidate test-helper builder" $ do
        let c = mkCandidate hashC 2 True
        candidateRef c `shouldBe` outRefC2

-- ----------------------------------------------------------------------
-- T003 (continued) — renderShortfallWithExcludes
-- ----------------------------------------------------------------------

renderSpec :: Spec
renderSpec = do
    describe "renderShortfallWithExcludes" $ do
        it "no excluded refs returns the base message unchanged" $
            renderShortfallWithExcludes "wallet shortfall" []
                `shouldBe` "wallet shortfall"
        it "one excluded ref appears on its own line, no trailing newline" $
            renderShortfallWithExcludes
                "wallet shortfall"
                [outRefA0]
                `shouldBe` "wallet shortfall\nexcluded utxos:\n"
                    <> outRefText outRefA0
        it
            "multiple excluded refs preserve input order, one per line, no trailing newline"
            $ do
                let rendered =
                        renderShortfallWithExcludes
                            "wallet shortfall"
                            [outRefC2, outRefA0, outRefB1]
                    expected =
                        "wallet shortfall\nexcluded utxos:\n"
                            <> outRefText outRefC2
                            <> "\n"
                            <> outRefText outRefA0
                            <> "\n"
                            <> outRefText outRefB1
                rendered `shouldBe` expected
                T.last rendered `shouldSatisfy` (/= '\n')
    describe "renderInputControlError" $ do
        it "renders a single-ref contradiction" $
            renderInputControlError (Contradiction [outRefA0])
                `shouldSatisfy` T.isInfixOf (outRefText outRefA0)
        it "renders a multi-ref contradiction listing every ref" $ do
            let rendered =
                    renderInputControlError
                        ( Contradiction
                            [outRefA0, outRefB1]
                        )
            rendered `shouldSatisfy` T.isInfixOf (outRefText outRefA0)
            rendered `shouldSatisfy` T.isInfixOf (outRefText outRefB1)

-- ----------------------------------------------------------------------
-- Bonus — optparse-applicative parsers (exercises excludeUtxoP / extraTxInP)
-- ----------------------------------------------------------------------

parsersSpec :: Spec
parsersSpec = describe "excludeUtxoP / extraTxInP" $ do
    let pInfo p = info (helper <*> p) fullDesc
    it "excludeUtxoP collects repeated --exclude-utxo in input order" $ do
        let args =
                [ "--exclude-utxo"
                , T.unpack (outRefText outRefA0)
                , "--exclude-utxo"
                , T.unpack (outRefText outRefC2)
                ]
        case execParserPure defaultPrefs (pInfo excludeUtxoP) args of
            Success refs -> refs `shouldBe` [outRefA0, outRefC2]
            Failure _ -> error "expected Success"
            _ -> error "unexpected completion result"
    it "excludeUtxoP defaults to []" $
        case execParserPure defaultPrefs (pInfo excludeUtxoP) [] of
            Success refs -> refs `shouldBe` []
            Failure _ -> error "expected Success"
            _ -> error "unexpected completion result"
    it "excludeUtxoP rejects malformed outref" $ do
        let args = ["--exclude-utxo", "not-an-outref"]
            isFailure = case execParserPure
                defaultPrefs
                (pInfo excludeUtxoP)
                args of
                Failure _ -> True
                _ -> False
        isFailure `shouldBe` True
    it "extraTxInP collects repeated --extra-tx-in in input order" $ do
        let args =
                [ "--extra-tx-in"
                , T.unpack (outRefText outRefB1)
                , "--extra-tx-in"
                , T.unpack (outRefText outRefA0)
                ]
        case execParserPure defaultPrefs (pInfo extraTxInP) args of
            Success refs -> refs `shouldBe` [outRefB1, outRefA0]
            Failure _ -> error "expected Success"
            _ -> error "unexpected completion result"
    it "extraTxInP defaults to []" $
        case execParserPure defaultPrefs (pInfo extraTxInP) [] of
            Success refs -> refs `shouldBe` []
            Failure _ -> error "expected Success"
            _ -> error "unexpected completion result"
