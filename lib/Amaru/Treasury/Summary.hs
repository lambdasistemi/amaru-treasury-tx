{- |
Module      : Amaru.Treasury.Summary
Description : JSON sidecar describing the unsigned tx
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The 'TxSummary' written next to the unsigned CBOR
transaction. Schema:
[`specs/001-treasury-tx-cli/contracts/summary-schema.json`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/specs/001-treasury-tx-cli/contracts/summary-schema.json).
-}
module Amaru.Treasury.Summary
    ( -- * Top-level summary
      TxSummary (..)
    , encodeSummary

      -- * Per-redeemer
    , RedeemerSummary (..)
    , RedeemerPurpose (..)

      -- * ExUnits view
    , ExUnitsView (..)
    ) where

import Data.Aeson
    ( ToJSON (..)
    , object
    , (.=)
    )
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (Spaces)
    , defConfig
    , encodePretty'
    , keyOrder
    )
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import Data.Word (Word32, Word64)

-- | Mirrors the @ex_units@ object in the schema.
data ExUnitsView = ExUnitsView
    { euvMem :: !Word64
    , euvSteps :: !Word64
    }
    deriving (Eq, Show)

instance ToJSON ExUnitsView where
    toJSON ExUnitsView{euvMem, euvSteps} =
        object
            [ "mem" .= euvMem
            , "steps" .= euvSteps
            ]

-- | One of the four Plutus script purposes.
data RedeemerPurpose
    = RpSpend
    | RpWithdraw
    | RpMint
    | RpPublish
    deriving (Eq, Show)

instance ToJSON RedeemerPurpose where
    toJSON = \case
        RpSpend -> "spend"
        RpWithdraw -> "withdraw"
        RpMint -> "mint"
        RpPublish -> "publish"

-- | One row of the @redeemers@ array in the schema.
data RedeemerSummary = RedeemerSummary
    { rsPurpose :: !RedeemerPurpose
    , rsIndex :: !Word32
    , rsExUnits :: !ExUnitsView
    }
    deriving (Eq, Show)

instance ToJSON RedeemerSummary where
    toJSON RedeemerSummary{rsPurpose, rsIndex, rsExUnits} =
        object
            [ "purpose" .= rsPurpose
            , "index" .= rsIndex
            , "ex_units" .= rsExUnits
            ]

-- | The full sidecar payload.
data TxSummary = TxSummary
    { tsTxId :: !Text
    -- ^ 32-byte hash, hex-encoded.
    , tsFeeLovelace :: !Integer
    , tsRedeemers :: ![RedeemerSummary]
    }
    deriving (Eq, Show)

instance ToJSON TxSummary where
    toJSON TxSummary{tsTxId, tsFeeLovelace, tsRedeemers} =
        object
            [ "txid" .= tsTxId
            , "fee_lovelace" .= tsFeeLovelace
            , "redeemers" .= tsRedeemers
            ]

{- | Render a 'TxSummary' as pretty-printed JSON
matching the field order documented in the schema.
-}
encodeSummary :: TxSummary -> ByteString
encodeSummary = encodePretty' summaryConfig
  where
    summaryConfig =
        defConfig
            { confIndent = Spaces 2
            , confCompare =
                keyOrder
                    [ "txid"
                    , "fee_lovelace"
                    , "redeemers"
                    , "purpose"
                    , "index"
                    , "ex_units"
                    , "mem"
                    , "steps"
                    ]
            , confTrailingNewline = True
            }
