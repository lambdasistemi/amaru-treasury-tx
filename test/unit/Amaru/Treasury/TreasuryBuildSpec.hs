{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.TreasuryBuildSpec
Description : Unit tests for the unified build pipeline
License     : Apache-2.0

The probe-driven network mismatch detection lives in
'Amaru.Treasury.Backend.N2C.findSocketMagic'. The probe
function is injected so we can assert the candidate-walk
behaviour without spinning up a real Unix socket — that
end-to-end verification is the manual T032 integration
test recorded in the PR description.
-}
module Amaru.Treasury.TreasuryBuildSpec (spec) where

import Data.IORef
    ( modifyIORef'
    , newIORef
    , readIORef
    )
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

import Ouroboros.Network.Magic (NetworkMagic (..))

import Amaru.Treasury.Backend.N2C
    ( findSocketMagic
    , knownNetworkMagics
    )

spec :: Spec
spec = describe "Amaru.Treasury.TreasuryBuild" $ do
    describe "findSocketMagic" $ do
        it "returns the actual magic when the socket is on the wrong network" $ do
            -- Intent says mainnet; socket actually accepts preprod (1).
            let probe (NetworkMagic 1) = pure True
                probe _ = pure False
            r <- findSocketMagic probe "mainnet"
            r `shouldBe` 1

        it "returns 0 when no candidate magic is accepted" $ do
            let probe _ = pure False
            r <- findSocketMagic probe "mainnet"
            r `shouldBe` 0

        it "skips the intent's own network in the probe walk" $ do
            -- Track every magic we probe; assert mainnet is
            -- never asked (the intent already declares it).
            seenRef <- newIORef []
            let probe m = do
                    modifyIORef' seenRef (unNetworkMagic m :)
                    pure False
            _ <- findSocketMagic probe "mainnet"
            seen <- readIORef seenRef
            -- Order doesn't matter; just assert mainnet's
            -- magic (764824073) is not in the probe trail.
            (764_824_073 `elem` seen) `shouldBe` False

        it "stops at the first accepting probe" $ do
            -- Both preprod and preview accept; we should
            -- see only the first candidate hit (preprod).
            seenRef <- newIORef []
            let probe m = do
                    modifyIORef' seenRef (unNetworkMagic m :)
                    pure True
            r <- findSocketMagic probe "mainnet"
            seen <- readIORef seenRef
            length seen `shouldBe` 1
            r `shouldBe` 1

    describe "knownNetworkMagics" $ do
        it "lists the three production-relevant networks" $ do
            map fst knownNetworkMagics
                `shouldBe` ["mainnet", "preprod", "preview"]
        it "uses the canonical magic numbers" $ do
            lookup "mainnet" knownNetworkMagics
                `shouldBe` Just (NetworkMagic 764_824_073)
            lookup "preprod" knownNetworkMagics
                `shouldBe` Just (NetworkMagic 1)
            lookup "preview" knownNetworkMagics
                `shouldBe` Just (NetworkMagic 2)
