{- |
Module      : Amaru.Treasury.Inspect
Description : Pure assembly for the @treasury-inspect@ report
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The pure heart of @treasury-inspect@: given the sampled chain
facts (metadata, chain tip, UTxOs at every relevant address, and
the parsed inline datums of every UTxO at the SundaeSwap order
address), produce the 'InspectReport'. No I/O — the I/O glue
lives in @Amaru.Treasury.Cli.TreasuryInspect@ (Slice D).
-}
module Amaru.Treasury.Inspect
    ( buildInspectReport
    ) where

import Data.ByteString.Base16 qualified as B16
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Amaru.Treasury.Inspect.Types
    ( ChainTip
    , DeploymentAnchor (..)
    , InspectReport (..)
    , OtherAsset (..)
    , Outref
    , ParsedSwapOrder (..)
    , PendingSwapOrder (..)
    , ScopeSection (..)
    , ScopeTotals (..)
    , TreasuryUtxo (..)
    )
import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , ScriptRef (..)
    , TreasuryMetadata (..)
    )
import Amaru.Treasury.Scope (ScopeId, allScopes)

{- | Build the report from sampled chain facts. Pure; total.

The /scope set/ is 'allScopes' (the five scopes the metadata
enumerates), then filtered by the @--scope@ value when present.
For each surviving scope, the treasury UTxOs come from the input
map and the pending orders come from filtering the parsed
swap-order set by destination treasury hash.

Pending orders that do not match any of the metadata's scope
treasury hashes are silently dropped — they are SundaeSwap orders
funded by something outside this deployment.
-}
buildInspectReport
    :: TreasuryMetadata
    -> ChainTip
    -> DeploymentAnchor
    -> Map ScopeId [TreasuryUtxo]
    -> [(Outref, ParsedSwapOrder)]
    -> Maybe ScopeId
    -> InspectReport
buildInspectReport
    metadata
    tip
    anchor
    treasuryUtxos
    pendingOrders
    filterScope =
        InspectReport
            { irChainTip = tip
            , irDeployment = anchor
            , irScopes = sections
            }
      where
        sections =
            [ scopeSection scope scopeMeta
            | scope <- allScopes
            , keep scope
            , Just scopeMeta <-
                [Map.lookup scope (tmTreasuries metadata)]
            ]

        keep scope = case filterScope of
            Nothing -> True
            Just s -> s == scope

        scopeSection scope scopeMeta =
            let scriptHash = srHash (smTreasury scopeMeta)
                utxos =
                    Map.findWithDefault
                        []
                        scope
                        treasuryUtxos
            in  ScopeSection
                    { ssScope = scope
                    , ssTreasuryAddress = smAddress scopeMeta
                    , ssTreasuryScriptHash = scriptHash
                    , ssTreasuryUtxos = utxos
                    , ssTreasuryTotals = totals utxos
                    , ssPendingOrders =
                        filterPendingForScope
                            scriptHash
                            pendingOrders
                    }

-- | Aggregate ADA, USDM and other-asset counts.
totals :: [TreasuryUtxo] -> ScopeTotals
totals utxos =
    ScopeTotals
        { stLovelace = sum (map tuLovelace utxos)
        , stUsdm = sum (map tuUsdm utxos)
        , stOtherAssetsCount =
            Set.size $
                Set.fromList
                    [ (oaPolicy a, oaAssetName a)
                    | u <- utxos
                    , a <- tuOtherAssets u
                    ]
        }

{- | Keep only orders whose datum destination is this scope's
treasury hash. The match compares the metadata-side hex text
against the hex-encoded bytes from the parsed datum.
-}
filterPendingForScope
    :: T.Text
    -> [(Outref, ParsedSwapOrder)]
    -> [PendingSwapOrder]
filterPendingForScope scriptHashHex =
    map convert . filter (matches . snd)
  where
    matches order =
        TE.decodeUtf8
            (B16.encode (posDestinationTreasuryHash order))
            == scriptHashHex

    convert (outref, parsed) =
        PendingSwapOrder
            { psoOutref = outref
            , psoLovelaceIn = posLovelaceIn parsed
            , psoMinUsdmOut = posMinUsdmOut parsed
            , psoSundaeFeeLovelace =
                posSundaeFeeLovelace parsed
            }
