{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Api.State
Description : Indexer-backed state read adapters for the HTTP API
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Small HTTP-facing adapters for state-style reads. UTxOs and pending
orders are read through the supplied 'Provider'; the API binary supplies
the indexer-backed provider, so these handlers do not perform node UTxO
queries.
-}
module Amaru.Treasury.Api.State
    ( -- * Filters
      ScopeUtxoFilter (..)

      -- * Indexer-backed reads
    , queryScopeState
    , queryScopeUtxos
    , queryPending

      -- * Metadata projections
    , registryResponseFromMetadata
    , scriptsResponseFromMetadata
    ) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx.Out (datumTxOutL, valueTxOutL)
import Cardano.Ledger.BaseTypes (txIxToInt)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (ScriptHash (..), extractHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.Plutus.Data
    ( Datum (..)
    , binaryDataToData
    , getPlutusData
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.List (partition)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))

import Amaru.Treasury.Api.Types
    ( PendingResponse (..)
    , PendingScope (..)
    , RegistryResponse (..)
    , RegistryScope (..)
    , ScopeScripts (..)
    , ScopeUtxosResponse (..)
    , ScriptRefResponse (..)
    , ScriptsResponse (..)
    )
import Amaru.Treasury.Backend (Provider (..))
import Amaru.Treasury.Cli.Common (filterFundUtxos)
import Amaru.Treasury.Constants
    ( usdmAssetHex
    , usdmPolicyHex
    )
import Amaru.Treasury.Inspect (buildInspectReport)
import Amaru.Treasury.Inspect.SwapOrderDatum
    ( parseSwapOrderDatum
    )
import Amaru.Treasury.Inspect.Types
    ( ChainTip (..)
    , DeploymentAnchor (..)
    , InspectReport (..)
    , OtherAsset (..)
    , Outref (..)
    , ParsedSwapOrder
    , ScopeSection (..)
    , TreasuryUtxo (..)
    )
import Amaru.Treasury.IntentJSON.Common (parseAddr)
import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , ScriptRef (..)
    , TreasuryMetadata (..)
    )
import Amaru.Treasury.Scope (ScopeId)

-- | Query filters for @GET /v1/scope/<scope>/utxos@.
data ScopeUtxoFilter = ScopeUtxoFilter
    { sufAsset :: !(Maybe Text)
    -- ^ @ada@, @usdm@, @policy@, or @policy.assetName@.
    , sufMinLovelace :: !(Maybe Integer)
    , sufLimit :: !(Maybe Int)
    }
    deriving stock (Eq, Show)

-- | Build one scope state section using indexer-backed UTxO reads.
queryScopeState
    :: Provider IO
    -> TreasuryMetadata
    -> Addr
    -> ScopeId
    -> IO ScopeSection
queryScopeState provider metadata swapAddr scope = do
    treasuryUtxos <- queryScopeTreasuryUtxos provider metadata scope
    pending <- queryPendingOrders provider swapAddr
    case irScopes $
        buildInspectReport
            metadata
            dummyTip
            dummyAnchor
            (Map.singleton scope treasuryUtxos)
            pending
            (Just scope) of
        [section] -> pure section
        _ ->
            fail $
                "queryScopeState: scope not found in metadata: "
                    <> show scope

-- | Build the UTxO response for one scope and apply request filters.
queryScopeUtxos
    :: Provider IO
    -> TreasuryMetadata
    -> Addr
    -> ScopeId
    -> ScopeUtxoFilter
    -> IO ScopeUtxosResponse
queryScopeUtxos provider metadata swapAddr scope flt = do
    section <- queryScopeState provider metadata swapAddr scope
    pure
        ScopeUtxosResponse
            { surScope = scope
            , surEntries =
                applyUtxoFilter flt (ssTreasuryUtxos section)
            }

-- | Query pending swap orders grouped by treasury scope.
queryPending
    :: Provider IO
    -> TreasuryMetadata
    -> Addr
    -> Maybe ScopeId
    -> IO PendingResponse
queryPending provider metadata swapAddr mScope = do
    pending <- queryPendingOrders provider swapAddr
    let sections =
            irScopes $
                buildInspectReport
                    metadata
                    dummyTip
                    dummyAnchor
                    Map.empty
                    pending
                    mScope
    pure
        PendingResponse
            { prScope = mScope
            , prEntries =
                [ PendingScope
                    { psScope = ssScope section
                    , psOrders = ssPendingOrders section
                    }
                | section <- sections
                ]
            }

-- | Project deployment registry metadata into the HTTP response shape.
registryResponseFromMetadata :: TreasuryMetadata -> RegistryResponse
registryResponseFromMetadata TreasuryMetadata{..} =
    RegistryResponse
        { rrScopeOwners = tmScopeOwners
        , rrScopes =
            [ RegistryScope
                { rsScope = scope
                , rsOwner = smOwner sm
                , rsBudget = smBudget sm
                , rsAddress = smAddress sm
                }
            | (scope, sm) <- Map.toList tmTreasuries
            ]
        }

-- | Project deployment script metadata into the HTTP response shape.
scriptsResponseFromMetadata :: TreasuryMetadata -> ScriptsResponse
scriptsResponseFromMetadata TreasuryMetadata{..} =
    ScriptsResponse
        { srScopes =
            [ ScopeScripts
                { ssrScope = scope
                , ssrTreasury = scriptRefResponse (smTreasury sm)
                , ssrPermissions = scriptRefResponse (smPermissions sm)
                , ssrRegistry = scriptRefResponse (smRegistry sm)
                }
            | (scope, sm) <- Map.toList tmTreasuries
            ]
        }

