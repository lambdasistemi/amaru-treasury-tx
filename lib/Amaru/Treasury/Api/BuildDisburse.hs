{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

{- |
Module      : Amaru.Treasury.Api.BuildDisburse
Description : JSON carriers + mapper for @POST /v1/build/disburse@
              (#277).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Sister of 'Amaru.Treasury.Api.BuildSwap' for the
disburse-wizard subcommand.  A shallow request type with
primitive fields the operator supplies; the mapper
translates to 'DisburseWizardOpts' before the handler calls
'Amaru.Treasury.Wizard.Disburse.buildDisburseIntent' and
then 'buildDisburseTx'.

Keeping the JSON shape distinct from 'DisburseWizardOpts'
avoids chaining @ToJSON@ / @FromJSON@ instances across the
wizard internals; the HTTP wire contract evolves
independently from the in-process record.
-}
module Amaru.Treasury.Api.BuildDisburse
    ( -- * Request
      DisburseBuildRequest (..)

      -- * Response
    , DisburseBuildResponse (..)

      -- * Mapper
    , mapToDisburseWizardOpts

      -- * Handler runner
    , runBuildDisburse
    ) where

import Control.Exception (SomeException, try)
import Control.Tracer (Tracer (..))
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.Char (toLower)
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
import Amaru.Treasury.Cli.DisburseWizard
    ( DisburseWizardOpts (..)
    )
import Amaru.Treasury.Constants (Unit (..))
import Amaru.Treasury.IntentJSON
    ( RationaleReferenceJSON
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.Report
    ( TxBuildSuccess (..)
    , TxCborHex (..)
    )
import Amaru.Treasury.Scope (ScopeId)
import Amaru.Treasury.Tx.DisburseWizard.Trace
    ( renderDisburseWizardEvent
    )
import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind (..)
    , encodeEnvelope
    )
import Amaru.Treasury.Wizard.Disburse
    ( buildDisburseIntent
    , buildDisburseTx
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

-- ---------------------------------------------------------------------------
-- Request

-- | Operator-supplied disburse inputs over HTTP.
data DisburseBuildRequest = DisburseBuildRequest
    { dbrScope :: ScopeId
    , dbrWalletAddr :: Text
    , dbrBeneficiaryAddr :: Text
    , dbrMetadataPath :: FilePath
    , dbrUnit :: Text
    -- ^ Currency selector; @"ada"@ or @"usdm"@
    --   (case-insensitive).  Mapper rejects other values.
    , dbrAmount :: Double
    -- ^ Amount in the unit's user-facing denomination
    --   (ADA, not lovelace; USDM, not micro-USDM).  The
    --   mapper converts via @* 1_000_000@ before handing
    --   to 'buildDisburseIntent'.
    , dbrValidityHours :: Maybe Word16
    , dbrDescription :: Text
    , dbrJustification :: Text
    , dbrDestinationLabel :: Text
    , dbrEvent :: Maybe Text
    , dbrLabel :: Maybe Text
    , dbrSigners :: [Text]
    , dbrReferences :: [RationaleReferenceJSON]
    -- ^ Optional external rationale references — pass-through
    --   to 'dwOptsReferences'.
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Response

{- | Shape of @POST /v1/build/disburse@ response.  On
success the body carries the encoded intent.json plus a
copy-pasteable CLI invocation; on failure it carries the
typed 'WizardFailure' / 'BuildFailure' tag.  Same four-arm
shape as 'Amaru.Treasury.Api.BuildSwap.SwapBuildResponse'.
-}
data DisburseBuildResponse = DisburseBuildResponse
    { dbrIntentJson :: Maybe Text
    -- ^ Pretty-printed @intent.json@ on success.
    , dbrCli :: Maybe Text
    -- ^ Equivalent CLI invocation on success.
    , dbrCborHex :: Maybe Text
    -- ^ Hex-encoded unsigned Conway tx body, present iff
    --   intent assembly AND tx build both succeeded.
    , dbrCborEnvelope :: Maybe Text
    -- ^ Same body wrapped in the cardano-cli text-envelope
    --   JSON so an operator can pipe it straight into
    --   @cardano-cli transaction witness@.
    , dbrReport :: Maybe Text
    -- ^ Pretty-printed @report.json@, present iff tx
    --   build succeeded.
    , dbrFailureTag :: Maybe Text
    -- ^ Constructor name of the 'WizardFailure' on
    --   intent-assembly failure.
    , dbrFailureField :: Maybe FieldId
    -- ^ The offending field on @Input*@ failures.
    , dbrFailureReason :: Maybe Text
    -- ^ Human-readable diagnostic on failure
    --   ('renderWizardFailure' / 'renderBuildFailure' output).
    , dbrBuildFailureTag :: Maybe Text
    -- ^ Constructor name of the 'BuildFailure' on tx-build
    --   failure; 'Nothing' if intent assembly failed OR
    --   build succeeded.
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Mapper

{- | Translate a wire-shape 'DisburseBuildRequest' into the
in-process 'DisburseWizardOpts' that 'buildDisburseIntent'
consumes.

Returns 'Left' on inputs whose translation can fail before
the wizard runs at all: unrecognised unit and non-positive
amount.  Other validation (bech32, scope membership,
wallet shortfall, …) lives downstream in
'buildDisburseIntent' itself.

Exclude / extra-tx-in lists default to empty (matches the
swap-side mapper's PR-A scope; the wire shape can grow
those fields in a later slice if the dashboard ever needs
to surface them).
-}
mapToDisburseWizardOpts
    :: DisburseBuildRequest
    -> Either WizardFailure DisburseWizardOpts
mapToDisburseWizardOpts DisburseBuildRequest{..} = do
    unit <- parseUnit dbrUnit
    amountInteger <- toSmallestUnit unit dbrAmount
    Right
        DisburseWizardOpts
            { dwOptsWalletAddr = dbrWalletAddr
            , dwOptsMetadataPath = dbrMetadataPath
            , dwOptsOut = Nothing
            , dwOptsLog = Nothing
            , dwOptsScope = dbrScope
            , dwOptsUnit = unit
            , dwOptsAmount = amountInteger
            , dwOptsBeneficiaryAddr = dbrBeneficiaryAddr
            , dwOptsValidityHours = dbrValidityHours
            , dwOptsDescription = dbrDescription
            , dwOptsJustification = dbrJustification
            , dwOptsDestinationLabel = dbrDestinationLabel
            , dwOptsEvent = dbrEvent
            , dwOptsLabel = dbrLabel
            , dwOptsReferences = dbrReferences
            , dwOptsSigners = dbrSigners
            , dwOptsTreasuryTxIns = []
            , dwOptsExcludeSet = ExclusionSet []
            , dwOptsForcedSet = ForcedInclusionSet []
            }
  where
    -- The disburse CLI flag is named @--unit@; the
    -- closest existing 'FieldId' constructor is
    -- 'FieldUsdm' (the default unit).  A dedicated
    -- @FieldUnit@ / @FieldAmount@ pair is a candidate
    -- for a later widening of 'FieldId' once a UI starts
    -- branching on them.
    parseUnit :: Text -> Either WizardFailure Unit
    parseUnit raw = case map toLower (T.unpack raw) of
        "ada" -> Right ADA
        "usdm" -> Right USDM
        _ ->
            Left
                ( InputInvalid
                    FieldUsdm
                    ( "unit must be \"ada\" or \"usdm\", got "
                        <> raw
                    )
                )

    toSmallestUnit :: Unit -> Double -> Either WizardFailure Integer
    toSmallestUnit _ amount
        | amount > 0 =
            Right (floor (amount * 1_000_000))
        | otherwise =
            Left
                ( InputOutOfRange
                    FieldUsdm
                    ( "amount must be positive, got "
                        <> T.pack (show amount)
                    )
                )

-- ---------------------------------------------------------------------------
-- Handler runner

{- | Service-side runner used by the @amaru-treasury-tx-api@
binary.  Maps the wire-shape request to
'DisburseWizardOpts', calls 'buildDisburseIntent' against
the caller-owned long-lived 'Backend', and on success calls
'buildDisburseTx' against the same backend to populate the
CBOR + report fields of the response.

Failures (whether from the mapper or from
'buildDisburseIntent' / 'buildDisburseTx') are carried as
the @failure*@ fields of the response; the HTTP handler
returns a 200 with those fields populated.
-}
runBuildDisburse
    :: GlobalOpts
    -> Backend
    -> DisburseBuildRequest
    -> IO DisburseBuildResponse
runBuildDisburse g backend req = do
    TIO.hPutStrLn
        stderr
        ( "amaru-treasury-tx-api: POST /v1/build/disburse scope="
            <> T.pack (show (dbrScope req))
        )
    case mapToDisburseWizardOpts req of
        Left wf -> do
            TIO.hPutStrLn
                stderr
                ( "amaru-treasury-tx-api: build/disburse mapper Left: "
                    <> renderWizardFailure wf
                )
            pure (failureResponse wf)
        Right opts -> do
            let tr =
                    Tracer
                        ( TIO.hPutStrLn stderr
                            . ("amaru-treasury-tx-api: " <>)
                            . renderDisburseWizardEvent
                        )
            r <-
                try @SomeException
                    (buildDisburseIntent g opts backend tr)
            case r of
                Left e -> do
                    TIO.hPutStrLn
                        stderr
                        ( "amaru-treasury-tx-api: build/disburse exception: "
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
                        ( "amaru-treasury-tx-api: build/disburse typed Left: "
                            <> renderWizardFailure wf
                        )
                    pure (failureResponse wf)
                Right (Right someIntent) -> do
                    TIO.hPutStrLn
                        stderr
                        "amaru-treasury-tx-api: build/disburse intent OK"
                    let intentJson =
                            Text.decodeUtf8
                                ( BSL.toStrict
                                    ( encodeSomeTreasuryIntent
                                        someIntent
                                    )
                                )
                        intentOnly =
                            DisburseBuildResponse
                                { dbrIntentJson = Just intentJson
                                , dbrCli = Just (renderCli req)
                                , dbrCborHex = Nothing
                                , dbrCborEnvelope = Nothing
                                , dbrReport = Nothing
                                , dbrFailureTag = Nothing
                                , dbrFailureField = Nothing
                                , dbrFailureReason = Nothing
                                , dbrBuildFailureTag = Nothing
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
                            ( buildDisburseTx
                                g
                                backend
                                someIntent
                                trB
                            )
                    case rb of
                        Left e -> do
                            TIO.hPutStrLn
                                stderr
                                ( "amaru-treasury-tx-api: build/disburse tx exception: "
                                    <> T.pack (show e)
                                )
                            pure
                                intentOnly
                                    { dbrBuildFailureTag =
                                        Just "BuildInternalError"
                                    , dbrFailureReason =
                                        Just
                                            ( "uncaught build exception: "
                                                <> T.pack (show e)
                                            )
                                    }
                        Right (Left bf) -> do
                            TIO.hPutStrLn
                                stderr
                                ( "amaru-treasury-tx-api: build/disburse tx typed Left: "
                                    <> renderBuildFailure bf
                                )
                            pure
                                intentOnly
                                    { dbrBuildFailureTag =
                                        Just (buildFailureTag bf)
                                    , dbrFailureField = fieldOfBuild bf
                                    , dbrFailureReason =
                                        Just (renderBuildFailure bf)
                                    }
                        Right (Right tbs) -> do
                            TIO.hPutStrLn
                                stderr
                                "amaru-treasury-tx-api: build/disburse tx OK"
                            let bareHex =
                                    unTxCborHex (tbsTxCbor tbs)
                                envelopeBytes =
                                    encodeEnvelope
                                        Tx
                                        (Text.encodeUtf8 bareHex)
                            pure
                                intentOnly
                                    { dbrCborHex = Just bareHex
                                    , dbrCborEnvelope =
                                        Just
                                            ( Text.decodeUtf8
                                                envelopeBytes
                                            )
                                    , dbrReport =
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
    failureResponse :: WizardFailure -> DisburseBuildResponse
    failureResponse wf =
        DisburseBuildResponse
            { dbrIntentJson = Nothing
            , dbrCli = Nothing
            , dbrCborHex = Nothing
            , dbrCborEnvelope = Nothing
            , dbrReport = Nothing
            , dbrFailureTag = Just (failureTag wf)
            , dbrFailureField = fieldOf wf
            , dbrFailureReason = Just (renderWizardFailure wf)
            , dbrBuildFailureTag = Nothing
            }

{- | Constructor tag of a 'WizardFailure' as a stable
string — wire counterpart of the same-named helper in
'Amaru.Treasury.Api.BuildSwap'.  Duplicated here so the
disburse module is self-contained; a later slice may
extract the two into a shared helper module.
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
string — wire counterpart of the same-named helper in
'Amaru.Treasury.Api.BuildSwap'.
-}
buildFailureTag :: BuildFailure -> Text
buildFailureTag = \case
    BuildInputInvalid{} -> "BuildInputInvalid"
    BuildResolveParams{} -> "BuildResolveParams"
    BuildResolveTip{} -> "BuildResolveTip"
    BuildResolveUtxo{} -> "BuildResolveUtxo"
    BuildBuildError{} -> "BuildBuildError"
    BuildInternalError{} -> "BuildInternalError"

{- | Render the equivalent @amaru-treasury-tx disburse-wizard@
CLI invocation for a request.  Convenience for operators
who want to reproduce the build locally.
-}
renderCli :: DisburseBuildRequest -> Text
renderCli DisburseBuildRequest{..} =
    T.intercalate
        " \\\n  "
        ( "amaru-treasury-tx disburse-wizard"
            : ("--scope " <> T.pack (show dbrScope))
            : ("--wallet-addr " <> dbrWalletAddr)
            : ("--beneficiary-addr " <> dbrBeneficiaryAddr)
            : ("--metadata " <> T.pack dbrMetadataPath)
            : ("--unit " <> T.toLower dbrUnit)
            : ("--amount " <> T.pack (show dbrAmount))
            : validityArgs dbrValidityHours
                <> [ "--description " <> quote dbrDescription
                   , "--justification " <> quote dbrJustification
                   , "--destination-label "
                        <> quote dbrDestinationLabel
                   ]
                <> maybeArg "--event " dbrEvent
                <> maybeArg "--label " dbrLabel
                <> map ("--extra-signer " <>) dbrSigners
        )
  where
    validityArgs Nothing = []
    validityArgs (Just h) = ["--validity-hours " <> T.pack (show h)]

    maybeArg _ Nothing = []
    maybeArg flagP (Just v) = [flagP <> v]

    quote t = "\"" <> t <> "\""
