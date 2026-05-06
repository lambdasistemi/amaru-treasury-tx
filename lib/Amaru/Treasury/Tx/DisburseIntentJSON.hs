{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Tx.DisburseIntentJSON
Description : JSON contract for the disburse intent
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Sister of
[`Amaru.Treasury.Tx.SwapIntentJSON`](Amaru.Treasury.Tx.SwapIntentJSON.html)
for the disburse subcommand. Defines the on-disk JSON
contract the @disburse-wizard@ writes and the @disburse@
build path reads, plus a typed lift to the values the
build pipeline consumes.

The JSON schema is documented in
@specs\/004-disburse-wizard\/contracts\/disburse-intent-json.md@.
-}
module Amaru.Treasury.Tx.DisburseIntentJSON
    ( -- * Top-level intent
      DisburseIntentJSON (..)
    , DisburseWalletJSON (..)
    , DisburseScopeJSON (..)
    , DisburseInputsJSON (..)
    , DisburseRationaleJSON (..)

      -- * Decoding
    , decodeDisburseIntent
    , decodeDisburseIntentFile

      -- * Encoding
    , encodeDisburseIntent

      -- * Translation
    , TranslatedDisburseIntent (..)
    , translateDisburseIntent
    ) where

import Cardano.Crypto.Hash.Class (Hash, HashAlgorithm, hashFromBytes)
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , decodeAddrEither
    )
import Cardano.Ledger.BaseTypes (Network (..), mkTxIxPartial)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Metadata (Metadatum)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Slotting.Slot (SlotNo (..))
import Codec.Binary.Bech32 qualified as Bech32
import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , eitherDecodeFileStrict
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.Aeson qualified as A
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (..)
    , NumberFormat (..)
    , encodePretty'
    )
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict (Map)
import Data.Maybe (fromJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)

import Amaru.Treasury.AuxData
    ( RationaleBody (..)
    , rationaleMetadatum
    )
import Amaru.Treasury.Tx.Disburse
    ( DisburseAdaPayload (..)
    , DisburseIntent (..)
    , DisburseIntentFields (..)
    )

-- ----------------------------------------------------
-- JSON shape
-- ----------------------------------------------------

-- | Wallet block: the fuel + collateral input.
data DisburseWalletJSON = DisburseWalletJSON
    { dwjTxIn :: !Text
    -- ^ @\<txid hex\>#\<ix\>@
    , dwjAddress :: !Text
    -- ^ bech32 @addr1…@
    }
    deriving stock (Eq, Show)

{- | Scope block: the treasury inputs, leftover totals,
deployed-script references, and registry pointer for the
chosen scope.
-}
data DisburseScopeJSON = DisburseScopeJSON
    { dsjId :: !Text
    -- ^ canonical scope name
    --   (@core_development@ etc.)
    , dsjTreasuryAddress :: !Text
    , dsjTreasuryUtxos :: ![Text]
    , dsjTreasuryLeftoverLovelace :: !Integer
    , dsjTreasuryLeftoverUsdm :: !Integer
    , dsjTreasuryLeftoverOtherAssets
        :: !(Map Text (Map Text Integer))
    -- ^ outer key: policy hex; inner key:
    --   asset-name hex
    , dsjTreasuryScriptHash :: !Text
    , dsjPermissionsRewardAccount :: !Text
    , dsjScopesDeployedAt :: !Text
    , dsjPermissionsDeployedAt :: !Text
    , dsjTreasuryDeployedAt :: !Text
    , dsjRegistryDeployedAt :: !Text
    , dsjRegistryPolicyId :: !Text
    }
    deriving stock (Eq, Show)

{- | Disburse-specific block: the unit, amount, beneficiary
address, and the USDM policy/token (carried for the @ada@
case as well, ignored by the build path when not needed).
-}
data DisburseInputsJSON = DisburseInputsJSON
    { dijUnit :: !Text
    -- ^ @"ada"@ or @"usdm"@
    , dijAmount :: !Integer
    -- ^ lovelace for @ada@; smallest USDM unit for
    --     @usdm@
    , dijBeneficiaryAddress :: !Text
    , dijUsdmPolicy :: !Text
    -- ^ hex 28 bytes
    , dijUsdmToken :: !Text
    -- ^ asset-name hex
    }
    deriving stock (Eq, Show)

