{- |
Module      : Amaru.Treasury.Build.Reorganize.Batch
Description : Pure scaler that picks the largest reorganize batch
              that fits per-tx exec units + size limits
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The reorganize builder spends every selected treasury UTxO with a
Plutus redeemer; each redeemer evaluation inspects the full script
context, so the per-tx exec-unit cost grows roughly as @O(N²)@ in
input count. On real treasuries (e.g. mainnet @network_compliance@,
55 UTxOs at probe time) a "merge everything" tx blows the per-tx
ceiling by an order of magnitude and cannot submit.

This module is the closed-form math that picks the largest @N@-input
subset whose total exec units stay under
@ppMaxTxExUnits + ppMaxTxSize@, given **one** evaluator measurement
of a trial build.

Approximation: @cost(N) ≈ k · N²@. The fixed overhead (withdraw
redeemer + scopes lookup) is treated as part of @k · N²@ rather than
as an additive constant, which makes the math conservative — it
under-estimates the safe @N*@ slightly. A refinement iteration (run
again with @N*@, re-measure, re-scale) tightens the picked value if
the operator asks for fewer batches.

> @nStarFromMeasured currentN measured limit alpha = floor (fromIntegral currentN * sqrt (alpha * fromIntegral limit / fromIntegral measured))@

Applied independently to memory, steps, and tx-size; the binding
@N*@ is the smallest of the three.
-}
module Amaru.Treasury.Build.Reorganize.Batch
    ( -- * Types
      BatchInputs (..)
    , BatchLimits (..)
    , BatchDecision (..)

      -- * The math
    , decideBatch
    , nStarFromMeasured
    ) where

import Cardano.Ledger.Plutus (ExUnits (..))
import Numeric.Natural (Natural)

{- | What was just measured on a trial build.

@biMeasuredCost@ is the sum of all redeemer 'ExUnits' that came
out of the Plutus evaluator on the trial. @biMeasuredSize@ is the
serialised CBOR length of the trial tx. @biCurrentN@ is the number
of treasury inputs used for that trial.
-}
data BatchInputs = BatchInputs
    { biMeasuredCost :: !ExUnits
    , biMeasuredSize :: !Int
    , biCurrentN :: !Int
    }
    deriving (Eq, Show)

{- | Per-tx protocol-parameter caps, scaled by the operator's
safety margin.

@blMaxExUnits@ comes from @ppMaxTxExUnitsL@; @blMaxSize@ from
@ppMaxTxSizeL@. @blSafetyAlpha@ is the safety factor in @[0, 1]@ —
typically @0.85@ — applied to all three dimensions to leave
headroom for fee re-balancing.
-}
data BatchLimits = BatchLimits
    { blMaxExUnits :: !ExUnits
    , blMaxSize :: !Int
    , blSafetyAlpha :: !Rational
    }
    deriving (Eq, Show)

{- | What the scaler tells the runner to do.

@BatchKeep@ — the trial already fits; build with the full input set.
@BatchTruncateTo n@ — rebuild after truncating the input list to its
largest-value @n@ entries (@n >= 2@; reorganize requires at least two
inputs to merge).
-}
data BatchDecision
    = BatchKeep
    | BatchTruncateTo !Int
    deriving (Eq, Show)

{- | Picks the largest fitting @N*@.

If the trial build already fits all three caps (mem, steps, size)
with the safety margin applied, returns 'BatchKeep' so the runner
can use the full set without rebuilding. Otherwise scales @N*@ down
via the closed-form sqrt formula on each dimension and returns the
minimum, capped at 2 below (reorganize requires @≥ 2@).
-}
decideBatch :: BatchInputs -> BatchLimits -> BatchDecision
decideBatch bi bl
    | fitsAll = BatchKeep
    | otherwise = BatchTruncateTo (max 2 nStar)
  where
    n = biCurrentN bi
    ExUnits measMem measSteps = biMeasuredCost bi
    measSize = biMeasuredSize bi
    ExUnits maxMem maxSteps = blMaxExUnits bl
    maxSize = blMaxSize bl
    alpha = blSafetyAlpha bl

    fitsAll =
        underAlpha (toInteger measMem) (toInteger maxMem) alpha
            && underAlpha (toInteger measSteps) (toInteger maxSteps) alpha
            && underAlpha (toInteger measSize) (toInteger maxSize) alpha

    nFromMem =
        nStarFromMeasured n measMem maxMem alpha
    nFromSteps =
        nStarFromMeasured n measSteps maxSteps alpha
    -- Size is linear in N, so the scaler is @N * α * limit / size@,
    -- not the sqrt. Approximate by treating size as quadratic too:
    -- the sqrt result is strictly smaller than the linear one, so
    -- this is the conservative direction.
    nFromSize =
        nStarFromMeasuredSize n measSize maxSize alpha

    nStar = minimum [nFromMem, nFromSteps, nFromSize]

{- | The closed-form scaler.

Given a measurement @cost(currentN) = measured@ and a target
@target = floor(α · limit)@, finds the largest integer @N@ such
that the projected cost @cost(N) ≈ measured · (N / currentN)² ≤
target@:

> N* = floor(currentN · sqrt(target / measured))

Returns @currentN@ unchanged when the measurement already fits the
target (no need to truncate on that dimension). Returns @0@ if
@measured == 0@ (defensive: the evaluator should never emit zero).
-}
nStarFromMeasured
    :: Int
    -- ^ currentN
    -> Natural
    -- ^ measured cost
    -> Natural
    -- ^ pparams limit (max per-tx)
    -> Rational
    -- ^ safety alpha (0,1]
    -> Int
nStarFromMeasured n measured maxLimit alpha
    | measured == 0 = n
    | underAlpha (toInteger measured) (toInteger maxLimit) alpha = n
    | otherwise = nFromRatio
  where
    -- target = floor(α · maxLimit)
    target :: Rational
    target = alpha * toRational maxLimit

    ratio :: Rational
    ratio = target / toRational measured

    -- N* = floor(currentN · sqrt(ratio))
    nFromRatio :: Int
    nFromRatio =
        floor (fromIntegral n * sqrtR ratio :: Double)

-- | Size scaler: linear in N. Same shape, no sqrt.
nStarFromMeasuredSize
    :: Int -> Int -> Int -> Rational -> Int
nStarFromMeasuredSize n measured maxLimit alpha
    | measured == 0 = n
    | underAlpha (toInteger measured) (toInteger maxLimit) alpha = n
    | otherwise = floor (fromIntegral n * scale :: Double)
  where
    target :: Rational
    target = alpha * toRational maxLimit
    scale :: Double
    scale = fromRational (target / toRational measured)

-- | True iff @measured ≤ α · limit@, with both sides as 'Integer'.
underAlpha :: Integer -> Integer -> Rational -> Bool
underAlpha measured limit alpha =
    toRational measured <= alpha * toRational limit

{- | 'sqrt' on a 'Rational' via 'Double' — good enough for an
integer floor that's then bounded by chain validation.
-}
sqrtR :: Rational -> Double
sqrtR = sqrt . fromRational
