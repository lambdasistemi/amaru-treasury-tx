{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Tx.SwapIntentJSON
Description : JSON parser for the @swap@ CLI intent
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Parses the user-facing @intent.json@ for the
@amaru-treasury-tx swap@ subcommand into the underlying
ledger types, computes the per-chunk SundaeSwap order
datums from a single rate parameter, and assembles the
'SwapIntent' + rationale 'Metadatum' the
@SwapBuild.runSwapBuild@ driver consumes.

The JSON schema is documented in
@specs\/001-treasury-tx-cli\/contracts\/swap-intent.schema.json@.
-}
module Amaru.Treasury.Tx.SwapIntentJSON
    ( -- * Top-level intent
      SwapIntentJSON (..)
    , Wallet (..)
    , ScopeInputs (..)
    , SwapInputs (..)
    , RationaleInputs (..)

      -- * Decoding
    , decodeSwapIntent
    , decodeSwapIntentFile

      -- * Translation
    , translateIntent
    , TranslatedIntent (..)

      -- * Re-usable parsers
    , parseAddr
    ) where

import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , eitherDecodeFileStrict
    , object
    , withObject
    , (.:)
    , (.:?)
    , (.=)
    )
import Data.Aeson qualified as A
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Word (Word64)

import Cardano.Ledger.Address (AccountAddress, Addr)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))

import Amaru.Treasury.AuxData (RationaleBody (..), rationaleMetadatum)
import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytes
    , decodeHexBytesAny
    , parseAddr
    , parseGuardKeyHash
    , parseRewardAccount
    , parseTxIn
    )
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , SwapOrderDatumParams (..)
    , SwapOrderOut (..)
    , swapOrderDatum
    )

-- ----------------------------------------------------
-- JSON shape
-- ----------------------------------------------------

data Wallet = Wallet
    { wTxIn :: !Text
    -- ^ @\<txid hex\>#\<ix\>@
    , wAddress :: !Text
    -- ^ bech32 @addr1…@
    }
    deriving (Show)

data ScopeInputs = ScopeInputs
    { siTreasuryAddress_ :: !Text
    , siTreasuryUtxos_ :: ![Text]
    , siTreasuryLeftoverLovelace_ :: !Integer
    , siTreasuryScriptHash_ :: !Text
    , siPermissionsRewardAccount_ :: !Text
    , siScopesDeployedAt_ :: !Text
    , siPermissionsDeployedAt_ :: !Text
    , siTreasuryDeployedAt_ :: !Text
    , siRegistryDeployedAt_ :: !Text
    , siRegistryPolicyId_ :: !Text
    }
    deriving (Show)

data SwapInputs = SwapInputs
    { swSwapOrderAddress :: !Text
    , swChunkSizeLovelace :: !Integer
    , swAmountLovelace :: !Integer
    , swExtraPerChunkLovelace :: !Integer
    , swRateNumerator :: !Integer
    , swRateDenominator :: !Integer
    , swPoolId :: !Text
    , swCoreOwner :: !Text
    , swOpsOwner :: !Text
    , swNetworkComplianceOwner :: !Text
    , swMiddlewareOwner :: !Text
    , swSundaeProtocolFeeLovelace :: !Integer
    , swUsdmPolicy :: !Text
    , swUsdmToken :: !Text
    }
    deriving (Show)

data RationaleInputs = RationaleInputs
    { riEvent :: !Text
    , riLabel :: !Text
    , riDescription :: !Text
    , riDestinationLabel :: !Text
    , riJustification :: !Text
    }
    deriving (Show)

data SwapIntentJSON = SwapIntentJSON
    { sijWallet :: !Wallet
    , sijScope :: !ScopeInputs
    , sijSwap :: !SwapInputs
    , sijSigners :: ![Text]
    , sijValidityUpperBoundSlot :: !Word64
    , sijRationale :: !RationaleInputs
    }
    deriving (Show)

instance FromJSON Wallet where
    parseJSON = withObject "Wallet" $ \o ->
        Wallet <$> o .: "txIn" <*> o .: "address"

instance FromJSON ScopeInputs where
    parseJSON = withObject "ScopeInputs" $ \o ->
        ScopeInputs
            <$> o .: "treasuryAddress"
            <*> o .: "treasuryUtxos"
            <*> o .: "treasuryLeftoverLovelace"
            <*> o .: "treasuryScriptHash"
            <*> o .: "permissionsRewardAccount"
            <*> o .: "scopesDeployedAt"
            <*> o .: "permissionsDeployedAt"
            <*> o .: "treasuryDeployedAt"
            <*> o .: "registryDeployedAt"
            <*> o .: "registryPolicyId"