{- | Rationale block. Defaults are applied upstream by the
wizard's pure translation; the JSON parser requires every
field to be present.
-}
data DisburseRationaleJSON = DisburseRationaleJSON
    { drjEvent :: !Text
    , drjLabel :: !Text
    , drjDescription :: !Text
    , drjJustification :: !Text
    , drjDestinationLabel :: !Text
    }
    deriving stock (Eq, Show)

-- | Top-level disburse intent.
data DisburseIntentJSON = DisburseIntentJSON
    { dijNetwork :: !Text
    -- ^ @"mainnet"@ / @"preprod"@ / @"preview"@
    , dijWallet :: !DisburseWalletJSON
    , dijScope :: !DisburseScopeJSON
    , dijDisburse :: !DisburseInputsJSON
    , dijSigners :: ![Text]
    -- ^ 28-byte hex; scope owner first
    , dijValidityUpperBoundSlot :: !Word64
    , dijRationale :: !DisburseRationaleJSON
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- FromJSON
-- ----------------------------------------------------

instance FromJSON DisburseWalletJSON where
    parseJSON = withObject "DisburseWalletJSON" $ \o ->
        DisburseWalletJSON
            <$> o .: "txIn"
            <*> o .: "address"

instance FromJSON DisburseScopeJSON where
    parseJSON = withObject "DisburseScopeJSON" $ \o ->
        DisburseScopeJSON
            <$> o .: "id"
            <*> o .: "treasuryAddress"
            <*> o .: "treasuryUtxos"
            <*> o .: "treasuryLeftoverLovelace"
            <*> o .: "treasuryLeftoverUsdm"
            <*> o .: "treasuryLeftoverOtherAssets"
            <*> o .: "treasuryScriptHash"
            <*> o .: "permissionsRewardAccount"
            <*> o .: "scopesDeployedAt"
            <*> o .: "permissionsDeployedAt"
            <*> o .: "treasuryDeployedAt"
            <*> o .: "registryDeployedAt"
            <*> o .: "registryPolicyId"

instance FromJSON DisburseInputsJSON where
    parseJSON = withObject "DisburseInputsJSON" $ \o ->
        DisburseInputsJSON
            <$> o .: "unit"
            <*> o .: "amount"
            <*> o .: "beneficiaryAddress"
            <*> o .: "usdmPolicy"
            <*> o .: "usdmToken"

instance FromJSON DisburseRationaleJSON where
    parseJSON = withObject "DisburseRationaleJSON" $ \o ->
        DisburseRationaleJSON
            <$> o .: "event"
            <*> o .: "label"
            <*> o .: "description"
            <*> o .: "justification"
            <*> o .: "destinationLabel"

instance FromJSON DisburseIntentJSON where
    parseJSON = withObject "DisburseIntentJSON" $ \o ->
        DisburseIntentJSON
            <$> o .: "network"
            <*> o .: "wallet"
            <*> o .: "scope"
            <*> o .: "disburse"
            <*> o .: "signers"
            <*> o .: "validityUpperBoundSlot"
            <*> o .: "rationale"

-- ----------------------------------------------------
-- ToJSON
-- ----------------------------------------------------

instance ToJSON DisburseWalletJSON where
    toJSON DisburseWalletJSON{..} =
        object
            [ "txIn" .= dwjTxIn
            , "address" .= dwjAddress
            ]

instance ToJSON DisburseScopeJSON where
    toJSON DisburseScopeJSON{..} =
        object
            [ "id" .= dsjId
            , "treasuryAddress" .= dsjTreasuryAddress
            , "treasuryUtxos" .= dsjTreasuryUtxos
            , "treasuryLeftoverLovelace"
                .= dsjTreasuryLeftoverLovelace
            , "treasuryLeftoverUsdm"
                .= dsjTreasuryLeftoverUsdm
            , "treasuryLeftoverOtherAssets"
                .= dsjTreasuryLeftoverOtherAssets
            , "treasuryScriptHash" .= dsjTreasuryScriptHash
            , "permissionsRewardAccount"
                .= dsjPermissionsRewardAccount
            , "scopesDeployedAt" .= dsjScopesDeployedAt
            , "permissionsDeployedAt"
                .= dsjPermissionsDeployedAt
            , "treasuryDeployedAt" .= dsjTreasuryDeployedAt
            , "registryDeployedAt" .= dsjRegistryDeployedAt
            , "registryPolicyId" .= dsjRegistryPolicyId
            ]

instance ToJSON DisburseInputsJSON where
    toJSON DisburseInputsJSON{..} =
        object
            [ "unit" .= dijUnit
            , "amount" .= dijAmount
            , "beneficiaryAddress" .= dijBeneficiaryAddress
            , "usdmPolicy" .= dijUsdmPolicy
            , "usdmToken" .= dijUsdmToken
            ]

instance ToJSON DisburseRationaleJSON where
    toJSON DisburseRationaleJSON{..} =
        object
            [ "event" .= drjEvent
            , "label" .= drjLabel
            , "description" .= drjDescription
            , "justification" .= drjJustification
            , "destinationLabel" .= drjDestinationLabel
            ]

instance ToJSON DisburseIntentJSON where
    toJSON DisburseIntentJSON{..} =
        object
            [ "network" .= dijNetwork
            , "wallet" .= dijWallet
            , "scope" .= dijScope
            , "disburse" .= dijDisburse
            , "signers" .= dijSigners
            , "validityUpperBoundSlot"
                .= dijValidityUpperBoundSlot
            , "rationale" .= dijRationale
            ]

-- ----------------------------------------------------
-- Decoding
-- ----------------------------------------------------

-- | Parse a 'DisburseIntentJSON' from a UTF-8 byte string.
decodeDisburseIntent
    :: BSL.ByteString -> Either String DisburseIntentJSON
decodeDisburseIntent = A.eitherDecode

-- | 'decodeDisburseIntent' over a file path.
decodeDisburseIntentFile
    :: FilePath -> IO (Either String DisburseIntentJSON)
decodeDisburseIntentFile = eitherDecodeFileStrict

-- ----------------------------------------------------
-- Encoding
-- ----------------------------------------------------

{- | Stable pretty-printed encoder for
'DisburseIntentJSON', used by golden tests. Fixed config:
4-space indent, alphabetical key ordering, no unicode
escapes for ASCII text, decimals for numbers, trailing
newline.
-}
encodeDisburseIntent :: DisburseIntentJSON -> BSL.ByteString
encodeDisburseIntent = encodePretty' cfg
  where
    cfg =
        Config
            { confIndent = Spaces 4
            , confCompare = compare
            , confNumFormat = Generic
            , confTrailingNewline = True
            }

-- ----------------------------------------------------
-- Translation
-- ----------------------------------------------------

-- | The result of 'translateDisburseIntent'.
data TranslatedDisburseIntent = TranslatedDisburseIntent
    { tdNetwork :: !Text
    , tdWalletTxIn :: !TxIn
    , tdWalletAddr :: !Addr
    , tdDisburseIntent :: !DisburseIntent
    , tdRationale :: !Metadatum
    -- ^ aux-data block carrying the rationale
    }

{- | Lift a parsed 'DisburseIntentJSON' into the typed
ledger inputs that 'DisburseBuild.runDisburseBuild' will
consume.

The ADA branch builds 'DisburseAdaIntent'. The USDM branch
parses cleanly but currently returns 'Left' because the
USDM 'TxBuild' lands in T038 (feature 004 phase 5).
-}
translateDisburseIntent
    :: DisburseIntentJSON
    -> Either String TranslatedDisburseIntent
translateDisburseIntent dij@DisburseIntentJSON{..} = do
    walletAddr <- parseAddr (dwjAddress dijWallet)
    walletTxIn <- parseTxIn (dwjTxIn dijWallet)
    fields <- buildFields dij
    intent <- buildIntent dij fields
    rationale <- buildRationale dij
    pure
        TranslatedDisburseIntent
            { tdNetwork = dijNetwork
            , tdWalletTxIn = walletTxIn
            , tdWalletAddr = walletAddr
            , tdDisburseIntent = intent
            , tdRationale = rationale
            }

buildFields
    :: DisburseIntentJSON -> Either String DisburseIntentFields
buildFields DisburseIntentJSON{..} = do
    walletTxIn <- parseTxIn (dwjTxIn dijWallet)
    treasuryAddr <-
        parseAddr (dsjTreasuryAddress dijScope)
    treasuryUtxos <-
        traverse parseTxIn (dsjTreasuryUtxos dijScope)
    permissionsAcct <-
        parseRewardAccount
            (dsjPermissionsRewardAccount dijScope)
    scopesRef <-
        parseTxIn (dsjScopesDeployedAt dijScope)
    permissionsRef <-
        parseTxIn (dsjPermissionsDeployedAt dijScope)
    treasuryRef <-
        parseTxIn (dsjTreasuryDeployedAt dijScope)
    registryRef <-
        parseTxIn (dsjRegistryDeployedAt dijScope)
    beneficiaryAddr <-
        parseAddr (dijBeneficiaryAddress dijDisburse)
    signers <- traverse parseGuardKeyHash dijSigners
    pure
        DisburseIntentFields
            { difWalletUtxo = walletTxIn
            , difBeneficiaryAddress = beneficiaryAddr
            , difTreasuryUtxos = treasuryUtxos
            , difTreasuryAddress = treasuryAddr
            , difPermissionsRewardAccount = permissionsAcct
            , difScopesDeployedAt = scopesRef
            , difPermissionsDeployedAt = permissionsRef
            , difTreasuryDeployedAt = treasuryRef
            , difRegistryDeployedAt = registryRef
            , difSigners = signers
            , difUpperBound =
                SlotNo dijValidityUpperBoundSlot
            }

buildIntent
    :: DisburseIntentJSON
    -> DisburseIntentFields
    -> Either String DisburseIntent
buildIntent DisburseIntentJSON{..} fields =
    case T.toLower (dijUnit dijDisburse) of
        "ada" ->
            Right $
                DisburseAdaIntent
                    fields
                    DisburseAdaPayload
                        { dapAmountLovelace =
                            Coin (dijAmount dijDisburse)
                        , dapLeftoverLovelace =
                            Coin
                                ( dsjTreasuryLeftoverLovelace
                                    dijScope
                                )
                        }
        "usdm" ->
            Left
                "USDM disburse JSON parsed; pure builder lands in T038"
        other ->
            Left ("unknown disburse unit: " <> T.unpack other)

buildRationale
    :: DisburseIntentJSON -> Either String Metadatum
buildRationale DisburseIntentJSON{..} = do
    registryPolicy <-
        decodeHexBytes 28 (dsjRegistryPolicyId dijScope)
    let body =
            RationaleBody
                { rbEvent = drjEvent dijRationale
                , rbLabel = drjLabel dijRationale
                , rbDescription =
                    [drjDescription dijRationale]
                , rbDestinationLabel =
                    drjDestinationLabel dijRationale
                , rbJustification =
                    [drjJustification dijRationale]
                }
    pure (rationaleMetadatum body registryPolicy)

-- ----------------------------------------------------
-- Helpers (parallel to SwapIntentJSON; intentionally
-- duplicated to keep the modules independently
-- reviewable. A shared "JSON helpers" module is a future
-- refactor once a third caller lands.)
-- ----------------------------------------------------

parseAddr :: Text -> Either String Addr
parseAddr t = do
    raw <- case Bech32.decodeLenient t of
        Right (_hrp, dp) ->
            case Bech32.dataPartToBytes dp of
                Just bs -> Right bs
                Nothing -> Left "bech32 data-part decode"
        Left e -> Left ("bech32: " <> show e)
    case decodeAddrEither raw of
        Right a -> Right a
        Left e -> Left ("address: " <> show e)

parseTxIn :: Text -> Either String TxIn
parseTxIn t = case T.splitOn "#" t of
    [hHex, ixT] -> do
        ix <- readEither "txix" (T.unpack ixT)
        bs <- decodeHexBytes 32 hHex
        Right
            ( TxIn
                (TxId (unsafeMakeSafeHash (mkHash32 bs)))
                (mkTxIxPartial (ix :: Integer))
            )
    _ ->
        Left
            ( "txIn must be \"<hex>#<ix>\", got "
                <> T.unpack t
            )

parseRewardAccount
    :: Text -> Either String AccountAddress
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

mkHash28 :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash28 = fromJust . hashFromBytes

mkHash32 :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash32 = fromJust . hashFromBytes

readEither :: (Read a) => String -> String -> Either String a
readEither what s = case reads s of
    [(v, "")] -> Right v
    _ -> Left (what <> ": cannot parse " <> show s)
