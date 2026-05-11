module Amaru.Treasury.Build.ReportWriter
    ( ReportWriteError (..)
    , writeReportArtifact
    ) where

import Control.Exception (IOException, try)
import Control.Tracer (Tracer, traceWith)
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T

import Amaru.Treasury.Build.Trace
    ( BuildEvent (..)
    )

data ReportWriteError = ReportWriteError
    { reportWritePath :: !FilePath
    , reportWriteMessage :: !String
    }
    deriving stock (Eq, Show)

writeReportArtifact
    :: Tracer IO BuildEvent
    -> FilePath
    -> ByteString
    -> IO (Either ReportWriteError ())
writeReportArtifact tr path bytes = do
    result <- try (BSL.writeFile path bytes)
    case result of
        Right () -> do
            traceWith tr (BuildEventWroteReport path)
            pure (Right ())
        Left err -> do
            let message = displayReportWriteError path err
            traceWith tr (BuildEventReportWriteFailed path (T.pack message))
            pure (Left (ReportWriteError path message))

displayReportWriteError :: FilePath -> IOException -> String
displayReportWriteError path err =
    path <> ": " <> show err
