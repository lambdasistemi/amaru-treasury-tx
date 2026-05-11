{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Report
Description : Mechanical transaction reports and tx-build envelopes
License     : Apache-2.0

The mechanical 'TransactionReport' explains the ledger facts that
@tx-build@ derived while constructing an unsigned transaction. The
public @--report@ artifact is the surrounding 'TxBuildOutput'
envelope: the decoded inline intent plus the result of attempting the
build. Success results carry the unsigned transaction CBOR and the
nested mechanical report; failure results carry structured failure
data and no transaction bytes.

The inline intent is the only transaction-type carrier. The nested
report intentionally does not duplicate an action or type field.
-}
module Amaru.Treasury.Report
    ( BuildFailure (..)
    , MetadataSummary (..)
    , ProducedOutput (..)
    , ProducedOutputRole (..)
    , ReportContext (..)
    , SignerRequirement (..)
    , SignerSource (..)
    , TxBuildOutput (..)
    , TxBuildOutputResult (..)
    , TxBuildSuccess (..)
    , TxCborHex (..)
    , TransactionIdentity (..)
    , TransactionReport (..)
    , TreasuryAccounting (..)
    , UtxoSummary (..)
    , ValidationFacts (..)
    , ValidityInterval (..)
    , ValueSummary (..)
    , WalletAccounting (..)
    , buildTransactionReport
    , encodeBuildOutput
    , encodeReport
    , mkTxCborHex
    , sampleSwapReport
    , txCborHexFromBytes
    ) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address
    ( Addr
    , getNetwork
    , serialiseAddr
    )
