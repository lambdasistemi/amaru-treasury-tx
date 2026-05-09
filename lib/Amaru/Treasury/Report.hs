{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.Report
    ( MetadataSummary (..)
    , ProducedOutput (..)
    , ProducedOutputRole (..)
    , ReportContext (..)
    , SignerRequirement (..)
    , SignerSource (..)
    , TransactionIdentity (..)
    , TransactionReport (..)
    , TreasuryAccounting (..)
    , UtxoSummary (..)
    , ValidationFacts (..)
    , ValidityInterval (..)
    , ValueSummary (..)
    , WalletAccounting (..)
    , buildTransactionReport
    , encodeReport
    , sampleSwapReport
    ) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address
    ( Addr
    , getNetwork
    , serialiseAddr
    )
import Cardano.Ledger.Allegra.Scripts qualified as Ledger
import Cardano.Ledger.Api.Tx.Body
    ( outputsTxBodyL
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
import Data.Aeson (ToJSON (..), object, (.=))
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (..)
    , NumberFormat (..)
    , encodePretty'
    )
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy (ByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Either (fromRight)
import Data.Foldable (toList)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Lens.Micro ((^.))

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
import Amaru.Treasury.TreasuryBuild
    ( ScriptResult (..)
    , TreasuryBuildResult (..)
    )

data TransactionReport = TransactionReport
    { trSchema :: Int
    , trAction :: Text
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
    { rcAction :: Text
    , rcNetwork :: Text
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

instance ToJSON TransactionReport where
    toJSON report =
        object
            [ "schema" .= trSchema report
            , "action" .= trAction report
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

instance ToJSON ProducedOutput where
    toJSON output =
        object
            [ "index" .= poIndex output
            , "role" .= poRole output
            , "address" .= poAddress output
            , "value" .= poValue output
            , "datum" .= poDatum output
            ]

instance ToJSON SignerRequirement where
    toJSON signer =
        object
            [ "keyHash" .= srKeyHash signer
            , "source" .= srSource signer
            , "scope" .= srScope signer
            ]

instance ToJSON SignerSource where
    toJSON =
        toJSON . signerSourceText

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

instance ToJSON ValidityInterval where
    toJSON interval =
        object
            [ "invalidBefore" .= viInvalidBefore interval
            , "invalidHereafter" .= viInvalidHereafter interval
            ]

instance ToJSON MetadataSummary where
    toJSON metadata =
        object
            [ "auxiliaryDataHash" .= msAuxiliaryDataHash metadata
            , "cip1694LabelPresent" .= msCip1694LabelPresent metadata
            ]

encodeReport :: TransactionReport -> ByteString
encodeReport = encodePretty' reportJsonConfig

buildTransactionReport
    :: ReportContext -> TreasuryBuildResult -> TransactionReport
buildTransactionReport context result =
    TransactionReport
        { trSchema = 1
        , trAction = rcAction context
        , trNetwork = rcNetwork context
        , trIdentity =
            TransactionIdentity
                { tiTxId = tbrTxId result
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
                        <$> tbrCollateralInput result
                , waChangeOutput =
                    outputSummary result
                        <$> tbrWalletChangeOutput result
                , waCollateralReturn =
                    collateralReturnSummary result
                        <$> tbrCollateralReturn result
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
            MetadataSummary
                { msAuxiliaryDataHash = Nothing
                , msCip1694LabelPresent = True
                }
        }
  where
    body = tbrFinalTxBody result
    bodySize = fromIntegral (BSL.length (tbrCborBytes result))
    Coin feeLovelace = tbrFeeLovelace result
    Coin totalCollateral = tbrTotalCollateralLovelace result
    Coin perChunkOverhead = tbrPerChunkOverheadLovelace result
    scriptResults = tbrScriptResults result
    walletInputs = inputSummary <$> tbrWalletInputs result
    treasuryInputs =
        inputSummary <$> tbrTreasuryInputs result
    treasuryInputTotal =
        sumValueSummaries (usValue <$> treasuryInputs)
    sundaeOrderTotal =
        sumValueSummaries
            [ valueSummary (txOut ^. valueTxOutL)
            | (_, txOut) <- tbrSundaeOrderOutputs result
            ]
    treasuryLeftover =
        maybe
            emptyValue
            (valueSummary . (^. valueTxOutL) . snd)
            (tbrTreasuryLeftoverOutput result)
    walletInputLovelace =
        sum (vsLovelace . usValue <$> walletInputs)
    walletChangeLovelace =
        maybe
            0
            ((vsLovelace . usValue) . outputSummary result)
            (tbrWalletChangeOutput result)
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
    :: TreasuryBuildResult -> Int -> TxOut ConwayEra -> ProducedOutput
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
    :: TreasuryBuildResult -> (Int, TxOut ConwayEra) -> UtxoSummary
outputSummary result (index, txOut) =
    UtxoSummary
        { usTxIn =
            tbrTxId result
                <> "#"
                <> T.pack (show index)
        , usValue = valueSummary (txOut ^. valueTxOutL)
        }

collateralReturnSummary
    :: TreasuryBuildResult -> TxOut ConwayEra -> UtxoSummary
collateralReturnSummary result txOut =
    UtxoSummary
        { usTxIn = tbrTxId result <> "#collateral-return"
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
        , trAction = "swap"
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