instance FromJSON SwapInputs where
    parseJSON = withObject "SwapInputs" $ \o ->
        SwapInputs
            <$> o .: "swapOrderAddress"
            <*> o .: "chunkSizeLovelace"
            <*> o .: "amountLovelace"
            <*> o .: "extraPerChunkLovelace"
            <*> o .: "rateNumerator"
            <*> o .: "rateDenominator"
            <*> o .: "poolId"
            <*> o .: "coreOwner"
            <*> o .: "opsOwner"
            <*> o .: "networkComplianceOwner"
            <*> o .: "middlewareOwner"
            <*> o .: "sundaeProtocolFeeLovelace"
            <*> o .: "usdmPolicy"
            <*> o .: "usdmToken"

instance FromJSON RationaleInputs where
    parseJSON = withObject "RationaleInputs" $ \o ->
        RationaleInputs
            . fromMaybe "disburse"
            <$> o .:? "event"
            <*> (fromMaybe "Swap ADA<->USDM" <$> o .:? "label")
            <*> o .: "description"
            <*> o .: "destinationLabel"
            <*> o .: "justification"

instance FromJSON SwapIntentJSON where
    parseJSON = withObject "SwapIntentJSON" $ \o ->
        SwapIntentJSON
            <$> o .: "wallet"
            <*> o .: "scope"
            <*> o .: "swap"
            <*> o .: "signers"
            <*> o .: "validityUpperBoundSlot"
            <*> o .: "rationale"

instance ToJSON Wallet where
    toJSON Wallet{..} =
        object
            [ "txIn" .= wTxIn
            , "address" .= wAddress
            ]

instance ToJSON ScopeInputs where
    toJSON ScopeInputs{..} =
        object
            [ "treasuryAddress" .= siTreasuryAddress_
            , "treasuryUtxos" .= siTreasuryUtxos_
            , "treasuryLeftoverLovelace"
                .= siTreasuryLeftoverLovelace_
            , "treasuryScriptHash" .= siTreasuryScriptHash_
            , "permissionsRewardAccount"
                .= siPermissionsRewardAccount_
            , "scopesDeployedAt" .= siScopesDeployedAt_
            , "permissionsDeployedAt" .= siPermissionsDeployedAt_
            , "treasuryDeployedAt" .= siTreasuryDeployedAt_
            , "registryDeployedAt" .= siRegistryDeployedAt_
            , "registryPolicyId" .= siRegistryPolicyId_
            ]

instance ToJSON SwapInputs where
    toJSON SwapInputs{..} =
        object
            [ "swapOrderAddress" .= swSwapOrderAddress
            , "chunkSizeLovelace" .= swChunkSizeLovelace
            , "amountLovelace" .= swAmountLovelace
            , "extraPerChunkLovelace" .= swExtraPerChunkLovelace
            , "rateNumerator" .= swRateNumerator
            , "rateDenominator" .= swRateDenominator
            , "poolId" .= swPoolId
            , "coreOwner" .= swCoreOwner
            , "opsOwner" .= swOpsOwner
            , "networkComplianceOwner" .= swNetworkComplianceOwner
            , "middlewareOwner" .= swMiddlewareOwner
            , "sundaeProtocolFeeLovelace"
                .= swSundaeProtocolFeeLovelace
            , "usdmPolicy" .= swUsdmPolicy
            , "usdmToken" .= swUsdmToken
            ]

instance ToJSON RationaleInputs where
    toJSON RationaleInputs{..} =
        object
            [ "event" .= riEvent
            , "label" .= riLabel
            , "description" .= riDescription
            , "destinationLabel" .= riDestinationLabel
            , "justification" .= riJustification
            ]

instance ToJSON SwapIntentJSON where
    toJSON SwapIntentJSON{..} =
        object
            [ "wallet" .= sijWallet
            , "scope" .= sijScope
            , "swap" .= sijSwap
            , "signers" .= sijSigners
            , "validityUpperBoundSlot"
                .= sijValidityUpperBoundSlot
            , "rationale" .= sijRationale
            ]

decodeSwapIntent :: BSL.ByteString -> Either String SwapIntentJSON
decodeSwapIntent = A.eitherDecode

decodeSwapIntentFile :: FilePath -> IO (Either String SwapIntentJSON)
decodeSwapIntentFile = eitherDecodeFileStrict

-- ----------------------------------------------------
-- Translation
-- ----------------------------------------------------

-- | The result of 'translateIntent'.
data TranslatedIntent = TranslatedIntent
    { tiSwapIntent :: !SwapIntent
    , tiWalletAddr :: !Addr
    , tiWalletTxIn :: !TxIn
    , tiRationale :: !Metadatum
    }

{- | Translate a parsed JSON intent into the typed
  ledger inputs that 'SwapBuild.runSwapBuild' expects.
-}
translateIntent
    :: SwapIntentJSON -> Either String TranslatedIntent
