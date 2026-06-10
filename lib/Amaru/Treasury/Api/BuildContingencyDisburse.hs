{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

{- |
Module      : Amaru.Treasury.Api.BuildContingencyDisburse
Description : JSON carriers + mapper for
              @POST /v1/build/contingency-disburse@ (#327).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Contingency sibling of 'Amaru.Treasury.Api.BuildDisburse'.
A shallow request type with the primitive fields the operator
(or the Operate UI) supplies; the mapper translates to
'ContingencyDisburseOpts' before the handler calls
'Amaru.Treasury.Wizard.Disburse.buildContingencyDisburseIntent'
and then the shared 'buildDisburseTx'.

The source scope is always @contingency@ and the unit is
always ADA, so — unlike the generic disburse request — there
is no scope / unit field on the wire; instead the request
carries a non-empty list of @(destination scope, ADA)@
beneficiaries.  The 'DisburseBuildResponse' shape is reused
verbatim from 'Amaru.Treasury.Api.BuildDisburse' since the
two endpoints return byte-identical response arms.
-}
module Amaru.Treasury.Api.BuildContingencyDisburse
    ( -- * Request
      ContingencyDisburseBuildRequest (..)
    , ContingencyDestinationRequest (..)

      -- * Mapper
    , mapToContingencyDisburseOpts

      -- * Handler runner
    , runBuildContingencyDisburse

      -- * CLI preview
    , renderCli
    ) where

import Control.Exception (SomeException, try)
import Control.Tracer (Tracer (..))
import Data.Aeson (FromJSON, ToJSON)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BSL
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as TIO
import Data.Word (Word16)
import GHC.Generics (Generic)
import System.IO (stderr)

import Amaru.Treasury.Api.BuildDisburse
    ( DisburseBuildResponse (..)
    )
import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Build.Trace (renderBuildEvent)
import Amaru.Treasury.Cli.Common (GlobalOpts)
import Amaru.Treasury.Cli.DisburseWizard
    ( ContingencyDisburseOpts (..)
    )
import Amaru.Treasury.IntentJSON
    ( RationaleReferenceJSON
    , encodeSomeTreasuryIntent
    )
import Amaru.Treasury.Report
    ( TxBuildSuccess (..)
    , TxCborHex (..)
    )
import Amaru.Treasury.Scope (ScopeId (..), scopeText)
import Amaru.Treasury.Tx.DisburseWizard.Trace
    ( renderDisburseWizardEvent
    )
import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind (..)
    , encodeEnvelope
    )
import Amaru.Treasury.Wizard.Disburse
    ( buildContingencyDisburseIntent
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

{- | One @(destination scope, ADA amount)@ beneficiary on the
@contingency-disburse@ wire.  @amountAda@ is the user-facing
ADA figure (not lovelace); the mapper multiplies by @1e6@.
-}
data ContingencyDestinationRequest = ContingencyDestinationRequest
    { scope :: ScopeId
    -- ^ Destination treasury scope; the mapper rejects
    --   @contingency@ (a contingency disburse pays *out* of
    --   contingency, never into it).
    , amountAda :: Double
    -- ^ Beneficiary amount in ADA; mapper rejects values @<= 0@.
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

{- | Operator-supplied contingency-disburse inputs over HTTP.
The source scope (@contingency@) and unit (ADA) are implicit,
so they carry no wire field; the destination list is the
repeatable beneficiary set.  This is the contract the #329
Operate UI POSTs to.
-}
data ContingencyDisburseBuildRequest = ContingencyDisburseBuildRequest
    { walletAddr :: Text
    , destinations :: [ContingencyDestinationRequest]
    -- ^ Non-empty on the happy path; the mapper rejects an
    --   empty list with a typed 'WizardFailure'.
    , validityHours :: Maybe Word16
    , description :: Text
    , justification :: Text
    , references :: [RationaleReferenceJSON]
    -- ^ Off-chain CIP-1694 rationale references (IPFS CIDs
    --   for invoices, contracts, proofs).  Pass-through to
    --   'cdOptsReferences', mirroring the non-contingency
    --   'Amaru.Treasury.Api.BuildDisburse.dbrReferences'.
    --   The Operate UI always sends this key (empty array
    --   when none).
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Mapper

{- | Translate a wire-shape 'ContingencyDisburseBuildRequest'
into the in-process 'ContingencyDisburseOpts' that
'buildContingencyDisburseIntent' consumes.

Returns 'Left' on inputs whose translation can fail before
the wizard runs at all:

  * an empty destinations list;
  * a @contingency@ destination scope (paying contingency into
    itself is never a contingency disburse);
  * a non-positive @amountAda@.

Other validation (bech32, registry membership, wallet
shortfall, …) lives downstream in
'buildContingencyDisburseIntent'.  Exclude / extra-tx-in
lists default to empty, matching the disburse-side mapper.
-}
mapToContingencyDisburseOpts
    :: FilePath
    -- ^ Server-configured metadata path; never a wire
    --   field (a client-supplied path would let any web
    --   caller pick which server-side file is opened).
    -> ContingencyDisburseBuildRequest
    -> Either WizardFailure ContingencyDisburseOpts
mapToContingencyDisburseOpts
    serverMetadataPath
    ContingencyDisburseBuildRequest{..} = do
        dests <- case destinations of
            [] ->
                Left
                    ( InputInvalid
                        FieldScope
                        "destinations must not be empty"
                    )
            (d : ds) -> traverse toDestination (d :| ds)
        Right
            ContingencyDisburseOpts
                { cdOptsWalletAddr = walletAddr
                , cdOptsMetadataPath = serverMetadataPath
                , cdOptsOut = Nothing
                , cdOptsLog = Nothing
                , cdOptsDestinations = dests
                , cdOptsValidityHours = validityHours
                , cdOptsDescription = description
                , cdOptsJustification = justification
                , cdOptsReferences = references
                , cdOptsExcludeSet = ExclusionSet []
                , cdOptsForcedSet = ForcedInclusionSet []
                }
      where
        toDestination
            :: ContingencyDestinationRequest
            -> Either WizardFailure (ScopeId, Integer)
        toDestination ContingencyDestinationRequest{..}
            | scope == Contingency =
                Left
                    ( InputScopeUnsupported
                        FieldScope
                        "contingency cannot be a disburse destination"
                    )
            | amountAda > 0 =
                Right (scope, floor (amountAda * 1_000_000))
            | otherwise =
                Left
                    ( InputOutOfRange
                        FieldScope
                        ( "destination amount must be positive, got "
                            <> T.pack (show amountAda)
                        )
                    )

-- ---------------------------------------------------------------------------
-- Handler runner

{- | Service-side runner used by the @amaru-treasury-tx-api@
binary.  Maps the wire-shape request to
'ContingencyDisburseOpts', calls
'buildContingencyDisburseIntent' against the caller-owned
long-lived 'Backend', and on success calls the shared
'buildDisburseTx' to populate the CBOR + report fields.

Failures (mapper or builder) are carried as the @failure*@
fields of the response; the HTTP handler returns a 200 with
those fields populated.  Same four-arm plumbing as
'Amaru.Treasury.Api.BuildDisburse.runBuildDisburse'.
-}
runBuildContingencyDisburse
    :: GlobalOpts
    -> FilePath
    -- ^ Server-configured metadata path
    -> Backend
    -> ContingencyDisburseBuildRequest
    -> IO DisburseBuildResponse
runBuildContingencyDisburse g serverMetadataPath backend req = do
    TIO.hPutStrLn
        stderr
        ( "amaru-treasury-tx-api: POST /v1/build/contingency-disburse \
          \destinations="
            <> T.pack (show (length (destinations req)))
        )
    case mapToContingencyDisburseOpts serverMetadataPath req of
        Left wf -> do
            TIO.hPutStrLn
                stderr
                ( "amaru-treasury-tx-api: build/contingency-disburse \
                  \mapper Left: "
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
                    ( buildContingencyDisburseIntent
                        g
                        opts
                        backend
                        tr
                    )
            case r of
                Left e -> do
                    TIO.hPutStrLn
                        stderr
                        ( "amaru-treasury-tx-api: \
                          \build/contingency-disburse exception: "
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
                        ( "amaru-treasury-tx-api: \
                          \build/contingency-disburse typed Left: "
                            <> renderWizardFailure wf
                        )
                    pure (failureResponse wf)
                Right (Right someIntent) -> do
                    TIO.hPutStrLn
                        stderr
                        "amaru-treasury-tx-api: \
                        \build/contingency-disburse intent OK"
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
                                , dbrGraphEffect = Nothing
                                , dbrTtl = Nothing
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
                                ( "amaru-treasury-tx-api: \
                                  \build/contingency-disburse tx \
                                  \exception: "
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
                                ( "amaru-treasury-tx-api: \
                                  \build/contingency-disburse tx \
                                  \typed Left: "
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
                                "amaru-treasury-tx-api: \
                                \build/contingency-disburse tx OK"
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
            , dbrGraphEffect = Nothing
            , dbrTtl = Nothing
            }

{- | Constructor tag of a 'WizardFailure' as a stable string.
Duplicated from 'Amaru.Treasury.Api.BuildDisburse' (which in
turn duplicates 'Amaru.Treasury.Api.BuildSwap') so this
module stays self-contained; a later slice may extract the
three into a shared helper.
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

{- | Constructor tag of a 'BuildFailure' as a stable string.
Wire counterpart of the same-named helper in
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

{- | Render the equivalent @amaru-treasury-tx
contingency-disburse-wizard@ CLI invocation for a request.
Convenience for operators who want to reproduce the build
locally; one @--to \<scope\>:\<ada\>@ flag per destination.
-}
renderCli :: ContingencyDisburseBuildRequest -> Text
renderCli ContingencyDisburseBuildRequest{..} =
    T.intercalate
        " \\\n  "
        ( "amaru-treasury-tx contingency-disburse-wizard"
            : ("--wallet-addr " <> walletAddr)
            : "--metadata <metadata.json>"
            : map toFlag destinations
                <> validityArgs validityHours
                <> [ "--description " <> quote description
                   , "--justification " <> quote justification
                   ]
        )
  where
    toFlag d =
        "--to "
            <> scopeText (scope d)
            <> ":"
            <> T.pack (show (amountAda d))

    validityArgs Nothing = []
    validityArgs (Just h) = ["--validity-hours " <> T.pack (show h)]

    quote t = "\"" <> t <> "\""
