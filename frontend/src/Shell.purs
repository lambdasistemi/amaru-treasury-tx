-- | #263 — shared shell: scope taxonomy + topbar + site
-- | footer.  Consumed by both the View (read-only inspect)
-- | and Operate (swap-wizard form) pages so the chrome is
-- | byte-identical across routes.

module Shell
  ( -- * Scope taxonomy
    Scope(..)
  , scopeSlug
  , scopeShort
  , scopeLong
  , allScopes

    -- * Shared chrome
  , topbar
  , siteFooter

    -- * Cross-page theme state
  , initialTheme
  , toggleThemeEff
  , themeLabel
  ) where

import Prelude

import Effect (Effect)
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

import Routing (Route(..))
import Theme as Theme

-- ---------------------------------------------------------------------------
-- Scope taxonomy

data Scope
  = CoreDevelopment
  | OpsAndUseCases
  | NetworkCompliance
  | Middleware
  | Contingency

derive instance eqScope :: Eq Scope

-- | Snake-case identifier the CLI + on-chain registry both use.
scopeSlug :: Scope -> String
scopeSlug = case _ of
  CoreDevelopment -> "core_development"
  OpsAndUseCases -> "ops_and_use_cases"
  NetworkCompliance -> "network_compliance"
  Middleware -> "middleware"
  Contingency -> "contingency"

-- | Short human label fit for narrow UI surfaces (scope pill).
scopeShort :: Scope -> String
scopeShort = case _ of
  CoreDevelopment -> "Core dev"
  OpsAndUseCases -> "Ops & use"
  NetworkCompliance -> "Network"
  Middleware -> "Middleware"
  Contingency -> "Contingency"

-- | Long human label for card titles / status banners.
scopeLong :: Scope -> String
scopeLong = case _ of
  CoreDevelopment -> "Core development"
  OpsAndUseCases -> "Ops & use cases"
  NetworkCompliance -> "Network compliance"
  Middleware -> "Middleware"
  Contingency -> "Contingency"

allScopes :: Array Scope
allScopes =
  [ CoreDevelopment
  , OpsAndUseCases
  , NetworkCompliance
  , Middleware
  , Contingency
  ]

-- ---------------------------------------------------------------------------
-- Topbar

-- | Top bar with brand, View/Operate nav, and a theme-toggle
-- | button.  Both pages call this with their own
-- | page-specific 'onToggleTheme' action so the click wires
-- | back into the right component.
topbar
  :: forall w i
   . Route
  -> { themeLabel :: String, onToggleTheme :: i }
  -> HH.HTML w i
topbar active opts =
  HH.div [ HP.classes [ cn "topbar" ] ]
    [ HH.div
        [ HP.classes
            [ cn "md-typescale-title-large", cn "topbar__brand" ]
        ]
        [ HH.text "Amaru Treasury" ]
    , HH.nav [ HP.classes [ cn "topbar__nav" ] ]
        [ navLink RouteView active "/" "View"
        , navLink RouteOperate active "/operate" "Operate"
        ]
    , HH.button
        [ HP.classes [ cn "topbar__theme-btn" ]
        , HE.onClick (\_ -> opts.onToggleTheme)
        ]
        [ HH.text opts.themeLabel ]
    ]

navLink :: forall w i. Route -> Route -> String -> String -> HH.HTML w i
navLink target active href label =
  HH.a
    ( [ HP.href href
      , HP.classes [ cn "topbar__nav-link" ]
      ]
        <> if target == active then
          [ HP.attr (HH.AttrName "aria-current") "page" ]
        else []
    )
    [ HH.text label ]

-- ---------------------------------------------------------------------------
-- Footer

-- | Common footer: docs / source / API surface links + a
-- | machine-readable build-identity line.  Pages pass
-- | their own build-identity rendering function so the
-- | footer doesn't depend on any Api.* type.
siteFooter
  :: forall w i
   . { buildIdentityLine :: String }
  -> HH.HTML w i
siteFooter opts =
  HH.div
    [ HP.classes
        [ cn "md-typescale-body-small", cn "site-footer" ]
    ]
    [ HH.div [ HP.classes [ cn "site-footer__links" ] ]
        [ extLink
            "https://lambdasistemi.github.io/amaru-treasury-tx/"
            "Docs"
        , extLink
            "https://github.com/lambdasistemi/amaru-treasury-tx"
            "Source"
        , extLink "/v1/version" "/v1/version"
        , extLink "/v1/recent-txs" "/v1/recent-txs"
        ]
    , HH.div [ HP.classes [ cn "site-footer__build" ] ]
        [ HH.text opts.buildIdentityLine ]
    ]
  where
  extLink href label =
    HH.a
      [ HP.href href
      , HP.target "_blank"
      , HP.rel "noopener"
      ]
      [ HH.text label ]

cn :: String -> HH.ClassName
cn = HH.ClassName

-- ---------------------------------------------------------------------------
-- Theme (shared across pages via localStorage + <html data-theme>)

-- | Read the persisted theme + apply it to <html>.  Pages call
-- | this once at Initialize and store the returned 'Theme.Theme'
-- | in their state so the topbar button can render the inverse
-- | label.
initialTheme :: Effect Theme.Theme
initialTheme = do
  t <- Theme.initialTheme
  Theme.applyTheme t
  pure t

-- | Compute the next theme, apply it to <html>, persist it to
-- | localStorage, and return the new value.  One-call upgrade
-- | for any page's topbar click handler.
toggleThemeEff :: Theme.Theme -> Effect Theme.Theme
toggleThemeEff t = do
  let next = Theme.next t
  Theme.applyTheme next
  Theme.persistTheme next
  pure next

-- | Topbar button label for the *opposite* theme (clicking
-- | Light switches to Light → label says "Dark"; clicking
-- | Dark says "Light").
themeLabel :: Theme.Theme -> String
themeLabel = case _ of
  Theme.Dark -> "Light"
  Theme.Light -> "Dark"
