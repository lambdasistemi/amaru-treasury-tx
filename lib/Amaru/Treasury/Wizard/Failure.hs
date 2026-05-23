{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.Failure
Description : Typed failure values returned by the swap
              wizard pipeline (#259).
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Two sum types tell a caller of 'buildSwapIntent' /
'buildSwapTx' (or of the CLI wrappers that exit-and-print)
exactly what went wrong, without exiting the host process:

  * 'WizardFailure' — produced by the intent-construction
    step (chain query + registry verify + resolver +
    translate + encode).
  * 'BuildFailure' — produced by the tx-build step
    (resolve params/tip + 'TxBuild' DSL).

Variants are grouped into three families distinguished by
the constructor prefix.  A UI that consumes a failure can
branch on the family to decide between "highlight this
field", "show an infrastructure banner", and "this is a
bug — please report".

== Families

[@Input*@]    Operator-supplied data is malformed or out of
              range.  Variants carry a 'FieldId' so a form
              can highlight the offending input.

[@Resolve*@]  The environment, chain state, or registry made
              the request unservable.  Not the operator's
              fault.

[@Internal*@] The wizard hit an invariant it does not expect.
              UI should show a "report a bug" prompt.

== JSON

Only 'FieldId' carries a 'ToJSON' / 'FromJSON' instance in
this module — the existing typed inner errors
('Amaru.Treasury.Tx.SwapWizard.ResolverError',
'Amaru.Treasury.Tx.SwapWizard.WizardError', etc.) do not
have JSON instances and will gain them in the HTTP-endpoint
follow-up that closes the @POST \/build\/{kind}@ slice of
#248.  Until then, this module's CLI consumer renders
failures to text via 'renderWizardFailure' /
'renderBuildFailure' for stderr printing.
-}
module Amaru.Treasury.Wizard.Failure
    ( -- * Input-field identifiers
      FieldId (..)

      -- * Wizard (intent-construction) failures
    , WizardFailure (..)
    , isInput
    , fieldOf
    , renderWizardFailure

      -- * Build (tx-construction) failures
    , BuildFailure (..)
    , isInputBuild
    , fieldOfBuild
    , renderBuildFailure
    ) where

import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , Value (String)
    , withText
    )
import Data.Text (Text)
import Data.Text qualified as T

-- ---------------------------------------------------------------------------
-- Field identifiers

{- | Stable identifier naming every form field the
operator may have supplied.  Used by 'Input*' failure
variants so a UI can highlight the offending input.

The JSON encoding is the constructor name without the
@Field@ prefix, snake_cased.  Adding a new field is a
non-breaking superset; renaming or removing one is
breaking.
-}
data FieldId
    = FieldScope
    | FieldWalletAddr
    | FieldUsdm
    | FieldAllAda
    | FieldSplit
    | FieldRate
    | FieldSlippageBps
    | FieldValidityHours
    | FieldDescription
    | FieldJustification
    | FieldDestinationLabel
    | FieldEvent
    | FieldLabel
    | FieldExtraSigner
    | FieldMetadataPath
    | FieldExcludeUtxo
    | FieldForceUtxo
    deriving (Eq, Show)

fieldToText :: FieldId -> Text
fieldToText = \case
    FieldScope -> "scope"
    FieldWalletAddr -> "wallet_addr"
    FieldUsdm -> "usdm"
    FieldAllAda -> "all_ada"
    FieldSplit -> "split"
    FieldRate -> "rate"
    FieldSlippageBps -> "slippage_bps"
    FieldValidityHours -> "validity_hours"
    FieldDescription -> "description"
    FieldJustification -> "justification"
    FieldDestinationLabel -> "destination_label"
    FieldEvent -> "event"
    FieldLabel -> "label"
    FieldExtraSigner -> "extra_signer"
    FieldMetadataPath -> "metadata"
    FieldExcludeUtxo -> "exclude_utxo"
    FieldForceUtxo -> "force_utxo"

fieldFromText :: Text -> Maybe FieldId
fieldFromText = \case
    "scope" -> Just FieldScope
    "wallet_addr" -> Just FieldWalletAddr
    "usdm" -> Just FieldUsdm
    "all_ada" -> Just FieldAllAda
    "split" -> Just FieldSplit
    "rate" -> Just FieldRate
    "slippage_bps" -> Just FieldSlippageBps
    "validity_hours" -> Just FieldValidityHours
    "description" -> Just FieldDescription
    "justification" -> Just FieldJustification
    "destination_label" -> Just FieldDestinationLabel
    "event" -> Just FieldEvent
    "label" -> Just FieldLabel
    "extra_signer" -> Just FieldExtraSigner
    "metadata" -> Just FieldMetadataPath
    "exclude_utxo" -> Just FieldExcludeUtxo
    "force_utxo" -> Just FieldForceUtxo
    _ -> Nothing

instance ToJSON FieldId where
    toJSON = String . fieldToText

instance FromJSON FieldId where
    parseJSON = withText "FieldId" $ \t ->
        case fieldFromText t of
            Just f -> pure f
            Nothing -> fail $ "unknown FieldId: " <> T.unpack t

-- ---------------------------------------------------------------------------
-- WizardFailure

