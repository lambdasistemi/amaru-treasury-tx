{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Report.Render
Description : Pure Markdown renderer for tx-build reports
License     : Apache-2.0

Renders a decoded build-output envelope into deterministic Markdown.
This module is pure; CLI stream handling lives outside the renderer.
-}
module Amaru.Treasury.Report.Render
    ( RenderError (..)
    , RenderOutput (..)
    , renderBuildOutput
    , renderSuccessReport
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
    )
import Amaru.Treasury.Report
    ( BuildFailure (..)
    , MetadataSummary (..)
    , ProducedOutput (..)
    , SignerRequirement (..)
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
    , ogAddress :: Text
    , ogValue :: ValueSummary
    , ogCount :: Int
    }
    deriving stock (Eq, Show)

renderBuildOutput :: TxBuildOutput -> Either RenderError RenderOutput
renderBuildOutput output =
    case txoResult output of
        TxBuildOutputSuccess success ->
            Right (renderSuccessReport (txoIntent output) success)
        TxBuildOutputFailure failure ->
            Left (RenderBuildFailure failure)

renderSuccessReport
    :: SomeTreasuryIntent -> TxBuildSuccess -> RenderOutput
renderSuccessReport intent success =
    RenderOutput . renderMarkdown $
        [ heading1 (intentTitle intent)
        , blank
        ]
            <> leadingLines intent success
            <> [ blank
               , heading2 "Produced Outputs"
               ]
            <> producedOutputLines (trOutputs report)
            <> [ blank
               , heading2 "Required Signers"
               ]
            <> signerLines report
  where
    report = tbsReport success

leadingLines :: SomeTreasuryIntent -> TxBuildSuccess -> [Text]
leadingLines intent success =
    [ bullet ("Transaction id: " <> tiTxId identity)
    , bullet ("Explorer: " <> explorerUrl report)
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

explorerUrl :: TransactionReport -> Text
explorerUrl report =
    base <> tiTxId (trIdentity report)
  where
    base =
        case trNetwork report of
            "preprod" -> "https://preprod.cardanoscan.io/transaction/"
            _ -> "https://cardanoscan.io/transaction/"

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

producedOutputLines :: [ProducedOutput] -> [Text]
producedOutputLines outputs =
    renderGroup <$> groupOutputs outputs

groupOutputs :: [ProducedOutput] -> [OutputGroup]
groupOutputs =
    foldl' addOutput []

addOutput :: [OutputGroup] -> ProducedOutput -> [OutputGroup]
addOutput [] output = [newGroup output]
addOutput (group : rest) output
    | groupMatches group output =
        group{ogCount = ogCount group + 1} : rest
    | otherwise =
        group : addOutput rest output

newGroup :: ProducedOutput -> OutputGroup
newGroup output =
    OutputGroup
        { ogRole = poRole output
        , ogAddress = poAddress output
        , ogValue = poValue output
        , ogCount = 1
        }

groupMatches :: OutputGroup -> ProducedOutput -> Bool
groupMatches group output =
    ogRole group == poRole output
        && ogAddress group == poAddress output
        && ogValue group == poValue output

renderGroup :: OutputGroup -> Text
renderGroup group =
    bullet $
        tshow (ogCount group)
            <> " x "
            <> producedOutputRoleText (ogRole group)
            <> " -> "
            <> ogAddress group
            <> ": "
            <> formatValueSummary (ogValue group)

signerLines :: TransactionReport -> [Text]
signerLines report =
    case trSigners report of
        [] -> [bullet "none"]
        signers ->
            [ bullet (srKeyHash signer)
            | signer <- signers
            ]

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
                    [ policy <> "." <> asset <> "=" <> tshow quantity
                    | (policy, assets) <- Map.toList (vsAssets value)
                    , (asset, quantity) <- sortOn fst (Map.toList assets)
                    ]

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
