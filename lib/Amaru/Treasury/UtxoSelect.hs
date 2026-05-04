{- |
Module      : Amaru.Treasury.UtxoSelect
Description : UTxO selection with blacklist
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pure first-fit UTxO selection mirroring
[`select_treasury_utxos.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/select_treasury_utxos.sh):
walk the UTxO list in the given order, skip any whose
key is in the blacklist, accumulate the per-UTxO
quantity until the running total meets the target.

Parameterised over the UTxO key (typically @TxIn@) and
value (typically @TxOut ConwayEra@) so the algorithm
is independent of @cardano-ledger@; the per-UTxO
quantity extractor is supplied by the caller.

This module also supplies 'loadBlacklist': read a
newline-separated @txid#ix@ blacklist file matching
the bash convention.
-}
module Amaru.Treasury.UtxoSelect
    ( -- * Selection
      Selection (..)
    , select

      -- * Errors
    , SelectionError (..)

      -- * Blacklist I/O
    , loadBlacklistFile
    ) where

import Control.Exception (Exception)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T

-- | Result of a successful selection.
data Selection k v = Selection
    { selChosen :: ![(k, v)]
    -- ^ The UTxOs picked, in input order.
    , selAccumulated :: !Integer
    -- ^ Sum of the per-UTxO quantities of the chosen set.
    , selLeftover :: !Integer
    -- ^ @selAccumulated - target@. Always non-negative.
    }
    deriving (Eq, Show)

-- | Error raised when selection cannot meet the target.
data SelectionError = InsufficientFunds
    { sefRequested :: !Integer
    , sefAvailable :: !Integer
    }
    deriving (Eq, Show)

instance Exception SelectionError

{- | First-fit selection. Walks @utxos@ in order,
skipping any whose key appears in @blacklist@. For each
non-skipped entry, calls @qty@ to read the
selection-relevant quantity (lovelace for ADA, native
amount for tokens) and accumulates until the target is
reached.

For tokens (e.g. USDM), the caller is responsible for
filtering out UTxOs that don't carry the asset before
passing them in — i.e. set @qty = const 0@ for those
or pre-filter the list.

Returns 'Left' 'InsufficientFunds' if the entire list
is consumed without reaching the target.
-}
select
    :: (Ord k)
    => Set k
    -- ^ blacklist
    -> (v -> Integer)
    -- ^ per-UTxO quantity extractor
    -> Integer
    -- ^ target (must be > 0; @select 0@ returns an empty selection)
    -> [(k, v)]
    -- ^ candidate UTxOs
    -> Either SelectionError (Selection k v)
select blacklist qty target =
    go [] 0
  where
    go chosen acc us
        | acc >= target =
            Right $
                Selection
                    { selChosen = reverse chosen
                    , selAccumulated = acc
                    , selLeftover = acc - target
                    }
        | otherwise = case us of
            [] ->
                Left
                    InsufficientFunds
                        { sefRequested = target
                        , sefAvailable = acc
                        }
            (k, v) : rest
                | Set.member k blacklist ->
                    go chosen acc rest
                | otherwise ->
                    go ((k, v) : chosen) (acc + qty v) rest

{- | Read a blacklist file. Each non-empty,
non-comment line is one @txid#ix@ entry.
Comment lines start with @#@. Whitespace around
entries is trimmed.
-}
loadBlacklistFile :: FilePath -> IO [Text]
loadBlacklistFile path = do
    contents <- T.readFile path
    pure
        [ trimmed
        | line <- T.lines contents
        , let trimmed = T.strip line
        , not (T.null trimmed)
        , not ("#" `T.isPrefixOf` trimmed)
        ]
