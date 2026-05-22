{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.InputControl
Description : Shared @--exclude-utxo@ / @--extra-tx-in@
              parsing, validation, and pool filtering.
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Single source of truth for the operator's wizard-input
control surface introduced by
[issue #184](https://github.com/lambdasistemi/amaru-treasury-tx/issues/184).
Every in-scope wizard (Slices 2–7) consumes this module
so the seven wizards do not duplicate the outref parser,
the contradiction check, the candidate-pool filter, or the
shortfall-with-excludes rendering.

This module is the FROZEN Slice 1 module: extensions land
in a forward slice, not via amend.
-}
module Amaru.Treasury.Wizard.InputControl
    ( -- * Outref
      OutRef
    , parseOutRef
    , outRefText

      -- * Operator-supplied sets
    , ExclusionSet (ExclusionSet)
    , ForcedInclusionSet (ForcedInclusionSet)

      -- * Validation
    , InputControlError (Contradiction)
    , validateInputControl

      -- * Pool filter
    , filterPool

      -- * @optparse-applicative@ parsers
    , excludeUtxoP
    , extraTxInP

      -- * Rendering
    , renderInputControlError
    , renderShortfallWithExcludes
    ) where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T
import Options.Applicative
    ( Parser
    , eitherReader
    , help
    , long
    , many
    , metavar
    , option
    )

-- ----------------------------------------------------------------------
-- OutRef
-- ----------------------------------------------------------------------

{- | A Conway transaction output reference: a 64-char
lowercase-hex transaction id paired with a non-negative
output index.

Construct via 'parseOutRef'; render via 'outRefText'. The
constructor is intentionally not exported so every
'OutRef' value in the codebase has been through the same
syntactic gate.
-}
data OutRef = OutRef !Text !Integer
    deriving stock (Eq, Ord, Show)

{- | Parse a @TX_HASH#IX@ string into an 'OutRef'. Returns
'Left' with a human-readable reason if the input is not a
64-char lowercase hex hash, a @#@ separator, and a
non-negative decimal integer.
-}
parseOutRef :: Text -> Either Text OutRef
parseOutRef raw =
    case T.splitOn "#" raw of
        [h, ix]
            | not (isValidHash h) ->
                Left
                    ( "invalid tx hash (need 64 \
                      \lowercase hex chars): "
                        <> raw
                    )
            | not (isValidIndex ix) ->
                Left
                    ( "invalid output index (need \
                      \non-negative decimal): "
                        <> raw
                    )
            | otherwise ->
                Right
                    ( OutRef h (read (T.unpack ix))
                    )
        _ ->
            Left
                ( "invalid outref (need TX_HASH#IX): "
                    <> raw
                )

isValidHash :: Text -> Bool
isValidHash h =
    T.length h == 64 && T.all isLowerHex h

isLowerHex :: Char -> Bool
isLowerHex c =
    isDigit c || (c >= 'a' && c <= 'f')

isValidIndex :: Text -> Bool
isValidIndex ix =
    not (T.null ix) && T.all isDigit ix

-- | Canonical @TX_HASH#IX@ rendering of an 'OutRef'.
outRefText :: OutRef -> Text
outRefText (OutRef h ix) =
    h <> "#" <> T.pack (show ix)

-- ----------------------------------------------------------------------
-- Operator-supplied sets
-- ----------------------------------------------------------------------

{- | The set of outrefs supplied via @--exclude-utxo@ on a
single wizard invocation. List shape preserves operator
input order, which the contradiction error reuses for
deterministic reporting.
-}
newtype ExclusionSet = ExclusionSet [OutRef]
    deriving stock (Eq, Show)

{- | The set of outrefs supplied via @--extra-tx-in@ on a
single wizard invocation. List shape preserves operator
input order; the @extraTxIns@ array emitted into
@intent.json@ uses the same order (FR-006).
-}
newtype ForcedInclusionSet = ForcedInclusionSet [OutRef]
    deriving stock (Eq, Show)

-- ----------------------------------------------------------------------
-- Validation
-- ----------------------------------------------------------------------

{- | Structured errors raised by the input-control layer.

The single 'Contradiction' constructor lists every outref
supplied to both @--exclude-utxo@ and @--extra-tx-in@ on
the same wizard invocation.
-}
newtype InputControlError
    = Contradiction [OutRef]
    deriving stock (Eq, Show)

{- | Check that no outref appears in both the exclusion
set and the forced-inclusion set. Returns 'Left
(Contradiction refs)' naming every overlap in the
exclusion set's input order; returns 'Right ()' otherwise.
-}
validateInputControl
    :: ExclusionSet
    -> ForcedInclusionSet
    -> Either InputControlError ()
validateInputControl
    (ExclusionSet excl)
    (ForcedInclusionSet forced) =
        case filter (`elem` forced) excl of
            [] -> Right ()
            bad -> Left (Contradiction bad)

-- ----------------------------------------------------------------------
-- Pool filter
-- ----------------------------------------------------------------------

{- | Filter a candidate pool by the operator's exclusion
set and remove any forced-inclusion ref that is already in
the pool (FR-006 dedup). Returns the 4-tuple
@(remaining, hits, inert, extras)@:

* @remaining@: pool with excluded refs and pool-present
  forced refs removed, in original order;
* @hits@: subset of the exclusion set that matched at
  least one pool element, in exclusion-set order;
* @inert@: subset of the exclusion set that did not match
  any pool element, in exclusion-set order. Per the spec's
  Edge Case, an inert exclusion is a no-op against the
  pool, but the caller logs it so the operator sees that
  their @--exclude-utxo@ was applied (and was vacuous);
* @extras@: forced-inclusion set in input order, used by
  callers to populate @intent.json@'s @extraTxIns@.

Parameterised over @candidateRef@ so callers can use any
candidate-pool element type as long as it exposes an
'OutRef'.
-}
filterPool
    :: (a -> OutRef)
    -> ExclusionSet
    -> ForcedInclusionSet
    -> [a]
    -> ([a], [OutRef], [OutRef], [OutRef])
filterPool
    candidateRef
    (ExclusionSet excl)
    (ForcedInclusionSet forced)
    pool =
        let poolRefs = map candidateRef pool
            keep x =
                candidateRef x `notElem` excl
                    && candidateRef x `notElem` forced
            remaining = filter keep pool
            hits = filter (`elem` poolRefs) excl
            inert = filter (`notElem` poolRefs) excl
        in  (remaining, hits, inert, forced)

-- ----------------------------------------------------------------------
-- optparse-applicative parsers
-- ----------------------------------------------------------------------

{- | Repeatable @--exclude-utxo TX_HASH#IX@ flag.
Collects every occurrence into an exclusion list in input
order. Wizards wrap the result in 'ExclusionSet'.
-}
excludeUtxoP :: Parser [OutRef]
excludeUtxoP =
    many
        ( option
            (eitherReader outRefReader)
            ( long "exclude-utxo"
                <> metavar "TX_HASH#IX"
                <> help
                    "Exclude this outref from the \
                    \candidate set before selection. \
                    \Repeatable."
            )
        )

{- | Repeatable @--extra-tx-in TX_HASH#IX@ flag. Collects
every occurrence into a forced-inclusion list in input
order. Wizards wrap the result in 'ForcedInclusionSet' and
emit it into @intent.json@'s @extraTxIns@.
-}
extraTxInP :: Parser [OutRef]
extraTxInP =
    many
        ( option
            (eitherReader outRefReader)
            ( long "extra-tx-in"
                <> metavar "TX_HASH#IX"
                <> help
                    "Force this outref as an extra \
                    \wallet input. Repeatable."
            )
        )

outRefReader :: String -> Either String OutRef
outRefReader s =
    case parseOutRef (T.pack s) of
        Right r -> Right r
        Left e -> Left (T.unpack e)

-- ----------------------------------------------------------------------
-- Rendering
-- ----------------------------------------------------------------------

{- | Render an 'InputControlError' as a single line of
operator-facing text. The contradiction case names every
conflicting outref so the operator can see which flag
pair must be reconciled.
-}
renderInputControlError :: InputControlError -> Text
renderInputControlError (Contradiction refs) =
    "contradictory --exclude-utxo / \
    \--extra-tx-in for: "
        <> T.intercalate ", " (map outRefText refs)

{- | Append the operator's excluded refs to an existing
shortfall error message. Empty exclusion list returns the
base message unchanged. Otherwise the output is:

@
\<base\>
excluded utxos:
\<ref1\>
\<ref2\>
@

with no trailing newline and one ref per line in the
caller's input order, per the spec's
shortfall-naming-every-exclusion requirement (FR-008).
-}
renderShortfallWithExcludes :: Text -> [OutRef] -> Text
renderShortfallWithExcludes base [] = base
renderShortfallWithExcludes base refs =
    base
        <> "\nexcluded utxos:\n"
        <> T.intercalate "\n" (map outRefText refs)
