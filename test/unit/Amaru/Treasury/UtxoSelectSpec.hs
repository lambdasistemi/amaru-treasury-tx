{- |
Module      : Amaru.Treasury.UtxoSelectSpec
Description : Property + unit tests for 'select'
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.UtxoSelectSpec (spec) where

import Data.Set qualified as Set
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
    ( Property
    , forAll
    , listOf1
    , (===)
    )
import Test.QuickCheck.Gen (Gen, choose)

import Amaru.Treasury.UtxoSelect
    ( Selection (..)
    , SelectionError (..)
    , select
    )

-- | Synthetic UTxO: @(id, qty)@.
type Utxo = (Int, Integer)

genPositiveUtxo :: Gen Utxo
genPositiveUtxo = do
    k <- choose (0 :: Int, 1000)
    q <- choose (1 :: Integer, 1_000_000)
    pure (k, q)

genUtxoList :: Gen [Utxo]
genUtxoList = listOf1 genPositiveUtxo

accumulatedAtLeastTarget :: [Utxo] -> Property
accumulatedAtLeastTarget xs =
    let target = (sum (map snd xs) `div` 2) + 1
    in  case select Set.empty id target xs of
            Right sel ->
                ( selAccumulated sel >= target
                    && selLeftover sel
                        == selAccumulated sel - target
                )
                    === True
            Left _ -> True === True

blacklistHonoured :: [Utxo] -> Property
blacklistHonoured xs = case xs of
    [] -> True === True
    ((kk, _) : _) ->
        let bl = Set.singleton kk
        in  case select bl id 1 xs of
                Right sel ->
                    (kk `notElem` map fst (selChosen sel)) === True
                Left _ -> True === True

spec :: Spec
spec = describe "Amaru.Treasury.UtxoSelect" $ do
    it "stops at the first UTxO that meets the target (3 ADA)" $ do
        let result =
                select
                    Set.empty
                    id
                    3_000_000
                    [(1 :: Int, 2_000_000), (2, 4_000_000), (3, 9_000_000)]
        fmap selChosen result
            `shouldBe` Right [(1, 2_000_000), (2, 4_000_000)]
        fmap selAccumulated result `shouldBe` Right 6_000_000
        fmap selLeftover result `shouldBe` Right 3_000_000

    it "skips blacklisted UTxOs" $ do
        let result =
                select
                    (Set.fromList [1])
                    id
                    3_000_000
                    [(1 :: Int, 9_000_000), (2, 4_000_000)]
        fmap selChosen result `shouldBe` Right [(2, 4_000_000)]
        fmap selAccumulated result `shouldBe` Right 4_000_000

    it "reports InsufficientFunds when the list is exhausted" $ do
        select Set.empty id 100 [(1 :: Int, 30), (2, 40)]
            `shouldBe` Left
                InsufficientFunds
                    { sefRequested = 100
                    , sefAvailable = 70
                    }

    it "returns an empty selection when the target is 0" $ do
        let result = select Set.empty id 0 [(1 :: Int, 5)]
        fmap selChosen result `shouldBe` Right []
        fmap selAccumulated result `shouldBe` Right 0
        fmap selLeftover result `shouldBe` Right 0

    prop "every accumulated total >= target on success" $
        forAll genUtxoList accumulatedAtLeastTarget

    prop "blacklist is honoured for any subset" $
        forAll genUtxoList blacklistHonoured

    it "returns InsufficientFunds with sefAvailable matching skipped sum" $ do
        let res =
                select
                    (Set.fromList [9 :: Int])
                    id
                    1000
                    [(1, 100), (9, 999_999), (2, 200)]
        res `shouldSatisfy` \case
            Left InsufficientFunds{sefAvailable = 300} -> True
            _ -> False
