{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Report.Render
Description : Pure Markdown renderer for tx-build reports
License     : Apache-2.0

Renders a decoded build-output envelope into deterministic Markdown.
This module is pure; CLI stream handling lives outside the renderer.

The leading review section is intentionally compact: after the level-1
title and blank line, the first 25 lines carry the transaction type,
scope, transaction id, explorer link, CBOR fingerprint, validity,
conservation, rationale, and signer/output identity context that a
multisig reviewer needs on first screen.
-}
module Amaru.Treasury.Report.Render
    ( RenderError (..)
    , RenderOutput (..)
    , renderBuildOutput
    , renderBuildOutputWithMetadata
    , renderSuccessReport
    , renderSuccessReportWithMetadata
    ) where

import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.IntentJSON
    ( RationaleJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    )
import Amaru.Treasury.Metadata
    ( TreasuryMetadata
    )
import Amaru.Treasury.Report
    ( BuildFailure (..)
    , MetadataSummary (..)
    , ProducedOutput (..)
    , SignerRequirement (..)
    , SignerSource (..)
    , TransactionIdentity (..)
    , TransactionReport (..)
    , TreasuryAccounting (..)
    , TxBuildOutput (..)
    , TxBuildOutputResult (..)
    , TxBuildSuccess (..)
    , TxCborHex (..)
    , UtxoSummary (..)
    , ValueSummary (..)
    , WalletAccounting (..)
    )
import Amaru.Treasury.Report.Accounting
    ( addValueSummary
    , subtractValueSummary
    , sumValueSummaries
    )
import Amaru.Treasury.Report.Classify
    ( ProducedOutputRole
    , producedOutputRoleText
    )
import Amaru.Treasury.Report.Identity
    ( AddressBook
    , IdentityMap
    , ReferenceInputMap
    , ResolutionInputs (..)
    , buildAddressBook
    , buildIdentityMap
    , buildReferenceInputMap
    , resolveAddress
    , resolveReferenceInput
    , resolveSigner
    )
import Amaru.Treasury.Report.Identity.Constants
    ( labelAsset
    )
import Amaru.Treasury.Report.Render.Address
    ( formatAddress
    , formatKeyHash
    , formatReferenceInput
    , truncateIdentifier
    )
import Amaru.Treasury.Report.Render.Markdown
    ( blank
    , bullet
    , heading1
    , heading2
    , renderMarkdown
    )
import Amaru.Treasury.Report.Render.Time
    ( renderValidityInterval
    )

newtype RenderOutput = RenderOutput
    { unRenderOutput :: Text
    }
    deriving stock (Eq, Show)

newtype RenderError
    = RenderBuildFailure BuildFailure
    deriving stock (Eq, Show)

data OutputGroup = OutputGroup
    { ogRole :: ProducedOutputRole
    , ogDestination :: Text
    , ogValue :: ValueSummary
    , ogCount :: Int
    }
    deriving stock (Eq, Show)

-- | Render a build-output envelope without an external metadata source.
renderBuildOutput :: TxBuildOutput -> Either RenderError RenderOutput
renderBuildOutput =
    renderBuildOutputWithMetadata Nothing

{- | Render a build-output envelope with optional treasury metadata.

Failure envelopes are returned as 'RenderBuildFailure' because they
are diagnostics, not signable transaction reviews.
-}
renderBuildOutputWithMetadata
    :: Maybe TreasuryMetadata
    -> TxBuildOutput
    -> Either RenderError RenderOutput
renderBuildOutputWithMetadata metadata output =
    case txoResult output of
        TxBuildOutputSuccess success ->
            Right
                ( renderSuccessReportWithMetadata
                    metadata
                    (txoIntent output)
                    success
                )
        TxBuildOutputFailure failure ->
            Left (RenderBuildFailure failure)

-- | Render a successful build result using only built-ins and intent data.
renderSuccessReport
    :: SomeTreasuryIntent -> TxBuildSuccess -> RenderOutput
renderSuccessReport =
    renderSuccessReportWithMetadata Nothing

-- | Render a successful build result with optional metadata labels.
renderSuccessReportWithMetadata
    :: Maybe TreasuryMetadata
    -> SomeTreasuryIntent
    -> TxBuildSuccess
    -> RenderOutput
