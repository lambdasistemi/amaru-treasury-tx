-- | #239 T013 — top-level Halogen component for the
-- | treasury-inspect dashboard. Provides the page chrome
-- | (header + footer with docs link + build-identity chip)
-- | and four empty scope card slots; data fetching arrives in
-- | T014+.

module App where

import Prelude

import Data.Maybe (Maybe(..))
import Effect.Aff.Class (class MonadAff)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP

type State = Unit

data Action = Initialize

component
  :: forall query input output m
   . MonadAff m
  => H.Component query input output m
component =
  H.mkComponent
    { initialState: \_ -> unit
    , render
    , eval:
        H.mkEval H.defaultEval
          { initialize = Just Initialize
          , handleAction = handleAction
          }
    }
  where
  render :: State -> H.ComponentHTML Action () m
  render _ =
    HH.div
      [ HP.classes [ HH.ClassName "app" ] ]
      [ header
      , main_
      , footer
      ]

  header =
    HH.header
      [ HP.classes [ HH.ClassName "site-header" ] ]
      [ HH.h1_ [ HH.text "Amaru Treasury" ]
      , HH.p
          [ HP.classes [ HH.ClassName "site-tagline" ] ]
          [ HH.text
              "Live read-only view across the four registered scopes."
          ]
      ]

  main_ =
    HH.main
      [ HP.classes [ HH.ClassName "site-main" ] ]
      [ HH.p_
          [ HH.text
              "Dashboard scopes load in T014; this is the T012/T013 chrome."
          ]
      ]

  footer =
    HH.footer
      [ HP.classes [ HH.ClassName "site-footer" ] ]
      [ HH.a
          [ HP.href
              "https://lambdasistemi.github.io/amaru-treasury-tx/"
          , HP.target "_blank"
          , HP.rel "noopener"
          ]
          [ HH.text "Docs" ]
      , HH.text " · "
      , HH.a
          [ HP.href
              "https://github.com/lambdasistemi/amaru-treasury-tx"
          , HP.target "_blank"
          , HP.rel "noopener"
          ]
          [ HH.text "Source" ]
      ]

  handleAction :: Action -> H.HalogenM State Action () output m Unit
  handleAction = case _ of
    Initialize -> pure unit
