{- |
Module      : Amaru.Treasury.Inspect.SwapOrderDatum
Description : Decode a SundaeSwap V3 order inline datum
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Inverts 'Amaru.Treasury.Tx.Swap.swapOrderDatum' for the read-only
inspector. Extracts the destination treasury script hash, the
chunk ADA and minimum USDM, and the embedded SundaeSwap fee.
Non-Amaru-treasury orders (or any inline datum that does not match
the expected shape) return 'Nothing' and are silently skipped by
the caller.
-}
module Amaru.Treasury.Inspect.SwapOrderDatum
    ( parseSwapOrderDatum
    ) where

import Data.ByteString (ByteString)
import PlutusCore.Data (Data (..))

import Amaru.Treasury.Inspect.Types (ParsedSwapOrder (..))

{- | Parse a SundaeSwap order inline datum produced by
'Amaru.Treasury.Tx.Swap.swapOrderDatum'.

Returns 'Nothing' if the outer constructor index, arity, or the
nested destination / swap-params shape does not match. The
authorised-signers list (index 1) and the trailing extra block
(index 5) are not inspected — they are shared across every Amaru
treasury order and carry no scope-attribution information.
-}
parseSwapOrderDatum :: Data -> Maybe ParsedSwapOrder
parseSwapOrderDatum
    ( Constr
            0
            [_pool, _signers, fee, dest, swapParams, _extra]
        ) = do
        feeLovelace <- asInt fee
        destHash <- destinationTreasuryHash dest
        (lovelaceIn, minUsdmOut) <- swapAmounts swapParams
        pure
            ParsedSwapOrder
                { posDestinationTreasuryHash = destHash
                , posLovelaceIn = lovelaceIn
                , posMinUsdmOut = minUsdmOut
                , posSundaeFeeLovelace = feeLovelace
                }
parseSwapOrderDatum _ = Nothing

asInt :: Data -> Maybe Integer
asInt (I n) = Just n
asInt _ = Nothing

{- | The destination block has shape
@Constr 0 [ Constr 0 [paymentCred, stakeCred] , datumOrInline ]@,
where @paymentCred@ is @Constr 1 [B treasuryScriptHash]@ for the
script-credential case (the only case the swap wizard emits).
-}
destinationTreasuryHash :: Data -> Maybe ByteString
destinationTreasuryHash
    ( Constr
            0
            [ Constr
                    0
                    [ Constr 1 [B hash]
                        , _stakeCred
                        ]
                , _datumOrInline
                ]
        ) = Just hash
destinationTreasuryHash _ = Nothing

{- | The swap-params block has shape
@Constr 1 [ List [B "", B "", I chunkLovelace]
         , List [B usdmPolicy, B usdmToken, I chunkUsdm]
         ]@.
The two assets are identified by position: the ADA list always
uses an empty policy and asset name; the USDM list carries the
project's USDM policy + token name.
-}
swapAmounts :: Data -> Maybe (Integer, Integer)
swapAmounts (Constr 1 [adaList, usdmList]) = do
    ada <- adaLovelace adaList
    usdm <- usdmAmount usdmList
    pure (ada, usdm)
swapAmounts _ = Nothing

adaLovelace :: Data -> Maybe Integer
adaLovelace (List [B "", B "", I lovelace]) = Just lovelace
adaLovelace _ = Nothing

usdmAmount :: Data -> Maybe Integer
usdmAmount (List [B _policy, B _token, I usdm]) = Just usdm
usdmAmount _ = Nothing