renderSuccessReportWithMetadata metadata intent success =
    RenderOutput . renderMarkdown $
        [ heading1 (intentTitle intent)
        , blank
        ]
            <> leadingLines intent success
            <> [ blank
               , heading2 "Consumed Inputs"
               ]
            <> consumedInputLines intent report addressBook
            <> [ blank
               , heading2 "Produced Outputs"
               ]
            <> producedOutputLines addressBook (trOutputs report)
            <> [ blank
               , heading2 "Reference Inputs"
               ]
            <> referenceInputLines referenceInputs report
            <> [ blank
               , heading2 "Required Signers"
               ]
            <> signerLines identityMap report
  where
    report = tbsReport success
    resolutionInputs =
        ResolutionInputs
            { riMetadata = metadata
            , riIntent = intent
            , riReport = report
            }
    addressBook = buildAddressBook resolutionInputs
    identityMap = buildIdentityMap resolutionInputs
    referenceInputs = buildReferenceInputMap resolutionInputs

leadingLines :: SomeTreasuryIntent -> TxBuildSuccess -> [Text]
leadingLines intent success =
    [ bullet ("Transaction id: " <> tiTxId identity)
    , bullet ("Transaction type: " <> actionTextFromIntent intent)
    , bullet ("Scope: " <> scopeTextFromIntent intent)
    , bullet ("Explorer: " <> explorerText report)
    , bullet ("CBOR fingerprint: " <> cborFingerprint (tbsTxCbor success))
    , bullet
        ( "Validity: "
            <> renderValidityInterval
                (trNetwork report)
                (tiValidityInterval identity)
        )
    , bullet ("Conservation: " <> conservationLine report)
    , bullet ("CIP-1694 rationale: " <> rationaleLine intent)
    , bullet ("Auxiliary data: " <> metadataLine (trMetadata report))
    ]
  where
    report = tbsReport success
    identity = trIdentity report

intentTitle :: SomeTreasuryIntent -> Text
intentTitle (SomeTreasuryIntent sa intent) =
    actionText sa <> " on " <> sjId (tiScope intent)

actionTextFromIntent :: SomeTreasuryIntent -> Text
actionTextFromIntent (SomeTreasuryIntent sa _) =
    actionText sa

scopeTextFromIntent :: SomeTreasuryIntent -> Text
scopeTextFromIntent (SomeTreasuryIntent _ intent) =
    sjId (tiScope intent)

actionText :: SAction a -> Text
actionText = \case
    SSwap -> "swap"
    SDisburse -> "disburse"
    SWithdraw -> "withdraw"
    SReorganize -> "reorganize"

rationaleLine :: SomeTreasuryIntent -> Text
rationaleLine (SomeTreasuryIntent _ intent) =
    rjLabel rationale
        <> " - "
        <> rjDescription rationale
        <> "; "
        <> rjJustification rationale
        <> "; destination "
        <> rjDestinationLabel rationale
  where
    rationale = tiRationale intent

metadataLine :: MetadataSummary -> Text
metadataLine metadata =
    case msAuxiliaryDataHash metadata of
        Nothing -> label <> "; no auxiliary data hash"
        Just h -> label <> "; hash " <> h
  where
    label =
        if msCip1694LabelPresent metadata
            then "CIP-1694 label present"
            else "CIP-1694 label absent"

explorerText :: TransactionReport -> Text
explorerText report =
    case explorerUrl report of
        Just url -> url
        Nothing -> "no public explorer for " <> trNetwork report

explorerUrl :: TransactionReport -> Maybe Text
explorerUrl report =
    (<> tiTxId (trIdentity report)) <$> base
  where
    base =
        case trNetwork report of
            "mainnet" -> Just "https://cardanoscan.io/transaction/"
            "preprod" -> Just "https://preprod.cardanoscan.io/transaction/"
            "preview" -> Just "https://preview.cardanoscan.io/transaction/"
            _ -> Nothing

cborFingerprint :: TxCborHex -> Text
cborFingerprint (TxCborHex hex) =
    shown <> " (" <> tshow (T.length hex) <> " hex chars)"
  where
    shown
        | T.length hex <= 32 = hex
        | otherwise = T.take 16 hex <> "..." <> T.takeEnd 16 hex

conservationLine :: TransactionReport -> Text
conservationLine report =
    "inputs "
        <> formatValueSummary inputTotal
        <> " = outputs "
        <> formatValueSummary outputTotal
        <> " + fee "
        <> formatValueSummary fee
        <> ", residual "
        <> formatValueSummary residual
  where
    wallet = trWalletAccounting report
    treasury = trTreasuryAccounting report
    inputTotal =
        sumValueSummaries $
            fmap usValue (waInputs wallet)
                <> fmap usValue (taInputs treasury)
    outputTotal = sumValueSummaries (poValue <$> trOutputs report)
    fee =
        ValueSummary
            { vsLovelace = waFeeLovelace wallet
            , vsAssets = Map.empty
            }
    residual =
        inputTotal `subtractValueSummary` (outputTotal `addValueSummary` fee)

