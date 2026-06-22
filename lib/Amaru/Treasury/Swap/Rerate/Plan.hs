{- |
Module      : Amaru.Treasury.Swap.Rerate.Plan
Description : Pure validation and value planning for swap re-rate
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Validates selected pending SundaeSwap orders for one treasury scope and
derives the replacement order value and datum at a new ADA/USDM rate.
No transaction body is built in this module.
-}
module Amaru.Treasury.Swap.Rerate.Plan
    ( planRerate
    ) where

import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Data.Map.Strict qualified as Map
import PlutusCore.Data (Data (..))

import Amaru.Treasury.Swap.Rerate.Types
    ( PlannedRerate (..)
    , PlannedRerateOrder (..)
    , RerateError (..)
    , RerateIntent (..)
    , RerateOrder (..)
    , RerateScopeContext (..)
    )
import Amaru.Treasury.Tx.Swap (swapOrderDatum)
import Amaru.Treasury.Tx.SwapCancel.Datum
    ( validateSwapOrderDatum
    )

-- | Validate selected orders and derive replacement values/datum.
planRerate :: RerateIntent -> Either RerateError PlannedRerate
planRerate intent
    | null (riOrders intent) = Left RerateNoOrders
    | riRateNumerator intent <= 0 || riRateDenominator intent <= 0 =
        Left $
            RerateNonPositiveRate
                (riRateNumerator intent)
                (riRateDenominator intent)
    | otherwise =
        PlannedRerate (riScopeContext intent)
            <$> traverse (planOrder intent) (riOrders intent)

planOrder
    :: RerateIntent
    -> RerateOrder
    -> Either RerateError PlannedRerateOrder
planOrder intent order = do
    let context = riScopeContext intent
        expectedScope = rscScope context
    if rroScope order == expectedScope
        then pure ()
        else
            Left $
                RerateOrderScopeMismatch
                    (rroTxIn order)
                    expectedScope
                    (rroScope order)
    _ <-
        either
            (Left . RerateOrderDatumInvalid (rroTxIn order))
            Right
            ( validateSwapOrderDatum
                (rscExpectedOwners context)
                (rscTreasuryScriptHash context)
                (rroDatum order)
            )
    offered <- parseOfferedLovelace (rroTxIn order) (rroDatum order)
    let actualOffered = orderOfferedFromValue context order
    if actualOffered == offered
        then pure ()
        else
            Left $
                RerateOfferedLovelaceMismatch
                    (rroTxIn order)
                    offered
                    actualOffered
    ensureNoNativeAssets order
    let requested =
            requestedUsdm
                (riRateNumerator intent)
                (riRateDenominator intent)
                offered
        replacementValue =
            MaryValue
                ( addCoin
                    offered
                    (rscOrderExtraLovelace context)
                )
                (MultiAsset Map.empty)
        replacementDatum =
            swapOrderDatum
                (rscDatumParams context)
                (unCoin offered)
                requested
    pure
        PlannedRerateOrder
            { proTxIn = rroTxIn order
            , proOriginalValue = rroValue order
            , proOfferedLovelace = offered
            , proReplacementValue = replacementValue
            , proReplacementDatum = replacementDatum
            , proRequestedUsdm = requested
            }

parseOfferedLovelace
    :: TxIn
    -> Data
    -> Either RerateError Coin
parseOfferedLovelace txin = \case
    Constr
        0
        [ _
            , _
            , _
            , _
            , Constr 1 [List [_, _, I offered], _]
            , _
            ]
            | offered >= 0 ->
                Right (Coin offered)
    _ -> Left (RerateMalformedOrderDetails txin)

orderOfferedFromValue :: RerateScopeContext -> RerateOrder -> Coin
orderOfferedFromValue context order =
    case rroValue order of
        MaryValue locked _ ->
            subtractCoin locked (rscOrderExtraLovelace context)

ensureNoNativeAssets :: RerateOrder -> Either RerateError ()
ensureNoNativeAssets order =
    case rroValue order of
        MaryValue _ (MultiAsset assets)
            | Map.null assets -> Right ()
            | otherwise ->
                Left (RerateOrderCarriesNativeAssets (rroTxIn order))

requestedUsdm :: Integer -> Integer -> Coin -> Integer
requestedUsdm numerator denominator (Coin lovelace) =
    (lovelace * numerator) `div` denominator

addCoin :: Coin -> Coin -> Coin
addCoin (Coin left) (Coin right) = Coin (left + right)

subtractCoin :: Coin -> Coin -> Coin
subtractCoin (Coin left) (Coin right) = Coin (left - right)
