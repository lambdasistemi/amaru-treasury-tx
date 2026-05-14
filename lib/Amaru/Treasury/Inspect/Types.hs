{- |
Module      : Amaru.Treasury.Inspect.Types
Description : Public record types for the @treasury-inspect@ report
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pure data shapes consumed by the inspect-report assembly. This
slice ships only 'ParsedSwapOrder'; subsequent slices extend this
module with the top-level 'InspectReport' and its sub-records.
-}
module Amaru.Treasury.Inspect.Types
    ( ParsedSwapOrder (..)
    ) where

import Data.ByteString (ByteString)

{- | One pending SundaeSwap order parsed from its inline datum.

The 'posDestinationTreasuryHash' field is what the inspector uses
to attribute the order to a scope — see
@specs/109-treasury-inspect/research.md@ §R1 for why this is the
correct disambiguator and not the four-scope authorised-signers
list embedded at index 1 of the order datum.
-}
data ParsedSwapOrder = ParsedSwapOrder
    { posDestinationTreasuryHash :: !ByteString
    -- ^ 28-byte hash of the funding scope's treasury script.
    , posLovelaceIn :: !Integer
    -- ^ ADA committed to the swap (chunk lovelace).
    , posMinUsdmOut :: !Integer
    -- ^ Minimum USDM the order will accept.
    , posSundaeFeeLovelace :: !Integer
    -- ^ SundaeSwap protocol fee embedded in the datum.
    }
    deriving (Eq, Show)