scriptRefResponse :: ScriptRef -> ScriptRefResponse
scriptRefResponse ScriptRef{..} =
    ScriptRefResponse
        { srrHash = srHash
        , srrDeployedAt = srDeployedAt
        }

queryScopeTreasuryUtxos
    :: Provider IO
    -> TreasuryMetadata
    -> ScopeId
    -> IO [TreasuryUtxo]
queryScopeTreasuryUtxos provider metadata scope =
    case Map.lookup scope (tmTreasuries metadata) of
        Nothing ->
            fail $
                "queryScopeTreasuryUtxos: scope not found in metadata: "
                    <> show scope
        Just sm -> do
            addr <- parseAddrOrFail "treasury address" (smAddress sm)
            utxos <- queryUTxOs provider addr
            pure
                [ toTreasuryUtxo txin (txOut ^. valueTxOutL)
                | (txin, txOut) <- filterFundUtxos utxos
                ]

queryPendingOrders
    :: Provider IO
    -> Addr
    -> IO [(Outref, ParsedSwapOrder)]
queryPendingOrders provider swapAddr = do
    utxos <- queryUTxOs provider swapAddr
    pure $
        mapMaybe
            ( \(txin, txOut) ->
                case txOut ^. datumTxOutL of
                    Datum d ->
                        (,) (txInToOutref txin)
                            <$> parseSwapOrderDatum
                                (getPlutusData (binaryDataToData d))
                    _ -> Nothing
            )
            utxos

applyUtxoFilter :: ScopeUtxoFilter -> [TreasuryUtxo] -> [TreasuryUtxo]
applyUtxoFilter ScopeUtxoFilter{..} =
    takeMaybe sufLimit
        . filter (matchesMinLovelace sufMinLovelace)
        . filter (matchesAsset sufAsset)

matchesMinLovelace :: Maybe Integer -> TreasuryUtxo -> Bool
matchesMinLovelace Nothing _ = True
matchesMinLovelace (Just minimumLovelace) u =
    tuLovelace u >= minimumLovelace

matchesAsset :: Maybe Text -> TreasuryUtxo -> Bool
matchesAsset Nothing _ = True
matchesAsset (Just asset) u
    | T.toLower asset == "ada" = tuLovelace u > 0
    | T.toLower asset == "usdm" = tuUsdm u > 0
    | otherwise = any (otherAssetMatches asset) (tuOtherAssets u)

otherAssetMatches :: Text -> OtherAsset -> Bool
otherAssetMatches asset OtherAsset{..} =
    asset == oaPolicy || asset == oaPolicy <> "." <> oaAssetName

takeMaybe :: Maybe Int -> [a] -> [a]
takeMaybe Nothing = id
takeMaybe (Just n) = take n

toTreasuryUtxo :: TxIn -> MaryValue -> TreasuryUtxo
toTreasuryUtxo txin mv =
    let (lovelace, usdm, others) = splitValue mv
    in  TreasuryUtxo
            { tuOutref = txInToOutref txin
            , tuLovelace = lovelace
            , tuUsdm = usdm
            , tuOtherAssets = others
            , tuDatumHash = Nothing
            }

splitValue :: MaryValue -> (Integer, Integer, [OtherAsset])
splitValue (MaryValue (Coin lovelace) (MultiAsset ma)) =
    let entries =
            [ (policyHexT pid, assetNameHexT an, qty)
            | (pid, inner) <- Map.toList ma
            , (an, qty) <- Map.toList inner
            , qty > 0
            ]
        (usdmEntries, otherEntries) = partition isUsdm entries
        isUsdm (p, n, _) =
            p == usdmPolicyHex && n == usdmAssetHex
        usdm = sum [q | (_, _, q) <- usdmEntries]
        others =
            [ OtherAsset
                { oaPolicy = p
                , oaAssetName = n
                , oaQuantity = q
                }
            | (p, n, q) <- otherEntries
            ]
    in  (lovelace, usdm, others)

policyHexT :: PolicyID -> Text
policyHexT (PolicyID (ScriptHash h)) =
    TE.decodeUtf8 (B16.encode (hashToBytes h))

assetNameHexT :: AssetName -> Text
assetNameHexT (AssetName bs) =
    TE.decodeUtf8 (B16.encode (SBS.fromShort bs))

txInToOutref :: TxIn -> Outref
txInToOutref (TxIn (TxId h) ix) =
    Outref
        (TE.decodeUtf8 (B16.encode (hashToBytes (extractHash h))))
        (fromIntegral (txIxToInt ix))

parseAddrOrFail :: String -> Text -> IO Addr
parseAddrOrFail label raw =
    case parseAddr raw of
        Right addr -> pure addr
        Left err -> fail (label <> ": " <> err)

dummyTip :: ChainTip
dummyTip =
    ChainTip
        { ctSlot = 0
        , ctBlockHash = Nothing
        }

dummyAnchor :: DeploymentAnchor
dummyAnchor =
    DeploymentAnchor
        Outref
            { orTxId =
                "0000000000000000000000000000000000000000000000000000000000000000"
            , orIx = 0
            }
