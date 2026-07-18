{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.InspectorSpec
Description : Pins the co-signer pointer URLs + copy
License     : Apache-2.0
-}
module Amaru.Treasury.InspectorSpec (spec) where

import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldContain
    , shouldSatisfy
    )

import Amaru.Treasury.Inspector
    ( bookInvitation
    , coSignerPointerLines
    , cskLibraryUrl
    , inspectInvitation
    , inspectorUrl
    , publishedBookUrl
    )

spec :: Spec
spec = describe "Amaru.Treasury.Inspector" $ do
    it "pins the Cardano Swiss Knife inspector URL" $
        inspectorUrl
            `shouldBe` "https://lambdasistemi.github.io/cardano-swiss-knife/"

    it "pins the published treasury book URL" $
        publishedBookUrl
            `shouldBe` "https://lambdasistemi.github.io/amaru-treasury-tx\
                       \/assets/amaru-treasury-book.ttl"

    it "pins the inspector Library URL" $
        cskLibraryUrl
            `shouldBe` "https://lambdasistemi.github.io/cardano-swiss-knife\
                       \/library/"

    it "invites independent inspection and book import" $ do
        inspectInvitation `shouldSatisfy` T.isInfixOf "independently"
        bookInvitation `shouldSatisfy` T.isInfixOf "identities to names"

    it "carries both URLs in the stderr pointer block" $ do
        let block = T.unlines coSignerPointerLines
        block `shouldContainText` inspectorUrl
        block `shouldContainText` publishedBookUrl
  where
    shouldContainText haystack needle =
        T.unpack haystack `shouldContain` T.unpack (needle :: Text)
