{- |
Module      : Amaru.Treasury.TraceSpec
Description : Tests for shared trace severity helpers
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.TraceSpec (spec) where

import Control.Exception
    ( SomeException
    , throwIO
    , try
    )
import Control.Tracer (Tracer (..))
import Data.IORef
    ( atomicModifyIORef'
    , newIORef
    , readIORef
    )
import Data.Text (Text)
import Data.Text qualified as T
import Test.Hspec
    ( Spec
    , describe
    , it
    , shouldBe
    , shouldSatisfy
    )

import Amaru.Treasury.Trace
    ( Severity (..)
    , filterSeverity
    , parseSeverityText
    , renderSeverityText
    , severityAtLeast
    , traced
    )

collectTracer
    :: IO (Tracer IO (Severity, Text), IO [(Severity, Text)])
collectTracer = do
    ref <- newIORef []
    let tr =
            Tracer $ \event ->
                atomicModifyIORef' ref $ \events ->
                    (event : events, ())
    pure (tr, reverse <$> readIORef ref)

messages :: [(Severity, Text)] -> [Text]
messages = fmap snd

spec :: Spec
spec = describe "Amaru.Treasury.Trace" $ do
    it "orders severities from Debug through Error" $
        [Debug, Info, Notice, Warning, Error]
            `shouldBe` [minBound .. maxBound]

    describe "severity text" $ do
        it "parses supported log levels" $
            traverse
                parseSeverityText
                ["debug", "info", "notice", "warning", "error"]
                `shouldBe` Right
                    [Debug, Info, Notice, Warning, Error]

        it "renders supported log levels" $
            fmap renderSeverityText [Debug, Info, Notice, Warning, Error]
                `shouldBe` ["debug", "info", "notice", "warning", "error"]

        it "rejects unknown log levels" $
            parseSeverityText "trace"
                `shouldBe` Left
                    "unknown log level: trace (expected debug|info|notice|warning|error)"

    describe "severityAtLeast" $ do
        it "keeps severities greater than or equal to the minimum" $ do
            severityAtLeast Notice Debug `shouldBe` False
            severityAtLeast Notice Info `shouldBe` False
            severityAtLeast Notice Notice `shouldBe` True
            severityAtLeast Notice Warning `shouldBe` True
            severityAtLeast Notice Error `shouldBe` True

    describe "filterSeverity" $ do
        it "drops events below the configured minimum severity" $ do
            (tr, readEvents) <- collectTracer
            let filtered = filterSeverity Warning tr
            case filtered of
                Tracer emit -> do
                    emit (Debug, "debug")
                    emit (Info, "quiet")
                    emit (Notice, "notice")
                    emit (Warning, "kept")
                    emit (Error, "also kept")
            events <- readEvents
            events
                `shouldBe` [(Warning, "kept"), (Error, "also kept")]

    describe "traced" $ do
        it "emits start and ok events with a duration" $ do
            (tr, readEvents) <- collectTracer
            result <- traced tr Info "build" (pure (42 :: Int))
            result `shouldBe` 42
            events <- readEvents
            fmap fst events `shouldBe` [Info, Info]
            messages events
                `shouldSatisfy` \case
                    [start, ok] ->
                        "build" `T.isInfixOf` start
                            && "start" `T.isInfixOf` start
                            && "build" `T.isInfixOf` ok
                            && "ok" `T.isInfixOf` ok
                            && "ms" `T.isInfixOf` ok
                    _ -> False

        it "logs failures with duration and rethrows the exception" $ do
            (tr, readEvents) <- collectTracer
            result <-
                try @SomeException
                    ( traced
                        tr
                        Warning
                        "submit"
                        (throwIO (userError "socket unavailable") :: IO ())
                    )
            result `shouldSatisfy` \case
                Left err ->
                    "socket unavailable" `T.isInfixOf` T.pack (show err)
                Right () -> False
            events <- readEvents
            fmap fst events `shouldBe` [Warning, Warning]
            messages events
                `shouldSatisfy` \case
                    [start, failed] ->
                        "submit" `T.isInfixOf` start
                            && "start" `T.isInfixOf` start
                            && "submit" `T.isInfixOf` failed
                            && "failed" `T.isInfixOf` failed
                            && "socket unavailable" `T.isInfixOf` failed
                            && "ms" `T.isInfixOf` failed
                    _ -> False
