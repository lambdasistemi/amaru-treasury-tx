{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StrictData #-}

{- |
Module      : Amaru.Treasury.Api.BuildSwap
Description : JSON carriers + mapper for @POST /v1/build/swap@
              (#263).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

A shallow request type with primitive fields the operator
supplies; the mapper translates to 'WizardOpts' before the
handler calls
'Amaru.Treasury.Wizard.Swap.buildSwapIntent'.

Keeping the JSON shape distinct from 'WizardOpts' avoids
chaining @ToJSON@ / @FromJSON@ instances across the wizard
internals; the HTTP wire contract evolves independently
from the in-process record.
-}
module Amaru.Treasury.Api.BuildSwap
    ( -- * Request
      SwapBuildRequest (..)
    , SwapAmount (..)
    , SwapChunk (..)
    , SwapRate (..)

      -- * Response
    , SwapBuildResponse (..)

      -- * Mapper
    , mapToWizardOpts

      -- * Handler runner
    , runBuildSwap

      -- * CLI preview
    , renderCli
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

import Amaru.Treasury.Api.GraphEffect (GraphEffect)
import Amaru.Treasury.Backend (Backend)
import Amaru.Treasury.Build.Trace (renderBuildEvent)
import Amaru.Treasury.Cli.Common (GlobalOpts)
import Amaru.Treasury.Cli.SwapWizard
    ( ChunkSpec (..)
    , WizardOpts (..)
    , WizardOrder (..)
    , WizardRate (..)
    )
import Amaru.Treasury.IntentJSON (encodeSomeTreasuryIntent)
import Amaru.Treasury.Report
    ( TxBuildSuccess (..)
    , TxCborHex (..)
    )
import Amaru.Treasury.Scope (ScopeId)
import Amaru.Treasury.Tx.Envelope
    ( EnvelopeKind (..)
    , encodeEnvelope
    )
import Amaru.Treasury.Tx.SwapQuote (SlippageBps (..))
import Amaru.Treasury.Tx.SwapWizard.Trace (renderEvent)
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
import Amaru.Treasury.Wizard.Swap
    ( buildSwapIntent
    , buildSwapTx
    )

-- ---------------------------------------------------------------------------
-- Request

-- | Operator-supplied swap inputs over HTTP.
data SwapBuildRequest = SwapBuildRequest
    { sbrScope :: ScopeId
    , sbrWalletAddr :: Text
    , sbrAmount :: SwapAmount
    , sbrRate :: SwapRate
    , sbrValidityHours :: Maybe Word16
    , sbrDescription :: Text
    , sbrJustification :: Text
    , sbrDestinationLabel :: Text
    , sbrEvent :: Maybe Text
    , sbrLabel :: Maybe Text
    , sbrSigners :: [Text]
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

{- | Either a fixed USDM target plus chunking, or all-ADA
max-spend split into N chunks.
-}
data SwapAmount
    = AmountFixedUsdm Double SwapChunk
    | AmountAllAda Int
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

{- | Chunk specification mirroring the CLI's @--split@ /
@--chunk-usdm@ flags.
-}
data SwapChunk
    = ChunkSplit Int
    | ChunkUsdmEach Double
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

{- | Either an operator-supplied minimum rate, or a quote
override with slippage in basis points.
-}
data SwapRate
    = RateMin Double
    | RateOverride Double Integer
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Response

{- | Shape of @POST /v1/build/swap@ response.  On success
the body carries the encoded intent.json plus a
copy-pasteable CLI invocation; on failure it carries the
typed 'WizardFailure'.  Exactly one of the fields is
'Just'.
-}
data SwapBuildResponse = SwapBuildResponse
    { sbrIntentJson :: Maybe Text
    -- ^ Pretty-printed @intent.json@ on success.
    , sbrCli :: Maybe Text
    -- ^ Equivalent CLI invocation on success.
    , sbrCborHex :: Maybe Text
    -- ^ Hex-encoded unsigned Conway tx body, present iff
    --   intent assembly AND tx build both succeeded
    --   (#269).
    , sbrCborEnvelope :: Maybe Text
    -- ^ Same body wrapped in the cardano-cli text-envelope
    --   JSON ('@{"type": "Tx ConwayEra", ...}'@) so an
    --   operator can pipe it straight into
    --   @cardano-cli transaction witness@ without
    --   wrapping the hex themselves (#269).
    , sbrReport :: Maybe Text
    -- ^ Pretty-printed @report.json@, present iff tx
    --   build succeeded (#269).
    , sbrFailureTag :: Maybe Text
    -- ^ Constructor name of the 'WizardFailure' on
    --   intent-assembly failure.
    , sbrFailureField :: Maybe FieldId
    -- ^ The offending field on @Input*@ failures.
    , sbrFailureReason :: Maybe Text
    -- ^ Human-readable diagnostic on failure
    --   ('renderWizardFailure' /
    --   'renderBuildFailure' output).
    , sbrBuildFailureTag :: Maybe Text
    -- ^ Constructor name of the 'BuildFailure' on
    --   tx-build failure (#269); 'Nothing' if intent
    --   assembly failed OR build succeeded.
    , sbrGraphEffect :: Maybe GraphEffect
    -- ^ Resolved graph-effect projection of the unsigned tx
    --   (#345): inputs + outputs resolved to treasury
    --   @{scope, role}@ entities + values + projected datums.
    --   Present iff tx build succeeded and the indexed UTxO
    --   state could resolve it; attached additively by the
    --   build handler, not the runner.
    }
    deriving (Eq, Show, Generic)
    deriving anyclass (FromJSON, ToJSON)

-- ---------------------------------------------------------------------------
-- Mapper

{- | Translate a wire-shape 'SwapBuildRequest' into the
in-process 'WizardOpts' that 'buildSwapIntent' consumes.
Returns 'Left' on inputs whose translation can fail before
the wizard runs at all (e.g. nonsensical slippage); other
validation lives downstream in 'buildSwapIntent' itself.

This mapper does NOT parse outref strings — the slippage
case is the only translation that materially fails here;
exclude/extra-tx-in lists default to empty in this slice
(#263 PR A scope).
-}
mapToWizardOpts
    :: FilePath
    -- ^ Server-configured metadata path; never a wire
    --   field (a client-supplied path would let any web
    --   caller pick which server-side file is opened).
    -> SwapBuildRequest
    -> Either WizardFailure WizardOpts
mapToWizardOpts serverMetadataPath SwapBuildRequest{..} = do
    order <- case sbrAmount of
        AmountFixedUsdm usdm chunkSpec ->
            Right (FixedUsdm usdm (mapChunk chunkSpec))
        AmountAllAda n
            | n > 0 -> Right (AllAda n)
            | otherwise ->
                Left
                    ( InputOutOfRange
                        FieldSplit
                        ( "all-ada split must be positive, got "
                            <> T.pack (show n)
                        )
                    )
    rate <- case sbrRate of
        RateMin minRate
            | minRate > 0 -> Right (WizardMinRate minRate)
            | otherwise ->
                Left
                    ( InputOutOfRange
                        FieldRate
                        ( "min rate must be > 0, got "
                            <> T.pack (show minRate)
                        )
                    )
        RateOverride adaUsdm bps
            | bps >= 0 ->
                Right (WizardOverrideRate adaUsdm (SlippageBps bps))
            | otherwise ->
                Left
                    ( InputOutOfRange
                        FieldSlippageBps
                        ( "slippage_bps must be >= 0, got "
                            <> T.pack (show bps)
                        )
                    )
    Right
        WizardOpts
            { wOptsWalletAddr = sbrWalletAddr
            , wOptsMetadataPath = serverMetadataPath
            , wOptsOut = Nothing
            , wOptsLog = Nothing
            , wOptsScope = sbrScope
            , wOptsOrder = order
            , wOptsRate = rate
            , wOptsValidityHours = sbrValidityHours
            , wOptsDescription = sbrDescription
            , wOptsJustification = sbrJustification
            , wOptsDestinationLabel = sbrDestinationLabel
            , wOptsEvent = sbrEvent
            , wOptsLabel = sbrLabel
            , wOptsSigners = sbrSigners
            , wOptsExcludeSet = ExclusionSet []
            , wOptsForcedSet = ForcedInclusionSet []
            }
  where
    mapChunk :: SwapChunk -> ChunkSpec
    mapChunk = \case
        ChunkSplit n -> SplitCount n
        ChunkUsdmEach x -> ChunkUsdm x

-- ---------------------------------------------------------------------------
-- Handler runner

{- | Service-side runner used by the @amaru-treasury-tx-api@
binary.  Maps the wire-shape request to 'WizardOpts', calls
'buildSwapIntent' against the caller-owned long-lived
'Backend', and renders the response as 'SwapBuildResponse'.

Failures (whether from the mapper or from 'buildSwapIntent')
are carried as the @failure*@ fields of the response; the
HTTP handler returns a 200 with those fields populated.
Mapping failure families to status codes is deferred to a
future commit (see #263 PR A scope).
-}
runBuildSwap
    :: GlobalOpts
    -> FilePath
    -- ^ Server-configured metadata path
    -> Backend
    -> SwapBuildRequest
    -> IO SwapBuildResponse
runBuildSwap g serverMetadataPath backend req = do
    TIO.hPutStrLn
        stderr
        ( "amaru-treasury-tx-api: POST /v1/build/swap scope="
            <> T.pack (show (sbrScope req))
        )
    case mapToWizardOpts serverMetadataPath req of
        Left wf -> do
            TIO.hPutStrLn
                stderr
                ( "amaru-treasury-tx-api: build/swap mapper Left: "
                    <> renderWizardFailure wf
                )
            pure (failureResponse wf)
        Right opts -> do
            -- Catch any IOException that escapes the typed-Either
            -- contract (deep bech32 parses, network drops, etc.)
            -- so the HTTP request always gets a structured body
            -- rather than a 500 + "Something went wrong".
            let tr =
                    Tracer
                        ( TIO.hPutStrLn stderr
                            . ("amaru-treasury-tx-api: " <>)
                            . renderEvent
                        )
            r <- try @SomeException (buildSwapIntent g opts backend tr)
            case r of
                Left e -> do
                    TIO.hPutStrLn
                        stderr
                        ( "amaru-treasury-tx-api: build/swap exception: "
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
                        ( "amaru-treasury-tx-api: build/swap typed Left: "
                            <> renderWizardFailure wf
                        )
                    pure (failureResponse wf)
                Right (Right someIntent) -> do
                    TIO.hPutStrLn
                        stderr
                        "amaru-treasury-tx-api: build/swap intent OK"
                    let intentJson =
                            Text.decodeUtf8
                                ( BSL.toStrict
                                    ( encodeSomeTreasuryIntent
                                        someIntent
                                    )
                                )
                        intentOnly =
                            SwapBuildResponse
                                { sbrIntentJson = Just intentJson
                                , sbrCli = Just (renderCli req)
                                , sbrCborHex = Nothing
                                , sbrCborEnvelope = Nothing
                                , sbrReport = Nothing
                                , sbrFailureTag = Nothing
                                , sbrFailureField = Nothing
                                , sbrFailureReason = Nothing
                                , sbrBuildFailureTag = Nothing
                                , sbrGraphEffect = Nothing
                                }
                    -- #269 — after intent assembly succeeds,
                    -- run the tx-build stage against the same
                    -- pre-opened Backend.  Failures populate
                    -- sbrBuildFailureTag + sbrFailureReason
                    -- (the data fields stay null); successes
                    -- populate cborHex + report.
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
                            ( buildSwapTx
                                g
                                backend
                                someIntent
                                trB
                            )
                    case rb of
                        Left e -> do
                            TIO.hPutStrLn
                                stderr
                                ( "amaru-treasury-tx-api: build/swap tx exception: "
                                    <> T.pack (show e)
                                )
                            pure
                                intentOnly
                                    { sbrBuildFailureTag =
                                        Just "BuildInternalError"
                                    , sbrFailureReason =
                                        Just
                                            ( "uncaught build exception: "
                                                <> T.pack (show e)
                                            )
                                    }
                        Right (Left bf) -> do
                            TIO.hPutStrLn
                                stderr
                                ( "amaru-treasury-tx-api: build/swap tx typed Left: "
                                    <> renderBuildFailure bf
                                )
                            pure
                                intentOnly
                                    { sbrBuildFailureTag =
                                        Just (buildFailureTag bf)
                                    , sbrFailureField = fieldOfBuild bf
                                    , sbrFailureReason =
                                        Just (renderBuildFailure bf)
                                    }
                        Right (Right tbs) -> do
                            TIO.hPutStrLn
                                stderr
                                "amaru-treasury-tx-api: build/swap tx OK"
                            let bareHex =
                                    unTxCborHex (tbsTxCbor tbs)
                                envelopeBytes =
                                    encodeEnvelope
                                        Tx
                                        (Text.encodeUtf8 bareHex)
                            pure
                                intentOnly
                                    { sbrCborHex = Just bareHex
                                    , sbrCborEnvelope =
                                        Just
                                            ( Text.decodeUtf8
                                                envelopeBytes
                                            )
                                    , sbrReport =
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
    failureResponse :: WizardFailure -> SwapBuildResponse
    failureResponse wf =
        SwapBuildResponse
            { sbrIntentJson = Nothing
            , sbrCli = Nothing
            , sbrCborHex = Nothing
            , sbrCborEnvelope = Nothing
            , sbrReport = Nothing
            , sbrFailureTag = Just (failureTag wf)
            , sbrFailureField = fieldOf wf
            , sbrFailureReason = Just (renderWizardFailure wf)
            , sbrBuildFailureTag = Nothing
            , sbrGraphEffect = Nothing
            }

{- | The constructor tag of a 'WizardFailure' as a stable
string — derived by 'show' truncated to the constructor
name (the wire contract for the family the UI branches
on).
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

{- | The constructor tag of a 'BuildFailure' as a stable
string — wire counterpart of 'failureTag' for the
tx-build side (#269).
-}
buildFailureTag :: BuildFailure -> Text
buildFailureTag = \case
    BuildInputInvalid{} -> "BuildInputInvalid"
    BuildResolveParams{} -> "BuildResolveParams"
    BuildResolveTip{} -> "BuildResolveTip"
    BuildResolveUtxo{} -> "BuildResolveUtxo"
    BuildBuildError{} -> "BuildBuildError"
    BuildInternalError{} -> "BuildInternalError"

{- | Render the equivalent @amaru-treasury-tx swap-wizard@
CLI invocation for a request.  Convenience for operators
who want to reproduce the build locally.

@--metadata@ renders the neutral @\<metadata.json\>@
placeholder: the operator substitutes their local copy, and
the server's own filesystem path never leaks into the
response.
-}
renderCli :: SwapBuildRequest -> Text
renderCli SwapBuildRequest{..} =
    T.intercalate
        " \\\n  "
        ( "amaru-treasury-tx swap-wizard"
            : ("--scope " <> T.pack (show sbrScope))
            : ("--wallet-addr " <> sbrWalletAddr)
            : "--metadata <metadata.json>"
            : amountArgs sbrAmount
                <> rateArgs sbrRate
                <> validityArgs sbrValidityHours
                <> [ "--description " <> quote sbrDescription
                   , "--justification " <> quote sbrJustification
                   , "--destination-label " <> sbrDestinationLabel
                   ]
                <> maybeArg "--event " sbrEvent
                <> maybeArg "--label " sbrLabel
                <> map ("--extra-signer " <>) sbrSigners
        )
  where
    amountArgs (AmountFixedUsdm usdm chunk) =
        ("--usdm " <> T.pack (show usdm)) : chunkArgs chunk
    amountArgs (AmountAllAda n) =
        ["--all-ada", "--split " <> T.pack (show n)]

    chunkArgs (ChunkSplit n) = ["--split " <> T.pack (show n)]
    chunkArgs (ChunkUsdmEach x) = ["--chunk-usdm " <> T.pack (show x)]

    rateArgs (RateMin r) = ["--min-rate " <> T.pack (show r)]
    rateArgs (RateOverride q bps) =
        [ "--ada-usdm " <> T.pack (show q)
        , "--slippage-bps " <> T.pack (show bps)
        ]

    validityArgs Nothing = []
    validityArgs (Just h) = ["--validity-hours " <> T.pack (show h)]

    maybeArg _ Nothing = []
    maybeArg flagP (Just v) = [flagP <> v]

    quote t = "\"" <> t <> "\""
