{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Wizard.InputControlTestHelpers
Description : Shared fixtures for
              'Amaru.Treasury.Wizard.InputControl' tests
              across Slices 1–7 of issue #184.
License     : Apache-2.0

A tiny fixture surface so the per-wizard test modules in
Slices 2–7 build their candidate lists from the same
@(TX_HASH, IX, hasAsset)@ triples and the same canonical
'OutRef' values, instead of every spec rolling its own.

Kept under @test/unit@ so it is not part of the production
library surface.
-}
module Amaru.Treasury.Wizard.InputControlTestHelpers
    ( -- * Sample hex hashes (64-char lowercase)
      hashA
    , hashB
    , hashC

      -- * Sample 'OutRef' values
    , outRefA0
    , outRefB1
    , outRefC2

      -- * Sample candidate pool
    , sampleCandidates
    , mkCandidate
    , candidateRef
    ) where

import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.Wizard.InputControl
    ( OutRef
    , parseOutRef
    )

-- ----------------------------------------------------------------------
-- Sample hex hashes
-- ----------------------------------------------------------------------

-- | 64 lowercase @'a'@ characters — a valid hex hash.
hashA :: Text
hashA = T.replicate 64 "a"

-- | 64 lowercase @'b'@ characters — a valid hex hash.
hashB :: Text
hashB = T.replicate 64 "b"

-- | 64 lowercase @'c'@ characters — a valid hex hash.
hashC :: Text
hashC = T.replicate 64 "c"

-- ----------------------------------------------------------------------
-- Sample OutRefs
-- ----------------------------------------------------------------------

-- | @hashA#0@.
outRefA0 :: OutRef
outRefA0 = mustParse (hashA <> "#0")

-- | @hashB#1@.
outRefB1 :: OutRef
outRefB1 = mustParse (hashB <> "#1")

-- | @hashC#2@.
outRefC2 :: OutRef
outRefC2 = mustParse (hashC <> "#2")

mustParse :: Text -> OutRef
mustParse t = case parseOutRef t of
    Right r -> r
    Left e ->
        error
            ( "InputControlTestHelpers: bad fixture "
                <> T.unpack t
                <> ": "
                <> T.unpack e
            )

-- ----------------------------------------------------------------------
-- Candidate pool
-- ----------------------------------------------------------------------

{- | A three-element candidate pool used by every Slice 1
filter test and reused by Slices 2–7 to seed
focused-regression fixtures. Each element is
@(txHash, ix, hasAsset)@ — the third field is a
placeholder so Slices 2–7 can extend the asset-set
classification without changing the tuple shape.
-}
sampleCandidates :: [(Text, Integer, Bool)]
sampleCandidates =
    [ mkCandidate hashA 0 False
    , mkCandidate hashB 1 False
    , mkCandidate hashC 2 True
    ]

{- | Tiny builder so Slices 2–7 do not re-spell the tuple
shape at every call site.
-}
mkCandidate :: Text -> Integer -> Bool -> (Text, Integer, Bool)
mkCandidate h ix asset = (h, ix, asset)

{- | Project the 'OutRef' out of a sample-candidate tuple.
This is the @(a -> OutRef)@ argument passed to
'Amaru.Treasury.Wizard.InputControl.filterPool' by the
fixture-driven tests.
-}
candidateRef :: (Text, Integer, Bool) -> OutRef
candidateRef (h, ix, _) =
    mustParse (h <> "#" <> T.pack (show ix))
