{- |
Module      : Amaru.Treasury.Inspect.Render
Description : JSON and human renderers for the @treasury-inspect@ report
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

JSON encoding follows the contract in
@specs/109-treasury-inspect/contracts/treasury-inspect-schema.json@.
The human renderer is for terminal use; both renderers share the
same underlying 'InspectReport' value.
-}
module Amaru.Treasury.Inspect.Render
    ( -- * JSON
      encodeReport

      -- * Human
    , renderHuman
    ) where

import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (..)
    , NumberFormat (..)
    , encodePretty'
    )
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.Inspect.Types
    ( ChainTip (..)
    , DeploymentAnchor (..)
    , InspectReport (..)
    , OtherAsset (..)
    , Outref (..)
    , PendingSwapOrder (..)
    , ScopeSection (..)
    , ScopeTotals (..)
    , TreasuryUtxo (..)
    )
import Amaru.Treasury.Scope (scopeText)

-- ----------------------------------------------------
-- JSON
-- ----------------------------------------------------

{- | Encode the report as pretty-printed JSON with the
project-standard 4-space indent, alphabetical key order, and a
trailing newline. The byte shape is the contract checked by
@just schema-check@ in Slice C.
-}
encodeReport :: InspectReport -> ByteString
encodeReport = encodePretty' inspectJsonConfig

inspectJsonConfig :: Config
inspectJsonConfig =
    Config
        { confIndent = Spaces 4
        , confCompare = compare
        , confNumFormat = Generic
        , confTrailingNewline = True
        }

-- ----------------------------------------------------
-- Human
-- ----------------------------------------------------

{- | Render the report in a terminal-friendly format. Numbers
follow the project convention (six decimal places for ADA and
USDM; raw quantities for other assets and the SundaeSwap fee).
-}
renderHuman :: InspectReport -> Text
renderHuman r =
    T.unlines $
        [ "Chain tip:        slot "
            <> T.pack (show (ctSlot (irChainTip r)))
            <> renderBlockHash (ctBlockHash (irChainTip r))
        , "Deployment anchor: scope-owners "
            <> renderOutref
                (unDeploymentAnchor (irDeployment r))
        , ""
        ]
            <> concatMap renderScope (irScopes r)

renderBlockHash :: Maybe Text -> Text
renderBlockHash Nothing = ""
renderBlockHash (Just h) = "  block " <> short12 h <> "…"

renderScope :: ScopeSection -> [Text]
renderScope s =
    [ "[" <> scopeText (ssScope s) <> "] " <> ssTreasuryAddress s
    , utxosLine
    ]
        <> map ("    " <>) utxoLines
        <> [totalsLine]
        <> [pendingLine]
        <> map ("    " <>) pendingLines
        <> [""]
  where
    utxos = ssTreasuryUtxos s
    nUtxos = length utxos
    utxosLine =
        "  Treasury UTxOs ("
            <> T.pack (show nUtxos)
            <> "):"
            <> if nUtxos == 0 then "  (no UTxOs)" else ""

    utxoLines = map renderUtxo utxos

    totalsLine = "  " <> renderTotals (ssTreasuryTotals s)

    pending = ssPendingOrders s
    nPending = length pending
    pendingLine =
        "  Pending SundaeSwap orders ("
            <> T.pack (show nPending)
            <> "):"
            <> if nPending == 0
                then "  (no pending orders)"
                else ""

    pendingLines = map renderPending pending

renderUtxo :: TreasuryUtxo -> Text
renderUtxo u =
    renderOutref (tuOutref u)
        <> "   "
        <> renderAda (tuLovelace u)
        <> " ADA   "
        <> renderUsdm (tuUsdm u)
        <> " USDM"
        <> renderOtherAssetsBrief (tuOtherAssets u)

renderOtherAssetsBrief :: [OtherAsset] -> Text
renderOtherAssetsBrief [] = ""
renderOtherAssetsBrief xs =
    "   ("
        <> T.pack (show (length xs))
        <> " other-asset entr"
        <> (if length xs == 1 then "y" else "ies")
        <> ")"

renderTotals :: ScopeTotals -> Text
renderTotals t =
    "Totals: "
        <> renderAda (stLovelace t)
        <> " ADA  "
        <> renderUsdm (stUsdm t)
        <> " USDM"
        <> if stOtherAssetsCount t == 0
            then "  (no other assets)"
            else
                "  ("
                    <> T.pack (show (stOtherAssetsCount t))
                    <> " other-asset entr"
                    <> ( if stOtherAssetsCount t == 1
                            then "y"
                            else "ies"
                       )
                    <> ")"

renderPending :: PendingSwapOrder -> Text
renderPending p =
    renderOutref (psoOutref p)
        <> "   "
        <> renderAda (psoLovelaceIn p)
        <> " ADA   ≥ "
        <> renderUsdm (psoMinUsdmOut p)
        <> " USDM  fee "
        <> renderAda (psoSundaeFeeLovelace p)
        <> " ADA"

renderOutref :: Outref -> Text
renderOutref o = short12 (orTxId o) <> "…#" <> T.pack (show (orIx o))

short12 :: Text -> Text
short12 = T.take 12

{- | Both ADA (lovelace) and USDM use six decimal places on
Cardano. Format as @<whole>.<six-fractional-digits>@.
-}
renderAda :: Integer -> Text
renderAda = renderSixDecimals

renderUsdm :: Integer -> Text
renderUsdm = renderSixDecimals

renderSixDecimals :: Integer -> Text
renderSixDecimals n =
    let (whole, frac) = n `divMod` 1_000_000
        fracText = T.justifyRight 6 '0' (T.pack (show frac))
    in  T.pack (show whole) <> "." <> fracText
