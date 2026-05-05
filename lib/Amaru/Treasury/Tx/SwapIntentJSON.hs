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
    ) where

import Data.Aeson
    ( FromJSON (..)
    , eitherDecodeFileStrict
    , withObject
    , (.:)
    , (.:?)
    )
import Data.Aeson qualified as A
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Maybe (fromJust, fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64, Word8)

import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm, hashFromBytes)
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , decodeAddrEither
    )
import Cardano.Ledger.BaseTypes (Network (..), mkTxIxPartial)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential
    ( Credential (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))

import Amaru.Treasury.AuxData (RationaleBody (..), rationaleMetadatum)
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

-- ----------------------------------------------------
-- Helpers
-- ----------------------------------------------------

parseAddr :: Text -> Either String Addr
parseAddr t =
    case decodeAddrEither (TE.encodeUtf8 t) of
        Right a -> Right a
        Left e -> Left ("address: " <> show e)

parseTxIn :: Text -> Either String TxIn
parseTxIn t =
    case T.splitOn "#" t of
        [hHex, ixT] -> do
            ix <- readEither "txix" (T.unpack ixT)
            bs <- decodeHexBytes 32 hHex
            Right
                ( TxIn
                    (TxId (unsafeMakeSafeHash (mkHash32 bs)))
                    (mkTxIxPartial (toInteger (ix :: Word8)))
                )
        _ ->
            Left
                ( "txIn must be \"<hex>#<ix>\", got "
                    <> T.unpack t
                )

{- | Parse a reward-account credential as the 28-byte
hex of the stake-script hash. (Bech32 stake addresses
are not accepted at the JSON layer; the user already
supplies one hash, not a full address.)
-}
parseRewardAccount :: Text -> Either String AccountAddress
parseRewardAccount t = do
    bs <- decodeHexBytes 28 t
    Right
        ( AccountAddress
            Mainnet
            ( AccountId
                ( ScriptHashObj
                    (ScriptHash (mkHash28 bs))
                )
            )
        )

parseGuardKeyHash :: Text -> Either String (KeyHash Guard)
parseGuardKeyHash t = do
    bs <- decodeHexBytes 28 t
    Right (KeyHash (mkHash28 bs))

decodeHexBytes :: Int -> Text -> Either String ByteString
decodeHexBytes expected t =
    case B16.decode (TE.encodeUtf8 t) of
        Right bs
            | BS.length bs == expected -> Right bs
            | otherwise ->
                Left
                    ( "expected "
                        <> show expected
                        <> " bytes, got "
                        <> show (BS.length bs)
                    )
        Left e -> Left ("hex decode: " <> e)

decodeHexBytesAny :: Text -> Either String ByteString
decodeHexBytesAny t =
    case B16.decode (TE.encodeUtf8 t) of
        Right bs -> Right bs
        Left e -> Left ("hex decode: " <> e)

mkHash28 :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash28 = fromJust . hashFromBytes

mkHash32 :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash32 = fromJust . hashFromBytes

readEither :: (Read a) => String -> String -> Either String a
readEither what s =
    case reads s of
        [(v, "")] -> Right v
        _ -> Left ("could not parse " <> what <> ": " <> s)