consumedInputLines
    :: SomeTreasuryIntent -> TransactionReport -> AddressBook -> [Text]
consumedInputLines (SomeTreasuryIntent _ intent) report addressBook =
    walletLines <> treasuryLines
  where
    walletLabel =
        formatAddress
            (resolveAddress addressBook (wjAddress (tiWallet intent)))
            (wjAddress (tiWallet intent))
    treasuryLabel =
        formatAddress
            (resolveAddress addressBook (sjTreasuryAddress scope))
            (sjTreasuryAddress scope)
    scope = tiScope intent

    walletLines =
        renderInput (walletLabel <> " input") <$> waInputs wallet
    treasuryLines =
        renderInput (treasuryLabel <> " input") <$> taInputs treasury

    wallet = trWalletAccounting report
    treasury = trTreasuryAccounting report

renderInput :: Text -> UtxoSummary -> Text
renderInput label input =
    bullet $
        label
            <> " "
            <> truncateIdentifier (usTxIn input)
            <> ": "
            <> formatValueSummary (usValue input)

producedOutputLines :: AddressBook -> [ProducedOutput] -> [Text]
producedOutputLines addressBook outputs =
    renderGroup <$> groupOutputs outputs
  where
    renderGroup group =
        bullet $
            tshow (ogCount group)
                <> " x "
                <> producedOutputRoleText (ogRole group)
                <> " -> "
                <> ogDestination group
                <> ": "
                <> formatValueSummary (ogValue group)

    groupOutputs =
        foldl' addOutput []

    addOutput [] output = [newGroup output]
    addOutput (group : rest) output
        | groupMatches group output =
            group{ogCount = ogCount group + 1} : rest
        | otherwise =
            group : addOutput rest output

    newGroup output =
        OutputGroup
            { ogRole = poRole output
            , ogDestination = outputDestination output
            , ogValue = poValue output
            , ogCount = 1
            }

    groupMatches group output =
        ogRole group == poRole output
            && ogDestination group == outputDestination output
            && ogValue group == poValue output

    outputDestination output =
        formatAddress
            (resolveAddress addressBook (poAddress output))
            (poAddress output)

referenceInputLines
    :: ReferenceInputMap -> TransactionReport -> [Text]
referenceInputLines referenceInputs report =
    case trReferenceInputs report of
        [] -> [bullet "none"]
        inputs ->
            [ bullet $
                formatReferenceInput
                    (resolveReferenceInput referenceInputs txIn)
                    txIn
            | txIn <- inputs
            ]

signerLines :: IdentityMap -> TransactionReport -> [Text]
signerLines identityMap report =
    case trSigners report of
        [] -> [bullet "none"]
        signers ->
            [ bullet $
                formatKeyHash
                    (resolveSigner identityMap (srKeyHash signer))
                    (srKeyHash signer)
                    <> " ("
                    <> signerSourceLabel (srSource signer)
                    <> ")"
            | signer <- signers
            ]

signerSourceLabel :: SignerSource -> Text
signerSourceLabel = \case
    SourceSelectedScopeOwner -> "selected scope owner"
    SourceExtraSigner -> "extra signer"
    SourceIntentRequiredSigner -> "intent required signer"
    SourceTxBodyRequiredSigner -> "tx-body required signer"

formatValueSummary :: ValueSummary -> Text
formatValueSummary value =
    formatLovelace (vsLovelace value) <> assetSuffix
  where
    assetSuffix
        | Map.null (vsAssets value) = ""
        | otherwise =
            " + assets "
                <> T.intercalate
                    ", "
                    [ formatAssetQuantity policy asset quantity
                    | (policy, assets) <- Map.toList (vsAssets value)
                    , (asset, quantity) <- sortOn fst (Map.toList assets)
                    ]

formatAssetQuantity :: Text -> Text -> Integer -> Text
formatAssetQuantity policy asset quantity =
    assetLabel <> "=" <> tshow quantity
  where
    assetLabel =
        case labelAsset policy asset of
            Just label -> label
            Nothing ->
                "unresolved asset ("
                    <> truncateIdentifier policy
                    <> "."
                    <> truncateIdentifier asset
                    <> ")"

formatLovelace :: Integer -> Text
formatLovelace lovelace =
    tshow lovelace <> " lovelace (" <> adaText lovelace <> " ADA)"

adaText :: Integer -> Text
adaText lovelace =
    sign
        <> tshow whole
        <> "."
        <> T.justifyRight 6 '0' (tshow fractional)
  where
    (whole, fractional) = abs lovelace `quotRem` 1_000_000
    sign = if lovelace < 0 then "-" else ""

tshow :: (Show a) => a -> Text
tshow = T.pack . show
