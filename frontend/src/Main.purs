-- | #239 — Halogen entry point. Mounts `App.component` INTO
-- | the `#app` host div declared in `dist/index.html` so the
-- | host stays the single styled container — `awaitBody`
-- | would mount as a body sibling and leak whitespace.

module Main where

import Prelude

import Data.Maybe (Maybe(..))
import Effect (Effect)
import Effect.Class (liftEffect)
import Effect.Exception (throw)
import Halogen.Aff (runHalogenAff)
import Halogen.VDom.Driver (runUI)
import Web.DOM.NonElementParentNode (getElementById)
import Web.HTML (window)
import Web.HTML.HTMLDocument as HTMLDocument
import Web.HTML.HTMLElement (HTMLElement)
import Web.HTML.HTMLElement as HTMLElement
import Web.HTML.Window (document)

import App as App

main :: Effect Unit
main = runHalogenAff do
  host <- liftEffect mountHost
  _ <- runUI App.component unit host
  pure unit

mountHost :: Effect HTMLElement
mountHost = do
  doc <- HTMLDocument.toNonElementParentNode <$>
    (document =<< window)
  el <- getElementById "app" doc
  case el >>= HTMLElement.fromElement of
    Just h -> pure h
    Nothing -> throw "mount: #app element not found"
