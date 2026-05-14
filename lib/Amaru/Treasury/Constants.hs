{- |
Module      : Amaru.Treasury.Constants
Description : Compile-time constants from the bash recipes
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

USDM policy/asset and Sundae swap-order constants
mirrored from
[`pragma-org/amaru-treasury/journal/2026/defaults.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/defaults.sh).
These values are part of the on-chain deployment; the
CLI updates them in lockstep with the upstream recipes.
-}
module Amaru.Treasury.Constants
    ( -- * Currency
      Unit (..)

      -- * USDM token
    , usdmPolicyHex
    , usdmAssetHex

      -- * Sundae swap-order pool
    , sundaeUsdmPoolHex
    , sundaeProtocolFeeLovelace
    , sundaeOrderAddressMainnet
    , sundaeOrderScriptHashMainnet

      -- * Min-UTxO deposit on swap-order outputs
    , minUtxoDepositLovelace
    ) where

import Data.Aeson
    ( FromJSON (..)
    , ToJSON (..)
    , Value (String)
    , withText
    )
import Data.Text (Text)
import Data.Text qualified as T

-- | Currency selector for disburse and reorganize.
data Unit
    = -- | Native ADA (lovelace).
      ADA
    | -- | Moria USD (USDM) token.
      USDM
    deriving (Eq, Show)

{- | JSON: @"ada"@ / @"usdm"@ (case-insensitive on parse;
always lower-cased on emit).
-}
instance FromJSON Unit where
    parseJSON = withText "Unit" $ \t -> case T.toLower t of
        "ada" -> pure ADA
        "usdm" -> pure USDM
        other ->
            fail $
                "Unit: expected \"ada\" or \"usdm\", got "
                    <> show other

instance ToJSON Unit where
    toJSON = \case
        ADA -> String "ada"
        USDM -> String "usdm"

-- | USDM minting policy id (hex).
usdmPolicyHex :: Text
usdmPolicyHex = "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad"

-- | USDM asset name (hex bytes).
usdmAssetHex :: Text
usdmAssetHex = "0014df105553444d"

-- | SundaeSwap USDM pool identifier (hex).
sundaeUsdmPoolHex :: Text
sundaeUsdmPoolHex = "64f35d26b237ad58e099041bc14c687ea7fdc58969d7d5b66e2540ef"

-- | Sundae protocol fee on each swap order (lovelace).
sundaeProtocolFeeLovelace :: Integer
sundaeProtocolFeeLovelace = 1_280_000

{- | SundaeSwap V3 order script address on mainnet. Used by
@treasury-inspect@ to enumerate pending swap-order UTxOs.
Operators on preprod/preview must override this via the
@--swap-order-address@ flag.
-}
sundaeOrderAddressMainnet :: Text
sundaeOrderAddressMainnet =
    "addr1x8ax5k9mutg07p2ngscu3chsauktmstq92z9de938j8nqaejyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxst7gy3n"

{- | SundaeSwap V3 mainnet order validator script hash.

This is the payment credential of 'sundaeOrderAddressMainnet'.
-}
sundaeOrderScriptHashMainnet :: Text
sundaeOrderScriptHashMainnet =
    "fa6a58bbe2d0ff05534431c8e2f0ef2cbdc1602a8456e4b13c8f3077"

-- | Minimum lovelace deposit on swap-order outputs.
minUtxoDepositLovelace :: Integer
minUtxoDepositLovelace = 2_000_000
