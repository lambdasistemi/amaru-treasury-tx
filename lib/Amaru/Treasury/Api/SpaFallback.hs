{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.SpaFallback
Description : SPA deep-link fallback middleware
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Middleware that rewrites known dashboard routes to @/@ so the static
asset handler serves the Halogen bundle on direct browser loads.
-}
module Amaru.Treasury.Api.SpaFallback
    ( spaFallback
    ) where

import Data.Text (Text)
import Network.Wai
    ( Middleware
    , pathInfo
    )

{- | Rewrite known top-level SPA routes to @/@ before the static asset
handler runs.

Without this, a direct GET or browser refresh on a dashboard route that
only exists client-side falls through to Servant's raw handler lookup and
returns 404 instead of @index.html@.
-}
spaFallback :: Middleware
spaFallback app req respond
    | pathInfo req `elem` spaPaths =
        app req{pathInfo = []} respond
    | otherwise = app req respond
  where
    spaPaths :: [[Text]]
    spaPaths =
        [ ["operate"]
        , ["view"]
        , ["books"]
        , ["audit"]
        , ["pending"]
        ]
