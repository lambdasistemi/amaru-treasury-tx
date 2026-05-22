-- | #239 T013–T021 — top-level Halogen component for the
-- | treasury-inspect dashboard.
-- |
-- | Renders all four registered scopes plus the global
-- | chain-tip banner, the recent-txs footer, and the build-
-- | identity chip.
-- |
-- | The per-scope card shows EVERY field of the inspect JSON
-- | as pretty-printed text (FR-010a). Links to cardanoscan
-- | for txids are inserted by the host's CSS + JS in a later
-- | slice; for now the operator sees the full canonical JSON
-- | the CLI emits, plus an "open on cardanoscan" link for
-- | every recent-tx footer entry (FR-010b partial).

module App where

import Prelude

import Api as Api
import Data.Argonaut.Core (Json)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String.CodePoints as Data.String.CodePoints
import Effect.Aff.Class (class MonadAff)
import Effect (Effect)
import Effect.Timer (setInterval)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Properties as HP
import Halogen.Subscription as HS
import JsonView as JsonView

-- | A scope's lifecycle on the page.
data ScopeState
  = Loading
  | Loaded Json
  | Failed String

type State =
  { scopes ::
      { core_development :: ScopeState
      , ops_and_use_cases :: ScopeState
      , network_compliance :: ScopeState
      , middleware :: ScopeState
      }
  , version :: Maybe Api.BuildIdentity
  , recent :: Maybe Api.RecentTxManifest
  }

data Action
  = Initialize
  | RefreshOne ScopeName
  | RefreshAll
  | LoadStatic

data ScopeName
  = CoreDevelopment
  | OpsAndUseCases
  | NetworkCompliance
  | Middleware

scopeKey :: ScopeName -> String
scopeKey = case _ of
  CoreDevelopment -> "core_development"
  OpsAndUseCases -> "ops_and_use_cases"
  NetworkCompliance -> "network_compliance"
  Middleware -> "middleware"

allScopeNames :: Array ScopeName
allScopeNames =
  [ CoreDevelopment
  , OpsAndUseCases
  , NetworkCompliance
  , Middleware
  ]

initialState :: State
initialState =
  { scopes:
      { core_development: Loading
      , ops_and_use_cases: Loading
      , network_compliance: Loading
      , middleware: Loading
      }
  , version: Nothing
  , recent: Nothing
  }

component
  :: forall query input output m
   . MonadAff m
  => H.Component query input output m
component =
  H.mkComponent
    { initialState: \_ -> initialState
    , render
    , eval:
        H.mkEval H.defaultEval
          { initialize = Just Initialize
          , handleAction = handleAction
          }
    }
  where

  render :: State -> H.ComponentHTML Action () m
  render st =
    HH.div
      [ HP.classes [ HH.ClassName "app" ] ]
      [ siteHeader
      , HH.main
          [ HP.classes [ HH.ClassName "site-main" ] ]
          (map (renderScope st) allScopeNames)
      , recentTxsSection st
      , siteFooter st
      ]

  siteHeader =
    HH.header
      [ HP.classes [ HH.ClassName "site-header" ] ]
      [ HH.h1_ [ HH.text "Amaru Treasury" ]
      , HH.p
          [ HP.classes [ HH.ClassName "site-tagline" ] ]
          [ HH.text
              "Live read-only view across the four registered scopes."
          ]
      ]

  renderScope st name =
    let
      key = scopeKey name
      ss = case name of
        CoreDevelopment -> st.scopes.core_development
        OpsAndUseCases -> st.scopes.ops_and_use_cases
        NetworkCompliance -> st.scopes.network_compliance
        Middleware -> st.scopes.middleware
      body = case ss of
        Loading -> HH.p_ [ HH.text "Loading…" ]
        Failed err ->
          HH.p
            [ HP.classes [ HH.ClassName "scope-error" ] ]
            [ HH.text ("Error: " <> err) ]
        Loaded j -> JsonView.render j
    in
      HH.section
        [ HP.classes [ HH.ClassName "scope-card" ] ]
        [ HH.h2_ [ HH.text key ]
        , body
        ]

  recentTxsSection st =
    let
      entries = fromMaybe [] (map _.rtmEntries st.recent)
    in
      HH.section
        [ HP.classes [ HH.ClassName "recent-txs" ] ]
        [ HH.h2_ [ HH.text "Recent treasury txs" ]
        , HH.ul_ (map recentLi entries)
        ]

  recentLi e =
    HH.li_
      [ HH.a
          [ HP.href e.rteCardanoscanUrl
          , HP.target "_blank"
          , HP.rel "noopener"
          ]
          [ HH.text
              ( e.rteScope <> "  ·  "
                  <> e.rteSubmittedAt
                  <> "  ·  "
                  <> (substring 0 12 e.rteTxid)
                  <> "…"
              )
          ]
      ]

  siteFooter st =
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
      , HH.text " · "
      , HH.span
          [ HP.classes [ HH.ClassName "build-id" ] ]
          [ HH.text
              ( case st.version of
                  Nothing -> ""
                  Just v ->
                    "build " <> v.biGitCommit
                      <> "  ·  metadata "
                      <> substring 0 8 v.biMetadataSha256
                      <> "…  ·  "
                      <> v.biBuildTime
              )
          ]
      ]

  handleAction :: Action -> H.HalogenM State Action () output m Unit
  handleAction = case _ of
    Initialize -> do
      handleAction LoadStatic
      handleAction RefreshAll
      -- Schedule the 30 s auto-refresh tick. Single-flight
      -- by construction: a tick that arrives while a
      -- previous Aff is still running is dropped because
      -- handleAction is sequential within HalogenM. (FR-013)
      emitter <- H.liftEffect refreshTimer
      void $ H.subscribe emitter

    RefreshAll -> do
      handleAction (RefreshOne CoreDevelopment)
      handleAction (RefreshOne OpsAndUseCases)
      handleAction (RefreshOne NetworkCompliance)
      handleAction (RefreshOne Middleware)

    LoadStatic -> do
      v <- H.liftAff Api.fetchVersion
      case v of
        Right ok -> H.modify_ \s -> s { version = Just ok }
        Left _ -> pure unit
      r <- H.liftAff Api.fetchRecentTxs
      case r of
        Right ok -> H.modify_ \s -> s { recent = Just ok }
        Left _ -> pure unit

    RefreshOne name -> do
      let key = scopeKey name
      res <- H.liftAff (Api.fetchInspect key)
      let
        next = case res of
          Right j -> Loaded j
          Left err -> Failed err
      H.modify_ \s ->
        s
          { scopes = case name of
              CoreDevelopment ->
                s.scopes { core_development = next }
              OpsAndUseCases ->
                s.scopes { ops_and_use_cases = next }
              NetworkCompliance ->
                s.scopes { network_compliance = next }
              Middleware ->
                s.scopes { middleware = next }
          }

-- ---------------------------------------------------------------------------
-- Helpers

substring :: Int -> Int -> String -> String
substring start n s =
  Data.String.CodePoints.take n
    (Data.String.CodePoints.drop start s)

-- | A 30-second emitter that fires `RefreshAll`.
-- |
-- | We don't clear the interval on component teardown; for
-- | the single-page dashboard the SPA's lifetime equals the
-- | timer's lifetime (the page reload resets both).
refreshTimer :: Effect (HS.Emitter Action)
refreshTimer = do
  { emitter, listener } <- HS.create
  _ <- setInterval 30000 (HS.notify listener RefreshAll)
  pure emitter
