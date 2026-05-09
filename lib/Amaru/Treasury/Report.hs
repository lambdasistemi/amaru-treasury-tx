{-# LANGUAGE OverloadedStrings #-}

module Amaru.Treasury.Report
    ( MetadataSummary (..)
    , ProducedOutput (..)
    , ProducedOutputRole (..)
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
    , encodeReport
    , sampleSwapReport
    ) where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (..)
    , NumberFormat (..)
    , encodePretty'
    )
import Data.ByteString.Lazy (ByteString)
import Data.Map.Strict (Map)
import Data.Text (Text)

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

data ProducedOutputRole
    = OutputSwapOrder
    | OutputTreasuryLeftover
    | OutputWalletChange
    | OutputCollateralReturn
    | OutputMetadata
    | OutputUnknown
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

data ValueSummary = ValueSummary
    { vsLovelace :: Integer
    , vsAssets :: Map Text (Map Text Integer)
    }
    deriving stock (Eq, Show)

data UtxoSummary = UtxoSummary
    { usTxIn :: Text
    , usValue :: ValueSummary
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

instance ToJSON ProducedOutputRole where
    toJSON =
        toJSON . producedOutputRoleText

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

instance ToJSON ValueSummary where
    toJSON value =
        object
            [ "lovelace" .= vsLovelace value
            , "assets" .= vsAssets value
            ]

instance ToJSON UtxoSummary where
    toJSON utxo =
        object
            [ "txIn" .= usTxIn utxo
            , "value" .= usValue utxo
            ]

instance ToJSON MetadataSummary where
    toJSON metadata =
        object
            [ "auxiliaryDataHash" .= msAuxiliaryDataHash metadata
            , "cip1694LabelPresent" .= msCip1694LabelPresent metadata
            ]

encodeReport :: TransactionReport -> ByteString
encodeReport = encodePretty' reportJsonConfig

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

emptyValue :: ValueSummary
emptyValue =
    ValueSummary
        { vsLovelace = 0
        , vsAssets = mempty
        }

producedOutputRoleText :: ProducedOutputRole -> Text
producedOutputRoleText = \case
    OutputSwapOrder -> "swapOrder"
    OutputTreasuryLeftover -> "treasuryLeftover"
    OutputWalletChange -> "walletChange"
    OutputCollateralReturn -> "collateralReturn"
    OutputMetadata -> "metadata"
    OutputUnknown -> "unknown"

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
