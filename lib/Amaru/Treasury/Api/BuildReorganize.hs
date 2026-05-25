{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

{- |
Module      : Amaru.Treasury.Api.BuildReorganize
Description : JSON carriers + mapper for @POST /v1/build/reorganize@
              (#280).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Sister of 'Amaru.Treasury.Api.BuildSwap' and
'Amaru.Treasury.Api.BuildDisburse' for the reorganize-wizard
subcommand.  A shallow request type with primitive fields
the operator supplies; the mapper translates to
'ReorganizeWizardOpts' before the handler calls
'Amaru.Treasury.Wizard.Reorganize.buildReorganizeIntent' and
then 'buildReorganizeTx'.

Keeping the JSON shape distinct from 'ReorganizeWizardOpts'
avoids chaining @ToJSON@ / @FromJSON@ instances across the
wizard internals; the HTTP wire contract evolves
independently from the in-process record.
-}
module Amaru.Treasury.Api.BuildReorganize
    ( -- * Request
      ReorganizeBuildRequest (..)

      -- * Response
    , ReorganizeBuildResponse (..)

      -- * Mapper
    , mapToReorganizeWizardOpts

      -- * Handler runner
    , runBuildReorganize
    ) where

import Control.Exception (SomeException, try)
import Control.Tracer (Tracer (..))
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as TIO
import Data.Word (Word16)
import GHC.Generics (Generic)
import System.IO (stderr)

import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Build.Trace (renderBuildEvent)
import Amaru.Treasury.Cli.Common (GlobalOpts)
import Amaru.Treasury.Cli.ReorganizeWizard
    ( CommonFlags (..)
    , ReorganizeWizardOpts (..)
    )
import Amaru.Treasury.IntentJSON
    ( encodeSomeTreasuryIntent
    )
import Amaru.Treasury.Report
    ( TxBuildSuccess (..)
    , TxCborHex (..)
    )
import Amaru.Treasury.Scope (ScopeId)
import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind (..)
    , encodeEnvelope
    )
import Amaru.Treasury.Tx.ReorganizeWizard.Trace
    ( renderReorganizeWizardEvent
    )
import Amaru.Treasury.Wizard.Failure
    ( BuildFailure (..)
    , FieldId (..)
    , WizardFailure (..)
    , fieldOf
    , fieldOfBuild
    , renderBuildFailure
    , renderWizardFailure
    )
import Amaru.Treasury.Wizard.InputControl
    ( ExclusionSet (..)
    , ForcedInclusionSet (..)
    )
import Amaru.Treasury.Wizard.Reorganize
    ( buildReorganizeIntent
    , buildReorganizeTx
    )

-- ---------------------------------------------------------------------------
-- Request

{- | Operator-supplied reorganize inputs over HTTP.

Matches 'ReorganizeWizardOpts' field-by-field for the
operator-supplied flags only; chain- and registry-derived
fields (treasury address, scope-owner key hash, deployed-at
references, permissions reward account) are resolved by the
wizard itself from @--metadata@ and the live N2C backend.

Exclude / extra-tx-in lists and the optional
@--funding-seed-txin@ override are intentionally NOT on the
wire here (matches the swap- and disburse-side PR-A scope);
the wire shape can grow those fields in a later slice if the
dashboard ever needs to surface them.  Until then the
resolver auto-picks the wallet UTxO.
-}
data ReorganizeBuildRequest = ReorganizeBuildRequest
    { rbrScope :: ScopeId
    , rbrWalletAddr :: Text
    , rbrMetadataPath :: FilePath
    , rbrValidityHours :: Maybe Word16
    , rbrDescription :: Maybe Text
    , rbrJustification :: Maybe Text
    , rbrDestinationLabel :: Maybe Text
    , rbrEvent :: Maybe Text
    , rbrLabel :: Maybe Text
    , rbrSplitNativeAssets :: Maybe Bool
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Response

{- | Shape of @POST /v1/build/reorganize@ response.  On
success the body carries the encoded intent.json plus a
copy-pasteable CLI invocation; on failure it carries the
typed 'WizardFailure' / 'BuildFailure' tag.  Same four-arm
shape as 'Amaru.Treasury.Api.BuildSwap.SwapBuildResponse'
and 'Amaru.Treasury.Api.BuildDisburse.DisburseBuildResponse'.
-}
data ReorganizeBuildResponse = ReorganizeBuildResponse
    { rbrIntentJson :: Maybe Text
    -- ^ Pretty-printed @intent.json@ on success.
    , rbrCli :: Maybe Text
    -- ^ Equivalent CLI invocation on success.
    , rbrCborHex :: Maybe Text
    -- ^ Hex-encoded unsigned Conway tx body, present iff
    --   intent assembly AND tx build both succeeded.
    , rbrCborEnvelope :: Maybe Text
    -- ^ Same body wrapped in the cardano-cli text-envelope
    --   JSON so an operator can pipe it straight into
    --   @cardano-cli transaction witness@.
    , rbrReport :: Maybe Text
    -- ^ Pretty-printed @report.json@, present iff tx
    --   build succeeded.
    , rbrFailureTag :: Maybe Text
    -- ^ Constructor name of the 'WizardFailure' on
    --   intent-assembly failure.
    , rbrFailureField :: Maybe FieldId
    -- ^ The offending field on @Input*@ failures.
    , rbrFailureReason :: Maybe Text
    -- ^ Human-readable diagnostic on failure
    --   ('renderWizardFailure' / 'renderBuildFailure' output).
    , rbrBuildFailureTag :: Maybe Text
    -- ^ Constructor name of the 'BuildFailure' on tx-build
    --   failure; 'Nothing' if intent assembly failed OR
    --   build succeeded.
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Mapper

{- | Translate a wire-shape 'ReorganizeBuildRequest' into
the in-process 'ReorganizeWizardOpts' that
'buildReorganizeIntent' consumes.

The reorganize wire shape carries no fields whose
translation can fail standalone — every operator input
either maps trivially or is a JSON-decoded primitive the
servant layer already validated.  The mapper is therefore
total in @ReorganizeBuildRequest@; downstream validation
(bech32, scope membership in metadata, wallet shortfall,
…) lives in 'buildReorganizeIntent' itself.

The CLI-shell-only fields ('cfOut', 'cfLog', 'cfForce',
'rwoFundingSeedTxIn') are set to inert defaults: the HTTP
caller never writes a file, never opens a log, and the
wizard auto-picks the wallet seed UTxO.
-}
mapToReorganizeWizardOpts
    :: ReorganizeBuildRequest
    -> Either WizardFailure ReorganizeWizardOpts
mapToReorganizeWizardOpts ReorganizeBuildRequest{..} =
    Right
        ReorganizeWizardOpts
            { rwoCommon =
                CommonFlags
                    { cfWalletAddr = rbrWalletAddr
                    , cfMetadataPath = rbrMetadataPath
                    , cfOut = ""
                    , cfLog = Nothing
                    , cfScope = rbrScope
                    , cfValidityHours = rbrValidityHours
                    , cfDescription = rbrDescription
                    , cfJustification = rbrJustification
                    , cfDestinationLabel = rbrDestinationLabel
                    , cfEvent = rbrEvent
                    , cfLabel = rbrLabel
                    , cfForce = False
                    , cfExcludeSet = ExclusionSet []
                    , cfForcedSet = ForcedInclusionSet []
                    }
            , rwoFundingSeedTxIn = Nothing
            , rwoSplitNativeAssets = rbrSplitNativeAssets == Just True
            }

-- ---------------------------------------------------------------------------
-- Handler runner

{- | Service-side runner used by the @amaru-treasury-tx-api@
binary.  Maps the wire-shape request to
'ReorganizeWizardOpts', calls 'buildReorganizeIntent' against
the caller-owned long-lived 'Backend', and on success calls
'buildReorganizeTx' against the same backend to populate the
CBOR + report fields of the response.

Failures (whether from the mapper or from
'buildReorganizeIntent' / 'buildReorganizeTx') are carried as
the @failure*@ fields of the response; the HTTP handler
returns a 200 with those fields populated.
-}
runBuildReorganize
    :: GlobalOpts
    -> Backend
    -> ReorganizeBuildRequest
    -> IO ReorganizeBuildResponse
runBuildReorganize g backend req = do
    TIO.hPutStrLn
        stderr
        ( "amaru-treasury-tx-api: POST /v1/build/reorganize scope="
            <> T.pack (show (rbrScope req))
        )
    case mapToReorganizeWizardOpts req of
        Left wf -> do
            TIO.hPutStrLn
                stderr
                ( "amaru-treasury-tx-api: build/reorganize mapper Left: "
                    <> renderWizardFailure wf
                )
            pure (failureResponse wf)
        Right opts -> do
            let tr =
                    Tracer
                        ( TIO.hPutStrLn stderr
                            . ("amaru-treasury-tx-api: " <>)
                            . renderReorganizeWizardEvent
                        )
            r <-
                try @SomeException
                    (buildReorganizeIntent g opts backend tr)
            case r of
                Left e -> do
                    TIO.hPutStrLn
                        stderr
                        ( "amaru-treasury-tx-api: build/reorganize exception: "
                            <> T.pack (show e)
                        )
                    pure
                        ( failureResponse
                            ( ResolveResolver
                                ( "uncaught exception: "
                                    <> T.pack (show e)
                                )
                            )
                        )
                Right (Left wf) -> do
                    TIO.hPutStrLn
                        stderr
                        ( "amaru-treasury-tx-api: build/reorganize typed Left: "
                            <> renderWizardFailure wf
                        )
                    pure (failureResponse wf)
                Right (Right someIntent) -> do
                    TIO.hPutStrLn
                        stderr
                        "amaru-treasury-tx-api: build/reorganize intent OK"
                    let intentJson =
                            Text.decodeUtf8
                                ( BSL.toStrict
                                    ( encodeSomeTreasuryIntent
                                        someIntent
                                    )
                                )
                        intentOnly =
                            ReorganizeBuildResponse
                                { rbrIntentJson = Just intentJson
                                , rbrCli = Just (renderCli req)
                                , rbrCborHex = Nothing
                                , rbrCborEnvelope = Nothing
                                , rbrReport = Nothing
                                , rbrFailureTag = Nothing
                                , rbrFailureField = Nothing
                                , rbrFailureReason = Nothing
                                , rbrBuildFailureTag = Nothing
                                }
                    let trB =
                            Tracer
                                ( TIO.hPutStrLn stderr
                                    . ( "amaru-treasury-tx-api: "
                                            <>
                                      )
                                    . renderBuildEvent
                                )
                    rb <-
                        try @SomeException
                            ( buildReorganizeTx
                                g
                                backend
                                someIntent
                                trB
                            )
                    case rb of
                        Left e -> do
                            TIO.hPutStrLn
                                stderr
                                ( "amaru-treasury-tx-api: build/reorganize tx exception: "
                                    <> T.pack (show e)
                                )
                            pure
                                intentOnly
                                    { rbrBuildFailureTag =
                                        Just "BuildInternalError"
                                    , rbrFailureReason =
                                        Just
                                            ( "uncaught build exception: "
                                                <> T.pack (show e)
                                            )
                                    }
                        Right (Left bf) -> do
                            TIO.hPutStrLn
                                stderr
                                ( "amaru-treasury-tx-api: build/reorganize tx typed Left: "
                                    <> renderBuildFailure bf
                                )
                            pure
                                intentOnly
                                    { rbrBuildFailureTag =
                                        Just (buildFailureTag bf)
                                    , rbrFailureField = fieldOfBuild bf
                                    , rbrFailureReason =
                                        Just (renderBuildFailure bf)
                                    }
                        Right (Right tbs) -> do
                            TIO.hPutStrLn
                                stderr
                                "amaru-treasury-tx-api: build/reorganize tx OK"
                            let bareHex =
                                    unTxCborHex (tbsTxCbor tbs)
                                envelopeBytes =
                                    encodeEnvelope
                                        Tx
                                        (Text.encodeUtf8 bareHex)
                            pure
                                intentOnly
                                    { rbrCborHex = Just bareHex
                                    , rbrCborEnvelope =
                                        Just
                                            ( Text.decodeUtf8
                                                envelopeBytes
                                            )
                                    , rbrReport =
                                        Just
                                            ( Text.decodeUtf8
                                                ( BSL.toStrict
                                                    ( Aeson.encode
                                                        ( tbsReport
                                                            tbs
                                                        )
                                                    )
                                                )
                                            )
                                    }
  where
    failureResponse :: WizardFailure -> ReorganizeBuildResponse
    failureResponse wf =
        ReorganizeBuildResponse
            { rbrIntentJson = Nothing
            , rbrCli = Nothing
            , rbrCborHex = Nothing
            , rbrCborEnvelope = Nothing
            , rbrReport = Nothing
            , rbrFailureTag = Just (failureTag wf)
            , rbrFailureField = fieldOf wf
            , rbrFailureReason = Just (renderWizardFailure wf)
            , rbrBuildFailureTag = Nothing
            }

{- | Constructor tag of a 'WizardFailure' as a stable
string — wire counterpart of the same-named helpers in
'Amaru.Treasury.Api.BuildSwap' and
'Amaru.Treasury.Api.BuildDisburse'.  Duplicated here so the
reorganize module is self-contained; a later slice may
extract the three into a shared helper module.
-}
failureTag :: WizardFailure -> Text
failureTag = \case
    InputInvalid{} -> "InputInvalid"
    InputOutOfRange{} -> "InputOutOfRange"
    InputControl{} -> "InputControl"
    InputScopeUnsupported{} -> "InputScopeUnsupported"
    ResolveNetworkUnsupported{} -> "ResolveNetworkUnsupported"
    ResolveSwapParameters{} -> "ResolveSwapParameters"
    ResolveRegistryVerify{} -> "ResolveRegistryVerify"
    ResolveResolver{} -> "ResolveResolver"
    ResolveValidityHorizon{} -> "ResolveValidityHorizon"
    InternalTranslate{} -> "InternalTranslate"
    InternalEncodeError{} -> "InternalEncodeError"

{- | Constructor tag of a 'BuildFailure' as a stable
string — wire counterpart of the same-named helpers in
'Amaru.Treasury.Api.BuildSwap' and
'Amaru.Treasury.Api.BuildDisburse'.
-}
buildFailureTag :: BuildFailure -> Text
buildFailureTag = \case
    BuildInputInvalid{} -> "BuildInputInvalid"
    BuildResolveParams{} -> "BuildResolveParams"
    BuildResolveTip{} -> "BuildResolveTip"
    BuildResolveUtxo{} -> "BuildResolveUtxo"
    BuildBuildError{} -> "BuildBuildError"
    BuildInternalError{} -> "BuildInternalError"

{- | Render the equivalent
@amaru-treasury-tx reorganize-wizard@ CLI invocation for a
request.  Convenience for operators who want to reproduce
the build locally.

@--out@ and @--network@ are intentionally omitted (the
operator's local invocation supplies them); the rendered
line is otherwise byte-equivalent to the disburse-side
'renderCli'.
-}
renderCli :: ReorganizeBuildRequest -> Text
renderCli ReorganizeBuildRequest{..} =
    T.intercalate
        " \\\n  "
        ( "amaru-treasury-tx reorganize-wizard"
            : ("--scope " <> T.pack (show rbrScope))
            : ("--wallet-addr " <> rbrWalletAddr)
            : ("--metadata " <> T.pack rbrMetadataPath)
            : validityArgs rbrValidityHours
                <> maybeQuotedArg
                    "--description "
                    rbrDescription
                <> maybeQuotedArg
                    "--justification "
                    rbrJustification
                <> maybeQuotedArg
                    "--destination-label "
                    rbrDestinationLabel
                <> maybeArg "--event " rbrEvent
                <> maybeArg "--label " rbrLabel
                <> boolArg
                    "--split-native-assets"
                    rbrSplitNativeAssets
        )
  where
    validityArgs Nothing = []
    validityArgs (Just h) = ["--validity-hours " <> T.pack (show h)]

    maybeArg _ Nothing = []
    maybeArg flagP (Just v) = [flagP <> v]

    maybeQuotedArg _ Nothing = []
    maybeQuotedArg flagP (Just v) = [flagP <> quote v]

    quote t = "\"" <> t <> "\""

    boolArg flagP (Just True) = [flagP]
    boolArg _ _ = []
