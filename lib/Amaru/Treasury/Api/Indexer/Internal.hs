{- |
Module      : Amaru.Treasury.Api.Indexer.Internal
Description : Compatibility re-export for readiness test helpers
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Compatibility re-export for tests that used to import the
readiness helper through the indexer module. New tests
should import "Amaru.Treasury.Api.Readiness.Internal".
-}
module Amaru.Treasury.Api.Indexer.Internal
    ( setReadinessForTest
    ) where

import Amaru.Treasury.Api.Readiness.Internal
    ( setReadinessForTest
    )
