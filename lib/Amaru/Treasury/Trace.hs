{- |
Module      : Amaru.Treasury.Trace
Description : Shared trace severity and duration helpers
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Trace
    ( Severity (..)
    , severityAtLeast
    , filterSeverity
    , traced
    ) where

import Control.Exception
    ( SomeException
    , throwIO
    , try
    )
import Control.Monad (when)
import Control.Tracer
    ( Tracer (..)
    , traceWith
    )
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time.Clock
    ( UTCTime
    , diffUTCTime
    , getCurrentTime
    )

-- | Shared severity vocabulary, ordered from least to most severe.
data Severity
    = Debug
    | Info
    | Notice
    | Warning
    | Error
    deriving stock (Bounded, Enum, Eq, Ord, Show)

-- | Test whether an event severity passes a minimum-severity threshold.
severityAtLeast :: Severity -> Severity -> Bool
severityAtLeast minimumSeverity eventSeverity =
    eventSeverity >= minimumSeverity

-- | Drop trace events below the configured minimum severity.
filterSeverity
    :: Severity
    -> Tracer IO (Severity, Text)
    -> Tracer IO (Severity, Text)
filterSeverity minimumSeverity (Tracer emit) =
    Tracer $ \(severity, message) ->
        when (severityAtLeast minimumSeverity severity) $
            emit (severity, message)

{- | Trace the start and terminal result of an action, including
elapsed duration in milliseconds for terminal events.

Exceptions are logged with their rendered message and then rethrown.
-}
traced
    :: Tracer IO (Severity, Text) -> Severity -> Text -> IO a -> IO a
traced tr severity label action = do
    traceWith tr (severity, label <> " start")
    startedAt <- getCurrentTime
    result <- try action
    finishedAt <- getCurrentTime
    case result of
        Right value -> do
            traceWith
                tr
                ( severity
                , label <> " ok after " <> elapsedMs startedAt finishedAt
                )
            pure value
        Left (err :: SomeException) -> do
            traceWith
                tr
                ( severity
                , label
                    <> " failed after "
                    <> elapsedMs startedAt finishedAt
                    <> ": "
                    <> T.pack (show err)
                )
            throwIO err

elapsedMs :: UTCTime -> UTCTime -> Text
elapsedMs startedAt finishedAt =
    T.pack (show millis) <> " ms"
  where
    millis :: Integer
    millis =
        round
            ( realToFrac (diffUTCTime finishedAt startedAt)
                * (1000 :: Double)
            )
