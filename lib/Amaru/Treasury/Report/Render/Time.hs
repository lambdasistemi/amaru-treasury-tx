{- |
Module      : Amaru.Treasury.Report.Render.Time
Description : Validity time rendering helpers
License     : Apache-2.0

Deterministic slot-to-UTC helpers for rendering validity bounds.
-}
module Amaru.Treasury.Report.Render.Time
    ( SlotTimeConfig (..)
    , networkSlotTimeConfig
    , renderValidityInterval
    , slotToUtcText
    ) where

import Cardano.Slotting.EpochInfo.API
    ( epochInfoSlotToUTCTime
    )
import Cardano.Slotting.EpochInfo.Impl
    ( fixedEpochInfo
    )
import Cardano.Slotting.Slot
    ( EpochSize (..)
    , SlotNo (..)
    )
import Cardano.Slotting.Time
    ( SystemStart (..)
    , slotLengthFromSec
    )
import Data.Functor.Identity (runIdentity)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Time
    ( UTCTime (..)
    , defaultTimeLocale
    , formatTime
    , fromGregorian
    , secondsToDiffTime
    )
import Data.Word (Word64)

import Amaru.Treasury.Report
    ( ValidityInterval (..)
    )

{- | Slot timing data used by the pure renderer.

The effective system start is the UTC instant that makes the active
one-second era line up with absolute Cardano slot numbers. This keeps
the renderer pure while still using the Cardano slotting API for the
actual slot-to-wall-clock conversion.
-}
data SlotTimeConfig = SlotTimeConfig
    { stcEffectiveSystemStart :: !UTCTime
    -- ^ UTC instant for absolute slot zero in the active one-second era.
    , stcEpochSize :: !Word64
    -- ^ Epoch size for the network's current slotting model.
    , stcSlotLengthSeconds :: !Integer
    -- ^ Slot length in seconds for the current era.
    }
    deriving stock (Eq, Show)

-- | Return deterministic slotting data for supported public networks.
networkSlotTimeConfig :: Text -> Maybe SlotTimeConfig
networkSlotTimeConfig network =
    case T.toLower network of
        "mainnet" ->
            Just
                SlotTimeConfig
                    { stcEffectiveSystemStart =
                        utc 2020 6 7 21 44 51
                    , stcEpochSize = 432_000
                    , stcSlotLengthSeconds = 1
                    }
        "preprod" ->
            Just
                SlotTimeConfig
                    { stcEffectiveSystemStart =
                        utc 2022 6 20 0 0 0
                    , stcEpochSize = 432_000
                    , stcSlotLengthSeconds = 1
                    }
        "preview" ->
            Just
                SlotTimeConfig
                    { stcEffectiveSystemStart =
                        utc 2022 10 25 0 0 0
                    , stcEpochSize = 86_400
                    , stcSlotLengthSeconds = 1
                    }
        _ -> Nothing

-- | Render a validity interval with UTC instants when network data is known.
renderValidityInterval :: Text -> ValidityInterval -> Text
renderValidityInterval network interval =
    "invalid before "
        <> renderBound config (viInvalidBefore interval)
        <> "; invalid hereafter "
        <> renderBound config (viInvalidHereafter interval)
  where
    config = networkSlotTimeConfig network

renderBound :: Maybe SlotTimeConfig -> Maybe Integer -> Text
renderBound _ Nothing = "none"
renderBound config (Just slot) =
    "slot "
        <> tshow slot
        <> maybe "" ((" (" <>) . (<> ")")) utcText
  where
    utcText = config >>= (`slotToUtcText` slot)

-- | Convert an absolute slot number into an ISO-8601 UTC timestamp.
slotToUtcText :: SlotTimeConfig -> Integer -> Maybe Text
slotToUtcText config slot =
    formatUtc <$> slotToUtc config slot

slotToUtc :: SlotTimeConfig -> Integer -> Maybe UTCTime
slotToUtc config slot
    | slot < 0 = Nothing
    | slot > fromIntegral maxSlot = Nothing
    | otherwise =
        Just $
            runIdentity $
                epochInfoSlotToUTCTime
                    ( fixedEpochInfo
                        (EpochSize (stcEpochSize config))
                        (slotLengthFromSec (stcSlotLengthSeconds config))
                    )
                    (SystemStart (stcEffectiveSystemStart config))
                    (SlotNo (fromInteger slot))
  where
    maxSlot = maxBound :: Word64

formatUtc :: UTCTime -> Text
formatUtc =
    T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

utc
    :: Integer -> Int -> Int -> Integer -> Integer -> Integer -> UTCTime
utc year month day hour minute second =
    UTCTime
        (fromGregorian year month day)
        (secondsToDiffTime (hour * 3600 + minute * 60 + second))

tshow :: (Show a) => a -> Text
tshow = T.pack . show
