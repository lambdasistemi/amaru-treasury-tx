{- |
Module      : Amaru.Treasury.PParamsSpec
Description : Sanity test for the frozen pparams fixture
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.PParamsSpec (spec) where

import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldSatisfy
    )

import Amaru.Treasury.PParams (readPParamsFile)

{- | Drop the 'PParams' value into '()'. We don't assert specific
field values (the network bumps them every epoch); the regression
we care about is just that the Aeson decoder accepts the fixture.
-}
decoded :: a -> ()
decoded = const ()

spec :: Spec
spec = describe "Amaru.Treasury.PParams" $ do
    it "decodes the frozen mainnet fixture" $ do
        pp <- readPParamsFile "test/fixtures/pparams.json"
        decoded pp `shouldSatisfy` (== ())
