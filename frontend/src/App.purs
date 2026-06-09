-- | #239 — Halogen renders Material Web Components verbatim.
-- |
-- | Visual language: Material 3
-- | (https://m3.material.io/components). No bespoke styling
-- | beyond the layout container in dist/index.html.
-- |
-- | Components used:
-- |   * `md-elevated-card`  — scope + recent-txs surfaces
-- |     (https://material-web.dev/components/card/)
-- |   * `md-list` + `md-list-item` — kv rows
-- |     (https://material-web.dev/components/list/)
-- |   * `md-icon-button`    — theme toggle
-- |   * `md-divider`        — separators
-- |   * `md-chip-set` + `md-assist-chip` — status banner
-- |
-- | Typography classes (.md-typescale-*) ship from
-- | dist/material.js via document.adoptedStyleSheets.

module App where

import Prelude

import Api as Api
import Routing as Routing
import Shell as Shell
import Data.Argonaut.Core (Json, caseJsonObject)
import Data.Argonaut.Core as Argonaut
import Data.Array as Array
import Data.DateTime.Instant (Instant, unInstant)
import Data.Either (Either(..))
import Data.Foldable (sum, traverse_)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Set (Set)
import Data.Set as Set
import Data.String.CodePoints as CodePoints
import Data.Time.Duration (Milliseconds(..))
import Effect (Effect)
import Effect.Aff (delay)
import Effect.Aff.Class (class MonadAff)
import Effect.Now (now)
import Effect.Timer (setInterval)
import Foreign.Object as FO
import Format (formatScaled, formatThousands, formatTreeJson, shortAddr, shortHex)
import Shell.Clipboard as Clipboard
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Halogen.Subscription as HS
import JsonTree as JsonView
import Theme as Theme

-- ---------------------------------------------------------------------------
-- Model

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
      , contingency :: ScopeState
      }
  , version :: Maybe Api.BuildIdentity
  , recent :: Maybe Api.RecentTxManifest
  -- #289 slice E — the dashboard status row uses an
  -- `Instant` rather than an ISO string so the relative
  -- time ("12 s ago" / "5 min ago") can be computed every
  -- tick without re-parsing.  Updated on every successful
  -- `RefreshAll`.
  , lastRefreshAt :: Maybe Instant
  -- Wall-clock tick for the relative-time renderer.  A
  -- 1 s timer (`tickTimer`) writes here so the chip text
  -- updates without re-running the chain query.
  , clockNow :: Maybe Instant
  , theme :: Theme.Theme
  -- #289 slice F — transient per-value flags for the
  -- dashboard copy buttons.  Both indexed by the full
  -- value string (the natural unique key — the same string
  -- is the clipboard payload).  An entry in 'copiedKeys'
  -- means the icon stays a check-mark for ~1 s; an entry
  -- in 'failedKeys' means the "Copy failed" caption is
  -- visible below the button for ~3 s.
  , copiedKeys :: Set String
  , failedKeys :: Set String
  }

data Action
  = Initialize
  | RefreshOne ScopeName
  | RefreshAll
  | LoadStatic
  | ToggleTheme
  -- #289 slice E — 1 s clock tick driving the relative
  -- time on the dashboard status row.  Independent of the
  -- 30 s chain refresh so the "x s ago" label updates
  -- every second.
  | TickNow
  -- #289 slice F — colocated copy buttons for long-string
  -- values on the dashboard.  'CopyValue' invokes the
  -- clipboard FFI and dispatches one of the
  -- 'ClearCopied' / 'ClearFailed' actions after the
  -- feedback timeout elapses.
  | CopyValue String
  | ClearCopied String
  | ClearFailed String

data ScopeName
  = CoreDevelopment
  | OpsAndUseCases
  | NetworkCompliance
  | Middleware
  | Contingency

derive instance eqScopeName :: Eq ScopeName

scopeKey :: ScopeName -> String
scopeKey = case _ of
  CoreDevelopment -> "core_development"
  OpsAndUseCases -> "ops_and_use_cases"
  NetworkCompliance -> "network_compliance"
  Middleware -> "middleware"
  Contingency -> "contingency"

scopeTitle :: ScopeName -> String
scopeTitle = case _ of
  CoreDevelopment -> "Core development"
  OpsAndUseCases -> "Ops & use cases"
  NetworkCompliance -> "Network compliance"
  Middleware -> "Middleware"
  Contingency -> "Contingency"

allScopeNames :: Array ScopeName
allScopeNames =
  [ CoreDevelopment
  , OpsAndUseCases
  , NetworkCompliance
  , Middleware
  , Contingency
  ]

initialState :: State
initialState =
  { scopes:
      { core_development: Loading
      , ops_and_use_cases: Loading
      , network_compliance: Loading
      , middleware: Loading
      , contingency: Loading
      }
  , version: Nothing
  , recent: Nothing
  , lastRefreshAt: Nothing
  , clockNow: Nothing
  , theme: Theme.Dark
  , copiedKeys: Set.empty
  , failedKeys: Set.empty
  }

scopeOf :: State -> ScopeName -> ScopeState
scopeOf st = case _ of
  CoreDevelopment -> st.scopes.core_development
  OpsAndUseCases -> st.scopes.ops_and_use_cases
  NetworkCompliance -> st.scopes.network_compliance
  Middleware -> st.scopes.middleware
  Contingency -> st.scopes.contingency

-- ---------------------------------------------------------------------------
-- Component

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
    let
      totals = computeTotals st
    in
      HH.div_
        [ topbar st
        , siteHeader st
        , statusRow st
        , totalsStrip totals
        , scopeGrid st totals.ada
        , siteFooter st
        ]

  topbar st =
    Shell.topbar Routing.RouteView
      { themeLabel:
          case st.theme of
            Theme.Dark -> "Light"
            Theme.Light -> "Dark"
      , onToggleTheme: ToggleTheme
      }

  siteHeader st =
    HH.div
      [ HP.classes [ HH.ClassName "site-header" ] ]
      -- #289 slice H — shrunk hero scale: heading drops from
      -- `display-medium` to `headline-medium`, lede drops from
      -- `body-large` to `body-medium`, and the `.site-header`
      -- CSS slashes its padding so the per-scope cards land
      -- in the first viewport fold (≤ 800 px desktop /
      -- ≤ 700 px mobile).
      [ HH.h1
          [ HP.classes
              [ HH.ClassName "md-typescale-headline-medium"
              , HH.ClassName "site-header__title"
              ]
          ]
          [ HH.text "Amaru Treasury" ]
      , HH.p
          [ HP.classes
              [ HH.ClassName "md-typescale-body-medium"
              , HH.ClassName "site-header__lede"
              ]
          ]
          [ HH.text
              "Live read-only view across the five registered \
              \scopes of the Amaru 2026 treasury."
          ]
      ]

  totalsStrip totals =
    HH.div
      [ HP.classes [ HH.ClassName "totals" ] ]
      [ totalTile "Total ADA" (formatScaled totals.ada)
      , totalTile "Total USDM" (formatScaled totals.usdm)
      , totalTile "Total UTxOs" (formatThousands totals.utxos)
      ]

  totalTile label_ value_ =
    HH.div
      [ HP.classes [ HH.ClassName "totals__tile" ] ]
      [ HH.div
          [ HP.classes
              [ HH.ClassName "md-typescale-title-medium"
              , HH.ClassName "totals__value"
              ]
          ]
          [ HH.text value_ ]
      , HH.div
          [ HP.classes
              [ HH.ClassName "md-typescale-label-small"
              , HH.ClassName "totals__label"
              ]
          ]
          [ HH.text label_ ]
      ]

  -- | #289 slice E — top-of-/ status row.  Chain tip slot
  -- | (from the existing `chainTip` query), relative
  -- | last-refresh time, and one chip per scope tracking
  -- | fresh / stale / partial state.  Replaces the old
  -- | `statusBanner` chip set which used Material assist
  -- | chips inside `siteHeader`; the new row sits ABOVE
  -- | the scope grid and uses a plain `.status-row` div so
  -- | the per-scope `data-state` colour tokens can drive
  -- | the visual differentiation.
  statusRow st =
    HH.div
      [ HP.classes [ HH.ClassName "status-row" ]
      , HP.attr (HH.AttrName "aria-label")
          "Treasury status"
      ]
      [ HH.div
          [ HP.classes [ HH.ClassName "status-row__meta" ] ]
          [ statusPair "chain tip"
              ( case firstChainTipSlot st of
                  Just s -> formatThousands s
                  Nothing -> "—"
              )
          , statusPair "refreshed"
              (relativeTime st.clockNow st.lastRefreshAt)
          ]
      , HH.div
          [ HP.classes [ HH.ClassName "status-row__scopes" ] ]
          (map (scopeStatusChip st) allScopeNames)
      ]

  statusPair label_ value_ =
    HH.span
      [ HP.classes [ HH.ClassName "status-row__pair" ] ]
      [ HH.span
          [ HP.classes [ HH.ClassName "status-row__label" ] ]
          [ HH.text label_ ]
      , HH.span
          [ HP.classes [ HH.ClassName "status-row__value" ] ]
          [ HH.text value_ ]
      ]

  scopeStatusChip st name =
    let
      status = scopeLoadStatus
        st.clockNow
        st.lastRefreshAt
        (scopeOf st name)
      slug = scopeKey name
      stateSlug = loadStatusSlug status
    in
      HH.span
        [ HP.classes [ HH.ClassName "scope-chip" ]
        , HP.attr (HH.AttrName "data-state") stateSlug
        , HP.attr (HH.AttrName "data-scope") slug
        , HP.attr (HH.AttrName "aria-label")
            (slug <> " scope, " <> stateSlug)
        ]
        [ HH.span
            [ HP.classes [ HH.ClassName "scope-chip__name" ] ]
            [ HH.text slug ]
        , HH.span
            [ HP.classes [ HH.ClassName "scope-chip__state" ] ]
            [ HH.text stateSlug ]
        ]

  scopeGrid st totalAda =
    HH.div
      [ HP.classes [ HH.ClassName "scope-grid" ] ]
      (map (renderScope st totalAda) allScopeNames)

  renderScope st totalAda name =
    let
      ss = scopeOf st name
      share =
        if totalAda <= 0.0 then 0.0
        else scopeStateAda ss / totalAda
      body = case ss of
        Loading ->
          HH.p
            [ HP.classes
                [ HH.ClassName "md-typescale-body-medium"
                , HH.ClassName "scope-card__loading"
                ]
            ]
            [ HH.text "Loading live treasury state…" ]
        Failed err ->
          HH.p
            [ HP.classes
                [ HH.ClassName "md-typescale-body-medium"
                , HH.ClassName "scope-card__error"
                ]
            ]
            [ HH.text err ]
        Loaded j ->
          HH.div_
            [ scopeSummary name j
            , scopeKvList st name j
            , md "md-divider" [] []
            -- The JSON tree is rendered under a single
            -- "details" super-key so the user gets the
            -- same key-click-to-collapse UX as every
            -- other compound entry inside the tree
            -- (instead of a special button + nested
            -- wrapper).
            , HH.div
                [ HP.classes
                    [ HH.ClassName "json-tree-wrapper" ]
                ]
                [ HH.button
                    [ HP.classes
                        [ HH.ClassName
                            "v-copy v-copy--block"
                        ]
                    , HP.attr
                        (HH.AttrName "data-copy")
                        (Argonaut.stringify j)
                    , HP.title "Copy inspect JSON"
                    , HP.type_ HP.ButtonButton
                    ]
                    [ md "md-icon" [] [ HH.text "content_copy" ]
                    , HH.span_ [ HH.text "Copy inspect JSON" ]
                    ]
                , JsonView.render
                    ( Argonaut.fromObject
                        (FO.singleton "details" (formatTreeJson j))
                    )
                ]
            ]
    in
      md "md-elevated-card"
        [ HP.classes [ HH.ClassName "scope-card" ]
        , HP.style ("--share: " <> showShare share <> ";")
        ]
        [ HH.div
            [ HP.classes
                [ HH.ClassName "scope-card__head" ]
            ]
            [ HH.h2
                [ HP.classes
                    [ HH.ClassName "md-typescale-title-large"
                    , HH.ClassName "scope-card__title"
                    ]
                ]
                [ HH.text (scopeTitle name) ]
            , HH.div
                [ HP.classes
                    [ HH.ClassName "md-typescale-label-small"
                    , HH.ClassName "scope-card__slug"
                    ]
                ]
                [ HH.text (scopeKey name) ]
            ]
        , HH.div
            [ HP.classes [ HH.ClassName "scope-card__weight" ] ]
            []
        , HH.div
            [ HP.classes [ HH.ClassName "scope-card__body" ] ]
            [ body ]
        ]

  siteFooter st =
    HH.div
      [ HP.classes
          [ HH.ClassName "md-typescale-body-small"
          , HH.ClassName "site-footer"
          ]
      ]
      [ HH.div
          [ HP.classes [ HH.ClassName "site-footer__links" ] ]
          [ HH.a
              [ HP.href
                  "https://lambdasistemi.github.io/amaru-treasury-tx/"
              , HP.target "_blank"
              , HP.rel "noopener"
              ]
              [ HH.text "Docs" ]
          , HH.a
              [ HP.href
                  "https://github.com/lambdasistemi/amaru-treasury-tx"
              , HP.target "_blank"
              , HP.rel "noopener"
              ]
              [ HH.text "Source" ]
          , HH.a
              [ HP.href "/v1/version"
              , HP.target "_blank"
              ]
              [ HH.text "/v1/version" ]
          , HH.a
              [ HP.href "/v1/recent-txs"
              , HP.target "_blank"
              ]
              [ HH.text "/v1/recent-txs" ]
          ]
      , HH.div
          [ HP.classes [ HH.ClassName "site-footer__build" ] ]
          [ HH.text
              ( case st.version of
                  Nothing -> "build identity loading…"
                  Just v ->
                    "build " <> v.biGitCommit
                      <> "  ·  metadata "
                      <> shortHex v.biMetadataSha256
                      <> "  ·  "
                      <> v.biBuildTime
              )
          ]
      ]

  -- -------------------------------------------------------------------------
  -- Handlers

  handleAction
    :: Action -> H.HalogenM State Action () output m Unit
  handleAction = case _ of
    Initialize -> do
      theme <- H.liftEffect Theme.initialTheme
      H.liftEffect (Theme.applyTheme theme)
      t0 <- H.liftEffect now
      H.modify_ \s -> s { theme = theme, clockNow = Just t0 }
      handleAction LoadStatic
      handleAction RefreshAll
      emitter <- H.liftEffect refreshTimer
      void $ H.subscribe emitter
      -- #289 slice E — independent 1 s tick so the status
      -- row's relative-time chip updates between chain
      -- refreshes (without re-running the 30 s chain query
      -- every second).
      tickEmitter <- H.liftEffect tickTimer
      void $ H.subscribe tickEmitter

    ToggleTheme -> do
      st <- H.get
      let t' = Theme.next st.theme
      H.liftEffect (Theme.applyTheme t')
      H.liftEffect (Theme.persistTheme t')
      H.modify_ \s -> s { theme = t' }

    RefreshAll -> do
      traverse_ (handleAction <<< RefreshOne) allScopeNames
      t <- H.liftEffect now
      H.modify_ \s ->
        s { lastRefreshAt = Just t, clockNow = Just t }

    TickNow -> do
      t <- H.liftEffect now
      H.modify_ \s -> s { clockNow = Just t }

    CopyValue val -> do
      ok <- H.liftAff (Clipboard.writeTextWithResult val)
      if ok then do
        H.modify_ \s -> s
          { copiedKeys = Set.insert val s.copiedKeys
          , failedKeys = Set.delete val s.failedKeys
          }
        _ <- H.fork do
          H.liftAff (delay (Milliseconds 1000.0))
          handleAction (ClearCopied val)
        pure unit
      else do
        H.modify_ \s -> s
          { failedKeys = Set.insert val s.failedKeys
          , copiedKeys = Set.delete val s.copiedKeys
          }
        _ <- H.fork do
          H.liftAff (delay (Milliseconds 3000.0))
          handleAction (ClearFailed val)
        pure unit

    ClearCopied val ->
      H.modify_ \s -> s { copiedKeys = Set.delete val s.copiedKeys }

    ClearFailed val ->
      H.modify_ \s -> s { failedKeys = Set.delete val s.failedKeys }

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
      res <- H.liftAff (Api.fetchInspect (scopeKey name))
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
              Contingency ->
                s.scopes { contingency = next }
          }

-- ---------------------------------------------------------------------------
-- Material-element shim

md
  :: forall r w i
   . String
  -> Array (HH.IProp r i)
  -> Array (HH.HTML w i)
  -> HH.HTML w i
md tag = HH.element (HH.ElemName tag)

-- ---------------------------------------------------------------------------
-- Per-scope summary blocks

scopeSummary :: forall w i. ScopeName -> Json -> HH.HTML w i
scopeSummary name j =
  let
    section_ = lookupScopeSection (scopeKey name) j
    lovelace = readNumber section_ [ "totals", "lovelace" ]
    usdm = readNumber section_ [ "totals", "usdm" ]
    utxoCount =
      case section_ of
        Just s ->
          fromMaybe 0
            ( do
                a <- Argonaut.toArray =<< FO.lookup "treasuryUtxos" s
                pure (Array.length a)
            )
        Nothing -> 0
  in
    HH.div
      [ HP.classes [ HH.ClassName "stat-grid" ] ]
      [ stat "ADA" (formatScaled lovelace)
      , stat "USDM" (formatScaled usdm)
      , stat "UTxOs" (formatThousands utxoCount)
      ]

stat :: forall w i. String -> String -> HH.HTML w i
stat label_ value_ =
  HH.div
    [ HP.classes [ HH.ClassName "stat-tile" ] ]
    [ HH.div
        [ HP.classes
            [ HH.ClassName "md-typescale-title-medium"
            , HH.ClassName "stat-tile__value"
            ]
        ]
        [ HH.text value_ ]
    , HH.div
        [ HP.classes
            [ HH.ClassName "md-typescale-label-small"
            , HH.ClassName "stat-tile__label"
            ]
        ]
        [ HH.text label_ ]
    ]

scopeKvList :: forall w. State -> ScopeName -> Json -> HH.HTML w Action
scopeKvList st name j =
  let
    section_ = lookupScopeSection (scopeKey name) j
    addr = readString section_ "treasuryAddress"
    scriptHash = readString section_ "treasuryScriptHash"
    pendingCount =
      case section_ of
        Just s ->
          fromMaybe 0
            ( do
                a <- Argonaut.toArray =<< FO.lookup "pendingOrders" s
                pure (Array.length a)
            )
        Nothing -> 0
  in
    md "md-list"
      []
      [ copyRow
          { label: "treasury address"
          , truncated: shortAddr addr
          , full: addr
          , href: Just ("https://cardanoscan.io/address/" <> addr)
          , copied: Set.member addr st.copiedKeys
          , failed: Set.member addr st.failedKeys
          }
      , copyRow
          { label: "treasury script hash"
          , truncated: shortHex scriptHash
          , full: scriptHash
          , href: Just ("https://cardanoscan.io/script/" <> scriptHash)
          , copied: Set.member scriptHash st.copiedKeys
          , failed: Set.member scriptHash st.failedKeys
          }
      , kvItem "pending swap orders"
          (formatThousands pendingCount) ""
      ]

-- | #289 slice F — colocated copy-button row for any
-- | long-string value on the dashboard.  Renders the
-- | truncated display + optional cardanoscan link + a
-- | sibling copy icon-button + an inline failure caption.
-- | Replaces the old `md-list-item type="link"` row for the
-- | per-scope treasury address / script-hash entries: the
-- | typed-link semantic conflicted with placing an
-- | interactive child inside (Material Web's type=link
-- | swallows clicks before they reach the button).
copyRow
  :: forall w
   . { label :: String
     , truncated :: String
     , full :: String
     , href :: Maybe String
     , copied :: Boolean
     , failed :: Boolean
     }
  -> HH.HTML w Action
copyRow cfg =
  let
    valueNode = case cfg.href of
      Just h ->
        HH.a
          [ HP.title cfg.full
          , HP.classes
              [ HH.ClassName "copy-row__value"
              , HH.ClassName "mono"
              ]
          , HP.href h
          , HP.target "_blank"
          , HP.rel "noopener"
          ]
          [ HH.text cfg.truncated ]
      Nothing ->
        HH.span
          [ HP.title cfg.full
          , HP.classes
              [ HH.ClassName "copy-row__value"
              , HH.ClassName "mono"
              ]
          ]
          [ HH.text cfg.truncated ]
    icon = if cfg.copied then "check" else "content_copy"
    btnLabel = "Copy " <> cfg.label
  in
    HH.div
      [ HP.classes [ HH.ClassName "copy-row" ] ]
      [ HH.div
          [ HP.classes [ HH.ClassName "copy-row__label" ] ]
          [ HH.text cfg.label ]
      , valueNode
      , HH.button
          [ HP.classes [ HH.ClassName "copy-icon-btn" ]
          , HP.attr (HH.AttrName "data-state")
              ( if cfg.copied then "copied"
                else if cfg.failed then "failed"
                else "idle"
              )
          , HP.attr (HH.AttrName "aria-label") btnLabel
          , HP.title btnLabel
          , HP.type_ HP.ButtonButton
          , HE.onClick (\_ -> CopyValue cfg.full)
          ]
          [ md "md-icon" [] [ HH.text icon ] ]
      , if cfg.failed then
          HH.div
            [ HP.classes
                [ HH.ClassName "copy-row__failed" ]
            , HP.attr (HH.AttrName "role") "status"
            ]
            [ HH.text "Copy failed" ]
        else HH.text ""
      ]

kvItem
  :: forall w i
   . String -> String -> String -> HH.HTML w i
kvItem label_ value_ titleAttr =
  md "md-list-item"
    [ HP.title titleAttr ]
    [ HH.div
        [ HP.attr (HH.AttrName "slot") "headline"
        , HP.classes [ HH.ClassName "kv__value" ]
        ]
        [ HH.text value_ ]
    , HH.div
        [ HP.attr (HH.AttrName "slot") "supporting-text" ]
        [ HH.text label_ ]
    ]

-- | Like 'kvItem' but the headline value is a clickable
-- | cardanoscan link.
kvLink
  :: forall w i
   . String -> String -> String -> String -> HH.HTML w i
kvLink label_ value_ titleAttr href_ =
  md "md-list-item"
    [ HP.prop (HH.PropName "type") "link"
    , HP.prop (HH.PropName "href") href_
    , HP.prop (HH.PropName "target") "_blank"
    , HP.title titleAttr
    ]
    [ HH.div
        [ HP.attr (HH.AttrName "slot") "headline"
        , HP.classes
            [ HH.ClassName "kv__value"
            , HH.ClassName "kv__value--link"
            ]
        ]
        [ HH.text value_ ]
    , HH.div
        [ HP.attr (HH.AttrName "slot") "supporting-text" ]
        [ HH.text label_ ]
    ]

-- ---------------------------------------------------------------------------
-- JSON read helpers

lookupScopeSection :: String -> Json -> Maybe (FO.Object Json)
lookupScopeSection key j =
  caseJsonObject Nothing
    ( \root -> do
        scopes <- Argonaut.toArray =<< FO.lookup "scopes" root
        Array.findMap (matchScope key) scopes
    )
    j

matchScope :: String -> Json -> Maybe (FO.Object Json)
matchScope key j =
  caseJsonObject Nothing
    ( \obj -> do
        nameJ <- FO.lookup "scope" obj
        name <- Argonaut.toString nameJ
        if name == key then Just obj else Nothing
    )
    j

readNumber :: Maybe (FO.Object Json) -> Array String -> Number
readNumber Nothing _ = 0.0
readNumber (Just obj) path = go obj path
  where
  go o = case _ of
    [] -> 0.0
    [ k ] ->
      fromMaybe 0.0
        ( FO.lookup k o >>= Argonaut.toNumber )
    ks ->
      case Array.uncons ks of
        Nothing -> 0.0
        Just { head, tail } ->
          case FO.lookup head o of
            Just sub ->
              caseJsonObject 0.0 (\o' -> go o' tail) sub
            Nothing -> 0.0

readString
  :: Maybe (FO.Object Json) -> String -> String
readString Nothing _ = ""
readString (Just obj) key =
  fromMaybe "" (FO.lookup key obj >>= Argonaut.toString)

-- ---------------------------------------------------------------------------
-- Cross-scope aggregates (totals strip + per-card share)

type Totals = { ada :: Number, usdm :: Number, utxos :: Int }

computeTotals :: State -> Totals
computeTotals st =
  let
    triples = map (scopeStateTotals <<< scopeOf st) allScopeNames
  in
    { ada: sum (map _.ada triples)
    , usdm: sum (map _.usdm triples)
    , utxos: sum (map _.utxos triples)
    }

scopeStateTotals :: ScopeState -> Totals
scopeStateTotals = case _ of
  Loaded j ->
    let
      sect = lookupTopScope j
      ada = readNumber sect [ "totals", "lovelace" ]
      usdm = readNumber sect [ "totals", "usdm" ]
      utxos =
        case sect of
          Just s ->
            fromMaybe 0
              ( do
                  a <- Argonaut.toArray
                    =<< FO.lookup "treasuryUtxos" s
                  pure (Array.length a)
              )
          Nothing -> 0
    in
      { ada, usdm, utxos }
  _ -> { ada: 0.0, usdm: 0.0, utxos: 0 }

scopeStateAda :: ScopeState -> Number
scopeStateAda ss = (scopeStateTotals ss).ada

-- | Given the scopes object in the raw report, pick the first
-- | (and only) entry. Each Loaded report carries exactly one
-- | scope already.
lookupTopScope :: Json -> Maybe (FO.Object Json)
lookupTopScope j =
  caseJsonObject Nothing
    ( \root -> do
        scopes <- Argonaut.toArray
          =<< FO.lookup "scopes" root
        Array.head scopes >>= Argonaut.toObject
    )
    j

-- | Three-decimal share string for the inline `--share: …`
-- | custom property.  Clamped to [0, 1].
showShare :: Number -> String
showShare s =
  let
    clamped =
      if s < 0.0 then 0.0
      else if s > 1.0 then 1.0
      else s
    scaled = Int.round (clamped * 1000.0)
    leading = scaled / 1000
    trailing = scaled - (leading * 1000)
    pad3 n =
      let
        t = show n
      in
        case CodePoints.length t of
          1 -> "00" <> t
          2 -> "0" <> t
          _ -> t
  in
    show leading <> "." <> pad3 trailing

firstChainTipSlot :: State -> Maybe Int
firstChainTipSlot st =
  Array.findMap (chainTipSlotOf st) allScopeNames

chainTipSlotOf :: State -> ScopeName -> Maybe Int
chainTipSlotOf st name = case scopeOf st name of
  Loaded j -> readSlot j
  _ -> Nothing
  where
  readSlot =
    caseJsonObject Nothing
      ( \root -> do
          tip <- FO.lookup "chainTip" root
          caseJsonObject Nothing
            ( \tipObj -> do
                slotJ <- FO.lookup "slot" tipObj
                Argonaut.toNumber slotJ >>= \n -> pure (Int.round n)
            )
            tip
      )

refreshTimer :: Effect (HS.Emitter Action)
refreshTimer = do
  { emitter, listener } <- HS.create
  _ <- setInterval 30000 (HS.notify listener RefreshAll)
  pure emitter

-- | #289 slice E — 1 s wall-clock tick.  Independent of
-- | the 30 s chain refresh; just pushes a fresh `Instant`
-- | into `state.clockNow` so the relative-time chip
-- | re-renders every second.
tickTimer :: Effect (HS.Emitter Action)
tickTimer = do
  { emitter, listener } <- HS.create
  _ <- setInterval 1000 (HS.notify listener TickNow)
  pure emitter

-- ---------------------------------------------------------------------------
-- #289 slice E — dashboard status row helpers
--
-- Three indicators above the scope cards: the chain tip
-- slot (from the existing chainTip query), the time since
-- last successful refresh (relative; "12 s ago"), and a
-- per-scope chip row showing fresh / stale / partial.
--
-- Staleness threshold = 60 s: anything older than a
-- minute since the last successful chain query is
-- considered stale (the 30 s `refreshTimer` should keep
-- this rare, but a network blip leaves the operator
-- looking at older data — that's worth surfacing).

stalenessThresholdSeconds :: Int
stalenessThresholdSeconds = 60

data LoadStatus = StatusFresh | StatusStale | StatusPartial

derive instance eqLoadStatus :: Eq LoadStatus

loadStatusSlug :: LoadStatus -> String
loadStatusSlug = case _ of
  StatusFresh -> "fresh"
  StatusStale -> "stale"
  StatusPartial -> "partial"

-- | Per-scope load status.  Loaded + recent → fresh;
-- | Loaded + > 60 s old → stale; Failed / Loading →
-- | partial.  When the wall clock or `lastRefreshAt`
-- | aren't available yet (the initial render before
-- | Initialize has fired), the scope falls back to
-- | partial as the safest tri-state default.
scopeLoadStatus
  :: Maybe Instant
  -> Maybe Instant
  -> ScopeState
  -> LoadStatus
scopeLoadStatus mNow mLast s = case s of
  Loaded _ -> case secondsSince mNow mLast of
    Just secs | secs < stalenessThresholdSeconds -> StatusFresh
    _ -> StatusStale
  _ -> StatusPartial

-- | Whole-second difference between `now` and a reference
-- | instant, both wrapped in `Maybe` for the
-- | not-yet-initialized case.  Returns `Nothing` when
-- | either is missing.
secondsSince :: Maybe Instant -> Maybe Instant -> Maybe Int
secondsSince mNow mThen = do
  tNow <- mNow
  tThen <- mThen
  let
    Milliseconds a = unInstant tNow
    Milliseconds b = unInstant tThen
  pure (Int.round ((a - b) / 1000.0))

-- | Relative-time text for the status row's `refreshed:`
-- | chip.  Plain English at second / minute / hour / day
-- | granularity.  Returns `—` when the last-refresh time
-- | isn't yet known.
relativeTime :: Maybe Instant -> Maybe Instant -> String
relativeTime mNow mThen = case secondsSince mNow mThen of
  Nothing -> "—"
  Just s
    | s < 0 -> "now"
    | s < 60 -> show s <> " s ago"
    | s < 3600 -> show (s / 60) <> " min ago"
    | s < 86400 -> show (s / 3600) <> " hr ago"
    | otherwise -> show (s / 86400) <> " day ago"