{- | Typed failure value returned by 'buildSwapIntent'.

Each variant is a former @abortTr@ site in
@Amaru.Treasury.Cli.SwapWizard.runWizard@.  The 'Text' on
@Resolve*@ and @Internal*@ variants is the human-readable
diagnostic the CLI used to print before exiting; it is the
single source of truth for stderr text after the refactor.
-}
data WizardFailure
    = -- | Operator input is malformed (e.g. bech32 decode
      --   failed, ScriptHash hex wrong length).
      InputInvalid !FieldId !Text
    | -- | Operator input is well-formed but out of the
      --   accepted range (e.g. @--validity-hours 0@).
      InputOutOfRange !FieldId !Text
    | -- | Operator-supplied input-control sets were
      --   contradictory or otherwise refused
      --   (@--exclude-utxo@ ∩ @--extra-tx-in@ non-empty,
      --   etc.).  The carried 'FieldId' points at the
      --   primary offender.
      InputControl !FieldId !Text
    | -- | Scope value parsed but the wizard does not
      --   support it (e.g. @contingency@).
      InputScopeUnsupported !FieldId !Text
    | -- | The CLI flags pointed at a network that the
      --   binary does not know how to drive.
      ResolveNetworkUnsupported !Text
    | -- | The resolver could not derive swap parameters
      --   (rate or chunk-size resolution failed).
      ResolveSwapParameters !Text
    | -- | Registry verification refused (metadata pin
      --   mismatch, missing tenant, …).
      ResolveRegistryVerify !Text
    | -- | The resolver returned a typed @ResolverError@ —
      --   wallet shortfall, missing wallet UTxOs, …  The
      --   carried text is the existing renderer output so
      --   stderr stays identical.
      ResolveResolver !Text
    | -- | @--validity-hours N@ overshoots the chain
      --   horizon, or the chain refused to resolve an
      --   upper-bound slot.
      ResolveValidityHorizon !Text
    | -- | The pure intent translation
      --   ('Tx.SwapWizard.wizardToTreasuryIntent')
      --   refused.  Treated as an internal invariant — the
      --   upstream input-control / resolver layers should
      --   have caught this earlier.
      InternalTranslate !Text
    | -- | Final intent serialisation failed.  Invariant.
      InternalEncodeError !Text
    deriving (Eq, Show)

-- | True for the @Input*@ family.
isInput :: WizardFailure -> Bool
isInput = \case
    InputInvalid{} -> True
    InputOutOfRange{} -> True
    InputControl{} -> True
    InputScopeUnsupported{} -> True
    _ -> False

{- | The 'FieldId' an @Input*@ variant points at; 'Nothing'
for the system-level families.
-}
fieldOf :: WizardFailure -> Maybe FieldId
fieldOf = \case
    InputInvalid f _ -> Just f
    InputOutOfRange f _ -> Just f
    InputControl f _ -> Just f
    InputScopeUnsupported f _ -> Just f
    _ -> Nothing

{- | Single-line human-readable render used for stderr
output by the CLI wrapper.  Format mirrors the pre-refactor
@abortTr@ text so wrapping scripts that grep stderr keep
working.
-}
renderWizardFailure :: WizardFailure -> Text
renderWizardFailure = \case
    InputInvalid f t ->
        "input " <> fieldToText f <> ": " <> t
    InputOutOfRange f t ->
        "input " <> fieldToText f <> " out of range: " <> t
    InputControl f t ->
        "input-control: " <> t <> " (primary: " <> fieldToText f <> ")"
    InputScopeUnsupported f t ->
        "scope unsupported: " <> t <> " (field: " <> fieldToText f <> ")"
    ResolveNetworkUnsupported t -> t
    ResolveSwapParameters t -> "derive swap parameters: " <> t
    ResolveRegistryVerify t -> "verify: " <> t
    ResolveResolver t -> t
    ResolveValidityHorizon t -> t
    InternalTranslate t -> "translate: " <> t
    InternalEncodeError t -> "encode: " <> t

-- ---------------------------------------------------------------------------
-- BuildFailure

{- | Typed failure value returned by 'buildSwapTx'.

The tx-build pipeline ('Amaru.Treasury.Build.Swap') is
already 'ExceptT'-based; 'BuildFailure' is the surface
'IO'-shaped variant that the wrapper produces.
-}
data BuildFailure
    = -- | Intent payload was incoherent (e.g. scope in the
      --   intent does not match a known scope after
      --   resolution).
      BuildInputInvalid !FieldId !Text
    | -- | Protocol parameter resolution failed.
      BuildResolveParams !Text
    | -- | Chain tip query failed.
      BuildResolveTip !Text
    | -- | UTxO resolution refused (missing tx ref,
      --   inconsistent ledger view, …).
      BuildResolveUtxo !Text
    | -- | The 'TxBuild' DSL refused — min-utxo violation,
      --   redeemer mismatch, fee overflow, etc.
      BuildBuildError !Text
    | -- | Invariant the builder does not expect; UI shows
      --   a "report a bug" prompt.
      BuildInternalError !Text
    deriving (Eq, Show)

-- | True for the @BuildInputInvalid@ family.
isInputBuild :: BuildFailure -> Bool
isInputBuild = \case
    BuildInputInvalid{} -> True
    _ -> False

-- | The 'FieldId' a @BuildInputInvalid@ variant points at.
fieldOfBuild :: BuildFailure -> Maybe FieldId
fieldOfBuild = \case
    BuildInputInvalid f _ -> Just f
    _ -> Nothing

{- | Single-line human-readable render used for stderr
output by the @tx-build@ CLI wrapper.
-}
renderBuildFailure :: BuildFailure -> Text
renderBuildFailure = \case
    BuildInputInvalid f t ->
        "build-input " <> fieldToText f <> ": " <> t
    BuildResolveParams t -> "resolve params: " <> t
    BuildResolveTip t -> "resolve tip: " <> t
    BuildResolveUtxo t -> "resolve utxo: " <> t
    BuildBuildError t -> "build: " <> t
    BuildInternalError t -> "internal: " <> t
