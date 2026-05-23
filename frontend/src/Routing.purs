-- | #263 — minimal client-side routing.  Two routes:
-- | inspect (current dashboard) at `/`, build form at
-- | `/build`. Reads `window.location.pathname` via a tiny
-- | FFI helper; no routing library.

module Routing
  ( Route(..)
  , currentRoute
  ) where

import Prelude

import Effect (Effect)

data Route = RouteInspect | RouteBuild

derive instance eqRoute :: Eq Route

currentRoute :: Effect Route
currentRoute = do
  p <- _pathname
  pure case p of
    "/build" -> RouteBuild
    _ -> RouteInspect

foreign import _pathname :: Effect String
