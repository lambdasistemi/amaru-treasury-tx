{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.SpaFallbackSpec
Description : Unit tests for SPA deep-link fallback middleware
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Api.SpaFallbackSpec (spec) where

import Control.Monad (forM_)
import Data.ByteString (ByteString)
import Data.ByteString.Lazy qualified as LBS
import Network.HTTP.Types (status200, status404)
import Network.Wai
    ( Application
    , pathInfo
    , responseLBS
    )
import Network.Wai.Test (runSession)
import Network.Wai.Test qualified as WaiTest
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    )

import Amaru.Treasury.Api.SpaFallback (spaFallback)

spec :: Spec
spec = describe "Amaru.Treasury.Api.SpaFallback" $
    describe "spaFallback" $ do
        it "serves the SPA bundle for every top-level SPA route" $
            forM_ spaRoutes $ \route -> do
                res <-
                    runSession
                        (WaiTest.srequest (waiGet route))
                        (spaFallback fakeStaticApp)
                WaiTest.simpleStatus res `shouldBe` status200
                WaiTest.simpleBody res `shouldBe` spaBundle

        it "leaves unknown paths as 404s" $ do
            res <-
                runSession
                    (WaiTest.srequest (waiGet "/unknown"))
                    (spaFallback fakeStaticApp)
            WaiTest.simpleStatus res `shouldBe` status404

spaRoutes :: [ByteString]
spaRoutes =
    [ "/operate"
    , "/view"
    , "/books"
    , "/audit"
    , "/pending"
    ]

fakeStaticApp :: Application
fakeStaticApp req respond
    | null (pathInfo req) =
        respond $
            responseLBS
                status200
                [("Content-Type", "text/html; charset=utf-8")]
                spaBundle
    | otherwise =
        respond $
            responseLBS
                status404
                [("Content-Type", "text/plain")]
                "not-found"

spaBundle :: LBS.ByteString
spaBundle = "<!doctype html><html><body>amaru-spa</body></html>"

waiGet :: ByteString -> WaiTest.SRequest
waiGet path =
    WaiTest.SRequest
        ( WaiTest.setPath
            WaiTest.defaultRequest
            path
        )
        ""
