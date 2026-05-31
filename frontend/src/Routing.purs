-- | #263 / #267 — minimal client-side routing.  Three
-- | routes: view (formerly "inspect") at `/` or `/view`,
-- | audit at `/audit`, operate (formerly "build") at
-- | `/operate`, and books at `/books` (per-field operator
-- | history management).

module Routing
  ( Route(..)
  , currentRoute
  ) where

import Prelude

import Effect (Effect)

data Route = RouteView | RouteAudit | RouteOperate | RouteBooks

derive instance eqRoute :: Eq Route

currentRoute :: Effect Route
currentRoute = do
  p <- _pathname
  pure case p of
    "/audit" -> RouteAudit
    "/operate" -> RouteOperate
    "/books" -> RouteBooks
    _ -> RouteView

foreign import _pathname :: Effect String
