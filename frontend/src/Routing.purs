-- | #263 — minimal client-side routing.  Two routes:
-- | view (formerly "inspect") at `/` or `/view`, operate
-- | (formerly "build") at `/operate`.

module Routing
  ( Route(..)
  , currentRoute
  ) where

import Prelude

import Effect (Effect)

data Route = RouteView | RouteOperate

derive instance eqRoute :: Eq Route

currentRoute :: Effect Route
currentRoute = do
  p <- _pathname
  pure case p of
    "/operate" -> RouteOperate
    _ -> RouteView

foreign import _pathname :: Effect String
