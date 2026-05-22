{- |
Module      : Amaru.Treasury.Build.Reorganize.Batch
Description : Pure helpers for the reorganize batcher
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The reorganize builder spends every selected treasury UTxO with a
Plutus redeemer; each redeemer evaluation inspects the full script
context, so the per-tx exec-unit cost grows roughly as @O(N²)@ in
input count. On real treasuries (e.g. mainnet @network_compliance@,
55 UTxOs at probe time) a "merge everything" tx blows the per-tx
ceiling by an order of magnitude and cannot submit.

This module is the **pure** half of the batcher: a closed-form
estimator for the largest @N@ whose projected cost fits the per-tx
ceiling, plus the "does this measurement fit?" predicate. The
runner in @Amaru.Treasury.Build.Reorganize@ uses the estimator as
the **initial guess** of a projected linear descent, then steps
**down by 1** against actual rebuild measurements until it finds
the true cliff (no safety alpha needed because every chosen @N@ is
confirmed by a real measurement, not just the projection).

Math:

> cost(N) ≈ k · N²
> N*     = floor(currentN · sqrt(limit / measured))

Applied independently to memory, steps, and tx-size; the binding
@N*@ is the smallest of the three.
-}
module Amaru.Treasury.Build.Reorganize.Batch
    ( -- * Types
      BatchLimits (..)

      -- * Predicates
    , measurementFits

      -- * Closed-form initial guess
    , estimateNStar
    , nStarFromMeasured
    ) where

import Cardano.Ledger.Plutus (ExUnits (..))
import Numeric.Natural (Natural)

{- | Per-tx protocol-parameter caps.

@blMaxExUnits@ comes from @ppMaxTxExUnitsL@; @blMaxSize@ from
@ppMaxTxSizeL@. No safety margin — the step-down refinement
against real per-rebuild measurements lets us walk right up to the
ledger ceiling without leaving headroom on the table.
-}
data BatchLimits = BatchLimits
    { blMaxExUnits :: !ExUnits
    , blMaxSize :: !Int
    }
    deriving (Eq, Show)

{- | True iff a measurement fits all three caps under the actual
ledger limit.

This is what 'pickBatch' calls after each rebuild to decide whether
the chosen @N@ is the answer. No alpha — we have a real measurement
of a real tx; if the ledger would accept it, we accept it.
-}
measurementFits
    :: ExUnits
    -- ^ measured exec units at currentN
    -> Int
    -- ^ measured cbor size at currentN
    -> BatchLimits
    -> Bool
measurementFits (ExUnits measMem measSteps) measSize bl =
    let ExUnits maxMem maxSteps = blMaxExUnits bl
    in  measMem <= maxMem
            && measSteps <= maxSteps
            && measSize <= blMaxSize bl

{- | Closed-form initial guess for the projected linear descent.

Given a measurement at @currentN@ that's over budget, predicts the
largest @N*@ whose projected cost fits the ledger ceiling. Applied
independently to each dimension (memory, steps, size); returns the
smaller, never below 2 (reorganize requires at least two inputs).

The projection is only the **starting point** of the runner's
descent — it can over- or under-shoot the true cliff depending on
how well @cost(N) ≈ k · N²@ holds for the specific input set.
Step-down by 1 against actual rebuild measurements lands on the
empirical cliff.
-}
estimateNStar
    :: Int
    -- ^ currentN (where we measured)
    -> ExUnits
    -- ^ measured exec units at currentN
    -> Int
    -- ^ measured cbor size at currentN
    -> BatchLimits
    -> Int
estimateNStar n (ExUnits measMem measSteps) measSize bl =
    let ExUnits maxMem maxSteps = blMaxExUnits bl
        nFromMem = nStarFromMeasured n measMem maxMem
        nFromSteps = nStarFromMeasured n measSteps maxSteps
        nFromSize =
            nStarFromMeasuredSize n measSize (blMaxSize bl)
    in  max 2 (minimum [nFromMem, nFromSteps, nFromSize])

{- | The closed-form sqrt scaler — initial guess on one dimension.

@cost(N) ≈ k · N²@, so projecting from the measurement at @currentN@:

> N* = floor(currentN · sqrt(limit / measured))

Returns @currentN@ unchanged when the measurement already fits
(no scale-down needed). Returns @currentN@ defensively if the
measurement is @0@.

The runner in @Amaru.Treasury.Build.Reorganize@ uses this as the
initial guess of its projected linear descent; once an @N@ is
chosen, the next rebuild's actual measurement decides whether to
accept it or step down by 1.
-}
nStarFromMeasured
    :: Int
    -- ^ currentN
    -> Natural
    -- ^ measured cost
    -> Natural
    -- ^ pparams limit (max per-tx)
    -> Int
nStarFromMeasured n measured maxLimit
    | measured == 0 = n
    | measured <= maxLimit = n
    | otherwise =
        floor
            ( fromIntegral n
                * sqrt
                    ( fromIntegral maxLimit
                        / fromIntegral measured
                        :: Double
                    )
            )

-- | Size scaler: linear in N. Same shape, no sqrt.
nStarFromMeasuredSize :: Int -> Int -> Int -> Int
nStarFromMeasuredSize n measured maxLimit
    | measured == 0 = n
    | measured <= maxLimit = n
    | otherwise =
        floor
            ( fromIntegral n
                * ( fromIntegral maxLimit
                        / fromIntegral measured
                        :: Double
                  )
            )