translateIntent SwapIntentJSON{..} = do
    walletAddr <- parseAddr (wAddress sijWallet)
    walletTxIn <- parseTxIn (wTxIn sijWallet)
    treasuryAddr <-
        parseAddr (siTreasuryAddress_ sijScope)
    swapOrderAddr <-
        parseAddr (swSwapOrderAddress sijSwap)
    treasuryUtxos <-
        traverse parseTxIn (siTreasuryUtxos_ sijScope)
    permissionsAcct <-
        parseRewardAccount (siPermissionsRewardAccount_ sijScope)
    scopesRef <- parseTxIn (siScopesDeployedAt_ sijScope)
    permissionsRef <-
        parseTxIn (siPermissionsDeployedAt_ sijScope)
    treasuryRef <-
        parseTxIn (siTreasuryDeployedAt_ sijScope)
    registryRef <-
        parseTxIn (siRegistryDeployedAt_ sijScope)
    registryPolicy <-
        decodeHexBytes 28 (siRegistryPolicyId_ sijScope)
    signers <- traverse parseGuardKeyHash sijSigners
    poolId <- decodeHexBytes 28 (swPoolId sijSwap)
    coreOwner <- decodeHexBytes 28 (swCoreOwner sijSwap)
    opsOwner <- decodeHexBytes 28 (swOpsOwner sijSwap)
    netcOwner <-
        decodeHexBytes 28 (swNetworkComplianceOwner sijSwap)
    midOwner <-
        decodeHexBytes 28 (swMiddlewareOwner sijSwap)
    treasurySh <-
        decodeHexBytes 28 (siTreasuryScriptHash_ sijScope)
    usdmPol <- decodeHexBytesAny (swUsdmPolicy sijSwap)
    usdmTok <- decodeHexBytesAny (swUsdmToken sijSwap)
    let dp =
            SwapOrderDatumParams
                { sodPoolId = poolId
                , sodCoreOwner = coreOwner
                , sodOpsOwner = opsOwner
                , sodNetworkComplianceOwner = netcOwner
                , sodMiddlewareOwner = midOwner
                , sodSundaeProtocolFeeLovelace =
                    swSundaeProtocolFeeLovelace sijSwap
                , sodTreasuryScriptHash = treasurySh
                , sodUsdmPolicy = usdmPol
                , sodUsdmToken = usdmTok
                }
        chunks =
            mkChunks
                (swChunkSizeLovelace sijSwap)
                (swAmountLovelace sijSwap)
                ( swRateNumerator sijSwap
                , swRateDenominator sijSwap
                )
                dp
        intent =
            SwapIntent
                { siWalletUtxo = walletTxIn
                , siSwapOrderAddress = swapOrderAddr
                , siSwapOrders = chunks
                , siSwapOrderExtraLovelace =
                    Coin (swExtraPerChunkLovelace sijSwap)
                , siTreasuryUtxos = treasuryUtxos
                , siTreasuryAddress = treasuryAddr
                , siTreasuryLeftoverLovelace =
                    Coin (siTreasuryLeftoverLovelace_ sijScope)
                , siTreasuryLeftoverAsset = Nothing
                , siRedeemerAmountLovelace =
                    Coin (swAmountLovelace sijSwap)
                , siPermissionsRewardAccount = permissionsAcct
                , siScopesDeployedAt = scopesRef
                , siPermissionsDeployedAt = permissionsRef
                , siTreasuryDeployedAt = treasuryRef
                , siRegistryDeployedAt = registryRef
                , siSigners = signers
                , siUpperBound =
                    SlotNo sijValidityUpperBoundSlot
                }
        rat = sijRationale
        body =
            RationaleBody
                { rbEvent = riEvent rat
                , rbLabel = riLabel rat
                , rbDescription = [riDescription rat]
                , rbDestinationLabel = riDestinationLabel rat
                , rbJustification = [riJustification rat]
                }
    pure
        TranslatedIntent
            { tiSwapIntent = intent
            , tiWalletAddr = walletAddr
            , tiWalletTxIn = walletTxIn
            , tiRationale =
                rationaleMetadatum body registryPolicy
            }

mkChunks
    :: Integer
    -- ^ chunkSize
    -> Integer
    -- ^ totalAmount
    -> (Integer, Integer)
    -- ^ (rateNum, rateDen)
    -> SwapOrderDatumParams
    -> [SwapOrderOut]
mkChunks chunkSize totalAmount (rNum, rDen) dp =
    let full = totalAmount `div` chunkSize
        rem' = totalAmount `mod` chunkSize
        usdm n = (n * rNum + rDen - 1) `div` rDen
        fullChunk =
            SwapOrderOut
                (Coin chunkSize)
                (swapOrderDatum dp chunkSize (usdm chunkSize))
        remChunk =
            SwapOrderOut
                (Coin rem')
                (swapOrderDatum dp rem' (usdm rem'))
        fulls = replicate (fromInteger full) fullChunk
    in  if rem' > 0 then fulls ++ [remChunk] else fulls

-- Parser helpers (parseAddr, parseTxIn, parseRewardAccount,
-- parseGuardKeyHash, decodeHexBytes, decodeHexBytesAny, mkHash28,
-- mkHash32, readEither) moved to
-- Amaru.Treasury.IntentJSON.Common in T008. The full module
-- itself is collapsed into Amaru.Treasury.IntentJSON in T028.
