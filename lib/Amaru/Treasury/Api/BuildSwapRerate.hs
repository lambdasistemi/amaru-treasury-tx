{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.Api.BuildSwapRerate
Description : JSON carriers for @POST /v1/build/swap-rerate@
              (#401).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Shallow HTTP request and response types for the swap re-rate
build endpoint.  The runner is an API adapter around the
existing @swap-rerate@ CLI path: it validates wire-shape
inputs, delegates planning/building to
'Amaru.Treasury.Cli.SwapRerate.runSwapRerate', then translates
the generated CBOR/report artifacts back into a structured
HTTP response.
-}
module Amaru.Treasury.Api.BuildSwapRerate
    ( -- * Request
      SwapRerateBuildRequest (..)

      -- * Response
    , SwapRerateBuildResponse (..)

      -- * Handler runner
    , runBuildSwapRerate
    ) where

import Control.Exception (SomeException, try)
import Data.Aeson
    ( FromJSON
    , ToJSON
    , eitherDecodeStrict'
    , withObject
    , (.:)
    , (.:?)
    )
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as BS
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as TIO
import GHC.Generics (Generic)
import System.Directory (doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (stderr)
import System.IO.Temp (withSystemTempDirectory)

import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Cli.Common (GlobalOpts)
import Amaru.Treasury.Cli.SwapRerate
    ( SwapRerateOpts (..)
    , SwapRerateSelectionMode (..)
    , runSwapRerate
    )
import Amaru.Treasury.Scope (ScopeId)
import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind (..)
    , encodeEnvelope
    )

-- ---------------------------------------------------------------------------
-- Request

{- | Operator-supplied swap re-rate inputs over HTTP.

The selected order and wallet inputs are plain @txid#index@
texts in this slice.  The later runner slice is responsible
for parsing them into the pure re-rate core's input types and
returning typed input failures.
-}
data SwapRerateBuildRequest = SwapRerateBuildRequest
    { srrScope :: ScopeId
    , srrSelectedOrders :: [Text]
    , srrNewRate :: Double
    , srrWalletTxIn :: Text
    , srrCollateralTxIn :: Maybe Text
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Response

{- | Shape of @POST /v1/build/swap-rerate@ response for the
route-and-stub slice.

Exactly one high-level outcome should be present.  Until the
real runner lands, the production runner returns the typed
failure arm while tests can still prove that the route decodes
a request and returns the handler's typed response.
-}
data SwapRerateBuildResponse = SwapRerateBuildResponse
    { srrCborHex :: Maybe Text
    -- ^ Hex-encoded unsigned Conway tx body on success.
    , srrCborEnvelope :: Maybe Text
    -- ^ Cardano CLI text-envelope JSON for the unsigned body.
    , srrReport :: Maybe Text
    -- ^ Pretty-printed build report on success.
    , srrDecision :: Maybe Text
    -- ^ Machine-readable decision, e.g. @single_tx@ or @split@.
    , srrReason :: Maybe Text
    -- ^ Planner/report reason for non-failure decisions.
    , srrFailureTag :: Maybe Text
    -- ^ Stable typed failure tag.
    , srrFailureReason :: Maybe Text
    -- ^ Human-readable diagnostic for the failure tag.
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Handler runner

-- | Service-side runner used by the @amaru-treasury-tx-api@ binary.
runBuildSwapRerate
    :: GlobalOpts
    -> FilePath
    -- ^ Server-configured metadata path.
    -> Backend
    -> SwapRerateBuildRequest
    -> IO SwapRerateBuildResponse
runBuildSwapRerate g serverMetadataPath _backend req@SwapRerateBuildRequest{..} = do
    TIO.hPutStrLn
        stderr
        ( "amaru-treasury-tx-api: POST /v1/build/swap-rerate scope="
            <> T.pack (show srrScope)
        )
    case validateRequest req of
        Just failure -> pure failure
        Nothing ->
            withSystemTempDirectory "amaru-build-swap-rerate" $
                \dir -> do
                    let cborPath = dir </> "swap-rerate.cbor.hex"
                        reportPath = dir </> "swap-rerate.report.json"
                        opts =
                            toSwapRerateOpts
                                serverMetadataPath
                                cborPath
                                reportPath
                                req
                    result <-
                        try @SomeException $
                            try @ExitCode (runSwapRerate g opts)
                    case result of
                        Left e ->
                            pure $
                                failureResponse
                                    "BuildSwapRerateException"
                                    ( "uncaught exception: "
                                        <> T.pack (show e)
                                    )
                        Right (Left exitCode) ->
                            responseFromReport
                                cborPath
                                reportPath
                                (Just exitCode)
                        Right (Right ()) ->
                            responseFromReport cborPath reportPath Nothing

validateRequest
    :: SwapRerateBuildRequest -> Maybe SwapRerateBuildResponse
validateRequest SwapRerateBuildRequest{..}
    | null srrSelectedOrders =
        Just $
            failureResponse
                "InputInvalid"
                "selectedOrders: at least one selected order is required"
    | isNaN srrNewRate || srrNewRate <= 0 =
        Just $
            failureResponse
                "InputOutOfRange"
                ("newRate: rate must be positive, got " <> T.pack (show srrNewRate))
    | otherwise = Nothing

toSwapRerateOpts
    :: FilePath
    -> FilePath
    -> FilePath
    -> SwapRerateBuildRequest
    -> SwapRerateOpts
toSwapRerateOpts metadataPath cborPath reportPath SwapRerateBuildRequest{..} =
    SwapRerateOpts
        { sroMetadataPath = metadataPath
        , sroScope = srrScope
        , sroWalletTxIn = srrWalletTxIn
        , sroCollateralTxIn = srrCollateralTxIn
        , sroSelectionMode = SwapRerateSelectExplicit srrSelectedOrders
        , sroNewRate = srrNewRate
        , sroValidityHours = Nothing
        , sroOutPath = Just cborPath
        , sroReportPath = Just reportPath
        , sroLog = Nothing
        }

data ReportSummary = ReportSummary
    { rsStatus :: !Text
    , rsReason :: !(Maybe Text)
    , rsCode :: !(Maybe Text)
    , rsMessage :: !(Maybe Text)
    }

responseFromReport
    :: FilePath
    -> FilePath
    -> Maybe ExitCode
    -> IO SwapRerateBuildResponse
responseFromReport cborPath reportPath exitCode = do
    reportExists <- doesFileExist reportPath
    if reportExists
        then do
            rawReport <- BS.readFile reportPath
            case parseReportSummary rawReport of
                Left err ->
                    pure $
                        failureResponse
                            "BuildSwapRerateReportInvalid"
                            err
                Right summary ->
                    responseFromSummary
                        cborPath
                        (Text.decodeUtf8 rawReport)
                        exitCode
                        summary
        else
            pure $
                failureResponse
                    "BuildSwapRerateNoReport"
                    ( case exitCode of
                        Just code ->
                            "swap-rerate exited without a report: "
                                <> T.pack (show code)
                        Nothing ->
                            "swap-rerate completed without a report"
                    )

parseReportSummary :: BS.ByteString -> Either Text ReportSummary
parseReportSummary raw = do
    value <-
        case eitherDecodeStrict' raw of
            Left err -> Left ("invalid report JSON: " <> T.pack err)
            Right ok -> Right ok
    case parseEither parseSummary value of
        Left err -> Left ("invalid report shape: " <> T.pack err)
        Right ok -> Right ok
  where
    parseSummary =
        withObject "swap-rerate report" $ \o ->
            ReportSummary
                <$> o .: "status"
                <*> o .:? "reason"
                <*> o .:? "code"
                <*> o .:? "message"

responseFromSummary
    :: FilePath
    -> Text
    -> Maybe ExitCode
    -> ReportSummary
    -> IO SwapRerateBuildResponse
responseFromSummary cborPath reportText exitCode ReportSummary{..} =
    case rsStatus of
        "single_tx" -> singleTxResponse cborPath reportText rsReason
        "split" ->
            pure $
                successResponse
                    { srrReport = Just reportText
                    , srrDecision = Just "split"
                    , srrReason = rsReason
                    }
        "rejected" ->
            pure $
                failureResponse
                    (fromMaybe "BuildSwapRerateRejected" rsCode)
                    (fromMaybe (exitReason exitCode) rsMessage)
        "passthrough" ->
            pure $
                successResponse
                    { srrReport = Just reportText
                    , srrDecision = Just "passthrough"
                    , srrReason = rsReason
                    }
        other ->
            pure $
                failureResponse
                    "BuildSwapRerateUnknownStatus"
                    ("unexpected report status: " <> other)

singleTxResponse
    :: FilePath -> Text -> Maybe Text -> IO SwapRerateBuildResponse
singleTxResponse cborPath reportText reason = do
    cborExists <- doesFileExist cborPath
    if cborExists
        then do
            cborBytes <- BS.readFile cborPath
            let cborText = Text.decodeUtf8 cborBytes
                envelope =
                    Text.decodeUtf8 $
                        encodeEnvelope Tx cborBytes
            pure
                successResponse
                    { srrCborHex = Just cborText
                    , srrCborEnvelope = Just envelope
                    , srrReport = Just reportText
                    , srrDecision = Just "single_tx"
                    , srrReason = reason
                    }
        else
            pure $
                failureResponse
                    "BuildSwapRerateNoCbor"
                    "single_tx report was produced without CBOR"

exitReason :: Maybe ExitCode -> Text
exitReason = \case
    Just code -> "swap-rerate exited: " <> T.pack (show code)
    Nothing -> "swap-rerate rejected the request"

successResponse :: SwapRerateBuildResponse
successResponse =
    SwapRerateBuildResponse
        { srrCborHex = Nothing
        , srrCborEnvelope = Nothing
        , srrReport = Nothing
        , srrDecision = Nothing
        , srrReason = Nothing
        , srrFailureTag = Nothing
        , srrFailureReason = Nothing
        }

failureResponse :: Text -> Text -> SwapRerateBuildResponse
failureResponse tag reason =
    SwapRerateBuildResponse
        { srrCborHex = Nothing
        , srrCborEnvelope = Nothing
        , srrReport = Nothing
        , srrDecision = Nothing
        , srrReason = Nothing
        , srrFailureTag = Just tag
        , srrFailureReason = Just reason
        }
