{- |
Module      : Amaru.Treasury.Backend.N2CSpec
Description : Tests for the supervised N2C connection
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The long-lived N2C session behind the API's 'Provider' must
survive the node going away. On 2026-09-19 the mainnet node
restarted, the connection thread ended, and nothing restarted
it: every later query waited on a channel nobody served (#508).
-}
module Amaru.Treasury.Backend.N2CSpec (spec) where

import Control.Concurrent.Async
    ( AsyncCancelled (..)
    )
import Control.Exception
    ( Exception
    , SomeException
    , fromException
    , throwIO
    , toException
    , try
    )
import Control.Monad (when)
import Data.IORef
    ( atomicModifyIORef'
    , modifyIORef'
    , newIORef
    , readIORef
    )
import System.Timeout (timeout)
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Backend.N2C
    ( reconnectInitialDelay
    , reconnectMaxDelay
    , superviseConnection
    )

-- | Thrown by the fake sleep to end the otherwise endless loop.
data Stop = Stop
    deriving stock (Show, Eq)

instance Exception Stop

{- | Run 'superviseConnection' over a scripted sequence of
connection outcomes. Each attempt advances the fake clock by
the scripted duration. The fake sleep records its delay and
stops the loop once every scripted attempt has run.
Returns the number of attempts and the recorded delays.
-}
runScript
    :: [(Double, IO (Either SomeException ()))]
    -> IO (Either Stop (), Int, [Int])
runScript script = do
    remaining <- newIORef script
    attempts <- newIORef (0 :: Int)
    delays <- newIORef []
    now <- newIORef (0 :: Double)
    let connectOnce = do
            modifyIORef' attempts (+ 1)
            next <- atomicModifyIORef' remaining $ \case
                [] -> ([], Nothing)
                (x : xs) -> (xs, Just x)
            case next of
                Nothing -> throwIO Stop
                Just (lasted, outcome) -> do
                    modifyIORef' now (+ lasted)
                    outcome
        sleep d = do
            modifyIORef' delays (d :)
            left <- readIORef remaining
            when (null left) $ throwIO Stop
    r <-
        timeout 5_000_000 $
            try $
                superviseConnection
                    (readIORef now)
                    sleep
                    (const $ pure ())
                    connectOnce
    n <- readIORef attempts
    ds <- reverse <$> readIORef delays
    case r of
        Nothing -> do
            expectationFailure $
                "connection not re-run after "
                    <> show n
                    <> " attempt(s)"
            pure (Right (), n, ds)
        Just outcome -> pure (outcome, n, ds)

failed :: IO (Either SomeException ())
failed = pure $ Left $ toException $ userError "bearer closed"

closed :: IO (Either SomeException ())
closed = pure $ Right ()

thrown :: IO (Either SomeException ())
thrown = throwIO $ userError "socket does not exist"

spec :: Spec
spec = describe "superviseConnection" $ do
    it "re-runs the connection however it ends" $ do
        (r, n, _) <- runScript [(0, failed), (0, closed), (0, thrown)]
        r `shouldBe` Left Stop
        n `shouldBe` 3

    it "backs off exponentially while the node stays away" $ do
        (_, _, ds) <- runScript [(0, failed), (0, failed), (0, failed)]
        ds
            `shouldBe` [ reconnectInitialDelay
                       , 2 * reconnectInitialDelay
                       , 4 * reconnectInitialDelay
                       ]

    it "caps the backoff" $ do
        (_, _, ds) <- runScript (replicate 20 (0, failed))
        maximum ds `shouldBe` reconnectMaxDelay
        last ds `shouldBe` reconnectMaxDelay

    it "resets the backoff after a long-lived connection" $ do
        (_, _, ds) <-
            runScript [(0, failed), (0, failed), (3600, failed)]
        ds
            `shouldBe` [ reconnectInitialDelay
                       , 2 * reconnectInitialDelay
                       , reconnectInitialDelay
                       ]

    -- A reconnect after cancellation reaches the fake sleep,
    -- which stops the loop with 'Stop' so the test fails
    -- rather than spinning.
    it "lets cancellation through instead of reconnecting" $ do
        r <-
            try @SomeException $
                superviseConnection @()
                    (pure 0)
                    (const $ throwIO Stop)
                    (const $ pure ())
                    (throwIO AsyncCancelled)
        case r of
            Left e -> fromException e `shouldBe` Just AsyncCancelled
            Right () -> expectationFailure "supervisor returned"
