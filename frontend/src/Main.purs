-- | #239 T012/T013 — Halogen entry point for the
-- | treasury-inspect dashboard. Mounts `App.component` into
-- | the `#app` div declared in `dist/index.html`.

module Main where

import Prelude

import Effect (Effect)
import Halogen.Aff as HA
import Halogen.VDom.Driver (runUI)

import App as App

main :: Effect Unit
main = HA.runHalogenAff do
  body <- HA.awaitBody
  runUI App.component unit body
