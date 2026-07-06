-- | #263 / #267 — minimal client-side routing.  Routes live in
-- | the `page` query parameter so the dashboard can be served
-- | from any static-preview subpath.

module Routing
  ( Route(..)
  , currentRoute
  , routeHref
  ) where

import Prelude

import Control.Monad (when)
import Data.Maybe (Maybe(..))
import Effect (Effect)
import FFI.Url as Url

data Route
  = RouteView
  | RouteAudit
  | RouteOperate
  | RoutePending
  | RouteBooks

derive instance eqRoute :: Eq Route

currentRoute :: Effect Route
currentRoute = do
  page <- Url.getPageParam
  case routeFromPage page of
    Just route -> do
      when (page /= "") (Url.setPageParam (routePage route))
      pure route
    Nothing -> do
      Url.setPageParam ""
      pure RouteView

routeHref :: Route -> String
routeHref route = "?page=" <> routePage route

routePage :: Route -> String
routePage = case _ of
  RouteView -> "view"
  RouteAudit -> "audit"
  RouteOperate -> "operate"
  RoutePending -> "pending"
  RouteBooks -> "books"

routeFromPage :: String -> Maybe Route
routeFromPage = case _ of
  "" -> Just RouteView
  "view" -> Just RouteView
  "audit" -> Just RouteAudit
  "operate" -> Just RouteOperate
  "pending" -> Just RoutePending
  "books" -> Just RouteBooks
  _ -> Nothing