import Cardano.Ledger.Allegra.Scripts qualified as Ledger
import Cardano.Ledger.Api.Tx.Body
    ( TxAuxDataHash (..)
    , auxDataHashTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    , txIxToInt
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (TopTx, TxBody)
import Cardano.Ledger.Hashes (KeyHash (..), extractHash)
import Cardano.Ledger.Plutus.Data qualified as PlutusData
import Cardano.Ledger.TxIn
    ( TxId (..)
    , TxIn (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Codec.Binary.Bech32 qualified as Bech32
import Control.Monad (unless)
import Data.Aeson
    ( FromJSON (..)
    , Object
    , ToJSON (..)
    , Value (Object)
    , object
    , withObject
    , withText
    , (.:)
    , (.=)
    )
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (..)
    , NumberFormat (..)
    , encodePretty'
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (Parser)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isDigit)
import Data.Either (fromRight)
import Data.Foldable (toList)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Lens.Micro ((^.))

import Amaru.Treasury.Build
    ( BuildResult (..)
    , ScriptResult (..)
    )
import Amaru.Treasury.IntentJSON (SomeTreasuryIntent)
import Amaru.Treasury.Report.Accounting
    ( UtxoSummary (..)
    , ValueSummary (..)
    , emptyValue
    , sumValueSummaries
    , treasuryNetDebit
    , valueSummary
    )
import Amaru.Treasury.Report.Classify
    ( ProducedOutputRole (..)
    , classifyOutputRole
    )

-- | Self-contained artifact written by @tx-build --report@.
data TxBuildOutput = TxBuildOutput
    { txoIntent :: SomeTreasuryIntent
    -- ^ Decoded originating intent, passed through unchanged.
    , txoResult :: TxBuildOutputResult
    -- ^ Build result: either failure data or transaction bytes plus report.
    }
    deriving stock (Eq, Show)

-- | Result of attempting to build the inline intent.
data TxBuildOutputResult
    = -- | No transaction was created.
      TxBuildOutputFailure BuildFailure
    | -- | Transaction was created and can be reviewed for signing.
      TxBuildOutputSuccess TxBuildSuccess
    deriving stock (Eq, Show)

-- | Successful build payload bound to the exact unsigned transaction.
data TxBuildSuccess = TxBuildSuccess
    { tbsTxCbor :: TxCborHex
    -- ^ Unsigned transaction CBOR as lowercase hex.
    , tbsReport :: TransactionReport
    -- ^ Mechanical facts needed by renderers and reviewers.
    }
    deriving stock (Eq, Show)

-- | Lowercase, non-empty, even-length hex encoding of transaction CBOR.
newtype TxCborHex = TxCborHex
    { unTxCborHex :: Text
    }
    deriving stock (Eq, Ord, Show)

-- | Structured failure result for post-intent-decode build failures.
data BuildFailure = BuildFailure
    { bfCode :: Text
    -- ^ Stable machine-facing failure class.
    , bfMessage :: Text
    -- ^ Operator-facing diagnostic.
    }
    deriving stock (Eq, Show)

-- | Nested mechanical report for successful build-output envelopes.
data TransactionReport = TransactionReport
    { trSchema :: Int
    , trNetwork :: Text
    , trIdentity :: TransactionIdentity
    , trWalletAccounting :: WalletAccounting
    , trTreasuryAccounting :: TreasuryAccounting
    , trOutputs :: [ProducedOutput]
    , trSigners :: [SignerRequirement]
    , trValidation :: ValidationFacts
    , trReferenceInputs :: [Text]
    , trMetadata :: MetadataSummary
    }
    deriving stock (Eq, Show)

data ReportContext = ReportContext
    { rcNetwork :: Text
    , rcSocketNetworkMagic :: Int
    , rcSelectedScopeOwner :: Maybe (Text, Text)
    , rcExtraSigners :: [Text]
    , rcIntentRequiredSigners :: [Text]
    }
    deriving stock (Eq, Show)

data TransactionIdentity = TransactionIdentity
    { tiTxId :: Text
    , tiBodySizeBytes :: Int
    , tiFeeLovelace :: Integer
    , tiTotalCollateralLovelace :: Integer
    , tiValidityInterval :: ValidityInterval
    }
    deriving stock (Eq, Show)

data WalletAccounting = WalletAccounting
    { waInputs :: [UtxoSummary]
    , waCollateralInput :: Maybe UtxoSummary
    , waChangeOutput :: Maybe UtxoSummary
    , waCollateralReturn :: Maybe UtxoSummary
    , waFeeLovelace :: Integer
    , waNetSpendLovelace :: Integer
    }
    deriving stock (Eq, Show)

data TreasuryAccounting = TreasuryAccounting
    { taInputs :: [UtxoSummary]
    , taInputTotal :: ValueSummary
    , taSundaeOrderTotal :: ValueSummary
    , taPerChunkOverheadLovelace :: Integer
    , taTreasuryLeftover :: ValueSummary
    , taNetDebit :: ValueSummary
    }
    deriving stock (Eq, Show)

data ProducedOutput = ProducedOutput
    { poIndex :: Int
    , poRole :: ProducedOutputRole
    , poAddress :: Text
    , poValue :: ValueSummary
    , poDatum :: Maybe Text
    }
    deriving stock (Eq, Show)

data SignerRequirement = SignerRequirement
    { srKeyHash :: Text
    , srSource :: SignerSource
    , srScope :: Maybe Text
    }
    deriving stock (Eq, Show)

data SignerSource
    = SourceSelectedScopeOwner
    | SourceExtraSigner
    | SourceIntentRequiredSigner
    | SourceTxBodyRequiredSigner
    deriving stock (Eq, Show)

data ValidationFacts = ValidationFacts
    { vfIntentNetwork :: Text
    , vfSocketNetworkMagic :: Int
    , vfNetworkMatches :: Bool
    , vfFeeLovelace :: Integer
    , vfBodySizeBytes :: Int
    , vfRedeemerCount :: Int
    , vfRedeemerFailures :: Int
    , vfValidationStatus :: Text
    , vfValidityInterval :: ValidityInterval
    }
    deriving stock (Eq, Show)

data ValidityInterval = ValidityInterval
    { viInvalidBefore :: Maybe Integer
    , viInvalidHereafter :: Maybe Integer
    }
    deriving stock (Eq, Show)

data MetadataSummary = MetadataSummary
    { msAuxiliaryDataHash :: Maybe Text
    , msCip1694LabelPresent :: Bool
    }
    deriving stock (Eq, Show)

instance ToJSON TxBuildOutput where
    toJSON output =
        object
            [ "intent" .= txoIntent output
            , "result" .= txoResult output
            ]

instance FromJSON TxBuildOutput where
    parseJSON = withObject "TxBuildOutput" $ \o -> do
        expectOnlyKeys "TxBuildOutput" ["intent", "result"] o
        TxBuildOutput
            <$> o .: "intent"
            <*> o .: "result"

instance ToJSON TxBuildOutputResult where
    toJSON = \case
        TxBuildOutputFailure failure ->
            object ["failure" .= failure]
        TxBuildOutputSuccess success ->
            toJSON success

instance FromJSON TxBuildOutputResult where
    parseJSON = withObject "TxBuildOutputResult" $ \o -> do
        let has key = KM.member (Key.fromString key) o
        case (has "failure", has "tx-cbor", has "report") of
            (True, False, False) ->
                TxBuildOutputFailure <$> o .: "failure"
            (False, True, True) ->
                TxBuildOutputSuccess <$> parseJSON (Object o)
            (True, _, _) ->
                fail "failure result must not include tx-cbor or report"
            _ ->
                fail "result must contain failure or tx-cbor and report"

instance ToJSON TxBuildSuccess where
    toJSON success =
        object
            [ "tx-cbor" .= tbsTxCbor success
            , "report" .= tbsReport success
            ]

instance FromJSON TxBuildSuccess where
    parseJSON = withObject "TxBuildSuccess" $ \o -> do
        expectOnlyKeys "TxBuildSuccess" ["tx-cbor", "report"] o
        TxBuildSuccess
            <$> o .: "tx-cbor"
            <*> o .: "report"

instance ToJSON TxCborHex where
    toJSON = toJSON . unTxCborHex

instance FromJSON TxCborHex where
    parseJSON = withText "TxCborHex" $ \text ->
        either (fail . T.unpack) pure (mkTxCborHex text)

instance ToJSON BuildFailure where
    toJSON failure =
        object
            [ "code" .= bfCode failure
            , "message" .= bfMessage failure
            ]

instance FromJSON BuildFailure where
    parseJSON = withObject "BuildFailure" $ \o -> do
        expectOnlyKeys "BuildFailure" ["code", "message"] o
        BuildFailure
            <$> o .: "code"
            <*> o .: "message"

instance ToJSON TransactionReport where
    toJSON report =
        object
            [ "schema" .= trSchema report
            , "network" .= trNetwork report
            , "identity" .= trIdentity report
            , "walletAccounting" .= trWalletAccounting report
            , "treasuryAccounting" .= trTreasuryAccounting report
            , "outputs" .= trOutputs report
            , "signers" .= trSigners report
            , "validation" .= trValidation report
            , "referenceInputs" .= trReferenceInputs report
            , "metadata" .= trMetadata report
            ]

instance FromJSON TransactionReport where
    parseJSON = withObject "TransactionReport" $ \o -> do
        expectOnlyKeys
            "TransactionReport"
            [ "schema"
            , "network"
            , "identity"
            , "walletAccounting"
            , "treasuryAccounting"
            , "outputs"
            , "signers"
            , "validation"
            , "referenceInputs"
            , "metadata"
            ]
            o
        TransactionReport
            <$> o .: "schema"
            <*> o .: "network"
            <*> o .: "identity"
            <*> o .: "walletAccounting"
            <*> o .: "treasuryAccounting"
            <*> o .: "outputs"
            <*> o .: "signers"
            <*> o .: "validation"
            <*> o .: "referenceInputs"
            <*> o .: "metadata"

instance ToJSON TransactionIdentity where
    toJSON identity =
        object
            [ "txId" .= tiTxId identity
            , "bodySizeBytes" .= tiBodySizeBytes identity
            , "feeLovelace" .= tiFeeLovelace identity
            , "totalCollateralLovelace"
                .= tiTotalCollateralLovelace identity
            , "validityInterval" .= tiValidityInterval identity
            ]

instance FromJSON TransactionIdentity where
    parseJSON = withObject "TransactionIdentity" $ \o ->
        TransactionIdentity
            <$> o .: "txId"
            <*> o .: "bodySizeBytes"
            <*> o .: "feeLovelace"
            <*> o .: "totalCollateralLovelace"
            <*> o .: "validityInterval"

instance ToJSON WalletAccounting where
    toJSON accounting =
        object
            [ "inputs" .= waInputs accounting
            , "collateralInput" .= waCollateralInput accounting
            , "changeOutput" .= waChangeOutput accounting
            , "collateralReturn" .= waCollateralReturn accounting
            , "feeLovelace" .= waFeeLovelace accounting
            , "netSpendLovelace" .= waNetSpendLovelace accounting
            ]

instance FromJSON WalletAccounting where
    parseJSON = withObject "WalletAccounting" $ \o ->
        WalletAccounting
            <$> o .: "inputs"
            <*> o .: "collateralInput"
            <*> o .: "changeOutput"
            <*> o .: "collateralReturn"
            <*> o .: "feeLovelace"
            <*> o .: "netSpendLovelace"

instance ToJSON TreasuryAccounting where
    toJSON accounting =
        object
            [ "inputs" .= taInputs accounting
            , "inputTotal" .= taInputTotal accounting
            , "sundaeOrderTotal" .= taSundaeOrderTotal accounting
            , "perChunkOverheadLovelace"
                .= taPerChunkOverheadLovelace accounting
            , "treasuryLeftover" .= taTreasuryLeftover accounting
            , "netDebit" .= taNetDebit accounting
            ]

instance FromJSON TreasuryAccounting where
    parseJSON = withObject "TreasuryAccounting" $ \o ->
        TreasuryAccounting
            <$> o .: "inputs"
            <*> o .: "inputTotal"
            <*> o .: "sundaeOrderTotal"
            <*> o .: "perChunkOverheadLovelace"
            <*> o .: "treasuryLeftover"
            <*> o .: "netDebit"

instance ToJSON ProducedOutput where
    toJSON output =
        object
            [ "index" .= poIndex output
            , "role" .= poRole output
            , "address" .= poAddress output
            , "value" .= poValue output
            , "datum" .= poDatum output
            ]

instance FromJSON ProducedOutput where
    parseJSON = withObject "ProducedOutput" $ \o ->
        ProducedOutput
            <$> o .: "index"
            <*> o .: "role"
            <*> o .: "address"
            <*> o .: "value"
            <*> o .: "datum"

instance ToJSON SignerRequirement where
    toJSON signer =
        object
            [ "keyHash" .= srKeyHash signer
            , "source" .= srSource signer
            , "scope" .= srScope signer
            ]

instance FromJSON SignerRequirement where
    parseJSON = withObject "SignerRequirement" $ \o ->
        SignerRequirement
            <$> o .: "keyHash"
            <*> o .: "source"
            <*> o .: "scope"

instance ToJSON SignerSource where
    toJSON =
        toJSON . signerSourceText

instance FromJSON SignerSource where
    parseJSON = withText "SignerSource" $ \case
        "selectedScopeOwner" -> pure SourceSelectedScopeOwner
        "extraSigner" -> pure SourceExtraSigner
        "intentRequiredSigner" -> pure SourceIntentRequiredSigner
        "txBodyRequiredSigner" -> pure SourceTxBodyRequiredSigner
        other -> fail ("unknown signer source: " <> T.unpack other)

instance ToJSON ValidationFacts where
    toJSON facts =
        object
            [ "intentNetwork" .= vfIntentNetwork facts
            , "socketNetworkMagic" .= vfSocketNetworkMagic facts
            , "networkMatches" .= vfNetworkMatches facts
            , "feeLovelace" .= vfFeeLovelace facts
            , "bodySizeBytes" .= vfBodySizeBytes facts
            , "redeemerCount" .= vfRedeemerCount facts
            , "redeemerFailures" .= vfRedeemerFailures facts
            , "validationStatus" .= vfValidationStatus facts
            , "validityInterval" .= vfValidityInterval facts
            ]

instance FromJSON ValidationFacts where
    parseJSON = withObject "ValidationFacts" $ \o ->
        ValidationFacts
            <$> o .: "intentNetwork"
            <*> o .: "socketNetworkMagic"
            <*> o .: "networkMatches"
            <*> o .: "feeLovelace"
            <*> o .: "bodySizeBytes"
            <*> o .: "redeemerCount"
            <*> o .: "redeemerFailures"
            <*> o .: "validationStatus"
            <*> o .: "validityInterval"

instance ToJSON ValidityInterval where
    toJSON interval =
        object
            [ "invalidBefore" .= viInvalidBefore interval
            , "invalidHereafter" .= viInvalidHereafter interval
            ]

instance FromJSON ValidityInterval where
    parseJSON = withObject "ValidityInterval" $ \o ->
        ValidityInterval
            <$> o .: "invalidBefore"
            <*> o .: "invalidHereafter"

instance ToJSON MetadataSummary where
    toJSON metadata =
        object
            [ "auxiliaryDataHash" .= msAuxiliaryDataHash metadata
            , "cip1694LabelPresent" .= msCip1694LabelPresent metadata
            ]

instance FromJSON MetadataSummary where
    parseJSON = withObject "MetadataSummary" $ \o ->
        MetadataSummary
            <$> o .: "auxiliaryDataHash"
            <*> o .: "cip1694LabelPresent"

encodeBuildOutput :: TxBuildOutput -> ByteString
encodeBuildOutput = encodePretty' reportJsonConfig

encodeReport :: TransactionReport -> ByteString
encodeReport = encodePretty' reportJsonConfig

mkTxCborHex :: Text -> Either Text TxCborHex
mkTxCborHex text
    | T.null text = Left "tx-cbor must be non-empty"
    | odd (T.length text) = Left "tx-cbor must have an even length"
    | T.any (not . isLowerHexChar) text =
        Left "tx-cbor must be lowercase hexadecimal"
    | otherwise = Right (TxCborHex text)

txCborHexFromBytes :: ByteString -> TxCborHex
txCborHexFromBytes =
    TxCborHex . Text.decodeUtf8 . B16.encode . BSL.toStrict

isLowerHexChar :: Char -> Bool
isLowerHexChar c =
    isDigit c || ('a' <= c && c <= 'f')

expectOnlyKeys :: String -> [String] -> Object -> Parser ()
expectOnlyKeys label fields o =
    unless
        (all (`KM.member` o) keys && KM.size o == length keys)
        (fail (label <> " has missing or unexpected fields"))
  where
    keys = Key.fromString <$> fields

buildTransactionReport
    :: ReportContext -> BuildResult -> TransactionReport
buildTransactionReport context result =
    TransactionReport
        { trSchema = 1
        , trNetwork = rcNetwork context
        , trIdentity =
            TransactionIdentity
                { tiTxId = brTxId result
                , tiBodySizeBytes = bodySize
                , tiFeeLovelace = feeLovelace
                , tiTotalCollateralLovelace = totalCollateral
                , tiValidityInterval = interval
                }
        , trWalletAccounting =
            WalletAccounting
                { waInputs = walletInputs
                , waCollateralInput =
                    inputSummary
                        <$> brCollateralInput result
                , waChangeOutput =
                    outputSummary result
                        <$> brWalletChangeOutput result
                , waCollateralReturn =
                    collateralReturnSummary result
                        <$> brCollateralReturn result
                , waFeeLovelace = feeLovelace
                , waNetSpendLovelace = walletNetSpend
                }
        , trTreasuryAccounting =
            TreasuryAccounting
                { taInputs = treasuryInputs
                , taInputTotal = treasuryInputTotal
                , taSundaeOrderTotal = sundaeOrderTotal
                , taPerChunkOverheadLovelace = perChunkOverhead
                , taTreasuryLeftover = treasuryLeftover
                , taNetDebit =
                    treasuryInputTotal
                        `treasuryNetDebit` treasuryLeftover
                }
        , trOutputs =
            zipWith
                (outputFromTxOut result)
                [0 ..]
                (toList (body ^. outputsTxBodyL))
        , trSigners = signerRequirements context body
        , trValidation =
            ValidationFacts
                { vfIntentNetwork = rcNetwork context
                , vfSocketNetworkMagic =
                    rcSocketNetworkMagic context
                , vfNetworkMatches =
                    rcSocketNetworkMagic context
                        == networkMagic (rcNetwork context)
                , vfFeeLovelace = feeLovelace
                , vfBodySizeBytes = bodySize
                , vfRedeemerCount = length scriptResults
                , vfRedeemerFailures = redeemerFailures
                , vfValidationStatus =
                    if redeemerFailures == 0 then "ok" else "failed"
                , vfValidityInterval = interval
                }
        , trReferenceInputs =
            renderTxIn
                <$> Set.toAscList (body ^. referenceInputsTxBodyL)
        , trMetadata =
            metadataSummary body
        }
  where
    body = brFinalTxBody result
    bodySize = fromIntegral (BSL.length (brCborBytes result))
    Coin feeLovelace = brFeeLovelace result
    Coin totalCollateral = brTotalCollateralLovelace result
    Coin perChunkOverhead = brPerChunkOverheadLovelace result
    scriptResults = brScriptResults result
    walletInputs = inputSummary <$> brWalletInputs result
    treasuryInputs =
        inputSummary <$> brTreasuryInputs result
    treasuryInputTotal =
        sumValueSummaries (usValue <$> treasuryInputs)
    sundaeOrderTotal =
        sumValueSummaries
            [ valueSummary (txOut ^. valueTxOutL)
            | (_, txOut) <- brSundaeOrderOutputs result
            ]
    treasuryLeftover =
        maybe
            emptyValue
            (valueSummary . (^. valueTxOutL) . snd)
            (brTreasuryLeftoverOutput result)
    walletInputLovelace =
        sum (vsLovelace . usValue <$> walletInputs)
    walletChangeLovelace =
        maybe
            0
            ((vsLovelace . usValue) . outputSummary result)
            (brWalletChangeOutput result)
    walletNetSpend =
        walletInputLovelace
            - walletChangeLovelace
    redeemerFailures =
        length
            [ ()
            | ScriptResult{srOutcome = Left _} <- scriptResults
            ]
    interval = validityInterval (body ^. vldtTxBodyL)

outputFromTxOut
    :: BuildResult -> Int -> TxOut ConwayEra -> ProducedOutput
outputFromTxOut result index txOut =
    ProducedOutput
        { poIndex = index
        , poRole = classifyOutputRole result index
        , poAddress = renderAddress (txOut ^. addrTxOutL)
        , poValue = valueSummary (txOut ^. valueTxOutL)
        , poDatum = datumSummary (txOut ^. datumTxOutL)
        }

signerRequirements
    :: ReportContext -> TxBody TopTx ConwayEra -> [SignerRequirement]
signerRequirements context body =
    dedupeSigners $
        selectedScopeOwnerRequirement context
            ++ fmap
                (signerRequirement SourceExtraSigner Nothing)
                (rcExtraSigners context)
            ++ fmap
                (signerRequirement SourceIntentRequiredSigner Nothing)
                (rcIntentRequiredSigners context)
            ++ fmap
                (signerRequirement SourceTxBodyRequiredSigner Nothing)
                bodyRequiredSigners
  where
    bodyRequiredSigners =
        renderKeyHash
            <$> Set.toAscList (body ^. reqSignerHashesTxBodyL)

selectedScopeOwnerRequirement :: ReportContext -> [SignerRequirement]
selectedScopeOwnerRequirement context =
    case rcSelectedScopeOwner context of
        Nothing -> []
        Just (keyHash, scope) ->
            [ signerRequirement
                SourceSelectedScopeOwner
                (Just scope)
                keyHash
            ]

signerRequirement
    :: SignerSource -> Maybe Text -> Text -> SignerRequirement
signerRequirement source scope keyHash =
    SignerRequirement
        { srKeyHash = keyHash
        , srSource = source
        , srScope = scope
        }

dedupeSigners :: [SignerRequirement] -> [SignerRequirement]
dedupeSigners = go Set.empty
  where
    go _ [] = []
    go seen (signer : rest)
        | Set.member (srKeyHash signer) seen = go seen rest
        | otherwise =
            signer : go (Set.insert (srKeyHash signer) seen) rest

inputSummary :: (TxIn, TxOut ConwayEra) -> UtxoSummary
inputSummary (txIn, txOut) =
    UtxoSummary
        { usTxIn = renderTxIn txIn
        , usValue = valueSummary (txOut ^. valueTxOutL)
        }

outputSummary
    :: BuildResult -> (Int, TxOut ConwayEra) -> UtxoSummary
outputSummary result (index, txOut) =
    UtxoSummary
        { usTxIn =
            brTxId result
                <> "#"
                <> T.pack (show index)
        , usValue = valueSummary (txOut ^. valueTxOutL)
        }

collateralReturnSummary
    :: BuildResult -> TxOut ConwayEra -> UtxoSummary
collateralReturnSummary result txOut =
    UtxoSummary
        { usTxIn = brTxId result <> "#collateral-return"
        , usValue = valueSummary (txOut ^. valueTxOutL)
        }

validityInterval :: Ledger.ValidityInterval -> ValidityInterval
validityInterval (Ledger.ValidityInterval from to) =
    ValidityInterval
        { viInvalidBefore = slotNo <$> strictMaybe from
        , viInvalidHereafter = slotNo <$> strictMaybe to
        }

strictMaybe :: StrictMaybe a -> Maybe a
strictMaybe = \case
    SNothing -> Nothing
    SJust value -> Just value

slotNo :: SlotNo -> Integer
slotNo (SlotNo value) = fromIntegral value

datumSummary :: PlutusData.Datum ConwayEra -> Maybe Text
datumSummary = \case
    PlutusData.NoDatum -> Nothing
    PlutusData.DatumHash h ->
        Just $
            "datumHash:"
                <> Text.decodeUtf8
                    (B16.encode (hashToBytes (extractHash h)))
    PlutusData.Datum _ -> Just "inlineDatum"

renderAddress :: Addr -> Text
renderAddress addr =
    Bech32.encodeLenient
        hrp
        (Bech32.dataPartFromBytes (serialiseAddr addr))
  where
    hrp =
        fromRight
            (error "renderAddress: invalid hrp")
            (Bech32.humanReadablePartFromText (addressHrp addr))
    addressHrp target =
        case getNetwork target of
            Mainnet -> "addr"
            Testnet -> "addr_test"

renderTxIn :: TxIn -> Text
renderTxIn (TxIn (TxId h) ix) =
    Text.decodeUtf8 (B16.encode (hashToBytes (extractHash h)))
        <> "#"
        <> T.pack (show (txIxToInt ix))

renderKeyHash :: KeyHash discriminator -> Text
renderKeyHash (KeyHash h) =
    Text.decodeUtf8 (B16.encode (hashToBytes h))

metadataSummary :: TxBody TopTx ConwayEra -> MetadataSummary
metadataSummary body =
    MetadataSummary
        { msAuxiliaryDataHash =
            renderAuxDataHash <$> strictMaybe (body ^. auxDataHashTxBodyL)
        , msCip1694LabelPresent =
            case body ^. auxDataHashTxBodyL of
                SNothing -> False
                SJust _ -> True
        }

renderAuxDataHash :: TxAuxDataHash -> Text
renderAuxDataHash (TxAuxDataHash h) =
    Text.decodeUtf8 (B16.encode (hashToBytes (extractHash h)))

networkMagic :: Text -> Int
networkMagic = \case
    "mainnet" -> 764_824_073
    "preprod" -> 1
    "preview" -> 2
    _ -> 0

sampleSwapReport :: TransactionReport
sampleSwapReport =
    TransactionReport
        { trSchema = 1
        , trNetwork = "mainnet"
        , trIdentity =
            TransactionIdentity
                { tiTxId =
                    "0000000000000000000000000000000000000000000000000000000000000000"
                , tiBodySizeBytes = 14954
                , tiFeeLovelace = 1039703
                , tiTotalCollateralLovelace = 1559555
                , tiValidityInterval = sampleValidityInterval
                }
        , trWalletAccounting =
            WalletAccounting
                { waInputs = [sampleUtxo]
                , waCollateralInput = Just sampleUtxo
                , waChangeOutput = Nothing
                , waCollateralReturn = Nothing
                , waFeeLovelace = 1039703
                , waNetSpendLovelace = 1039703
                }
        , trTreasuryAccounting =
            TreasuryAccounting
                { taInputs = []
                , taInputTotal = emptyValue
                , taSundaeOrderTotal = emptyValue
                , taPerChunkOverheadLovelace = 0
                , taTreasuryLeftover = emptyValue
                , taNetDebit = emptyValue
                }
        , trOutputs =
            [ ProducedOutput
                { poIndex = 0
                , poRole = OutputUnknown
                , poAddress = "addr_test1..."
                , poValue = emptyValue
                , poDatum = Nothing
                }
            ]
        , trSigners =
            [ SignerRequirement
                { srKeyHash =
                    "11111111111111111111111111111111111111111111111111111111"
                , srSource = SourceExtraSigner
                , srScope = Nothing
                }
            ]
        , trValidation =
            ValidationFacts
                { vfIntentNetwork = "mainnet"
                , vfSocketNetworkMagic = 764824073
                , vfNetworkMatches = True
                , vfFeeLovelace = 1039703
                , vfBodySizeBytes = 14954
                , vfRedeemerCount = 2
                , vfRedeemerFailures = 0
                , vfValidationStatus = "ok"
                , vfValidityInterval = sampleValidityInterval
                }
        , trReferenceInputs = []
        , trMetadata =
            MetadataSummary
                { msAuxiliaryDataHash = Nothing
                , msCip1694LabelPresent = True
                }
        }

sampleValidityInterval :: ValidityInterval
sampleValidityInterval =
    ValidityInterval
        { viInvalidBefore = Nothing
        , viInvalidHereafter = Just 186796799
        }

sampleUtxo :: UtxoSummary
sampleUtxo =
    UtxoSummary
        { usTxIn =
            "0000000000000000000000000000000000000000000000000000000000000000#0"
        , usValue = emptyValue
        }

signerSourceText :: SignerSource -> Text
signerSourceText = \case
    SourceSelectedScopeOwner -> "selectedScopeOwner"
    SourceExtraSigner -> "extraSigner"
    SourceIntentRequiredSigner -> "intentRequiredSigner"
    SourceTxBodyRequiredSigner -> "txBodyRequiredSigner"

reportJsonConfig :: Config
reportJsonConfig =
    Config
        { confIndent = Spaces 4
        , confCompare = compare
        , confNumFormat = Generic
        , confTrailingNewline = True
        }
