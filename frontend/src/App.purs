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
import Data.Either (Either(..))
import Data.Foldable (sum, traverse_)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String.CodePoints as CodePoints
import Effect (Effect)
import Effect.Aff.Class (class MonadAff)
import Effect.Timer (setInterval)
import Foreign.Object as FO
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
  , lastRefresh :: Maybe String
  , theme :: Theme.Theme
  }

data Action
  = Initialize
  | RefreshOne ScopeName
  | RefreshAll
  | LoadStatic
  | ToggleTheme

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
  , lastRefresh: Nothing
  , theme: Theme.Dark
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
      [ HH.h1
          [ HP.classes
              [ HH.ClassName "md-typescale-display-medium"
              , HH.ClassName "site-header__title"
              ]
          ]
          [ HH.text "Amaru Treasury" ]
      , HH.p
          [ HP.classes
              [ HH.ClassName "md-typescale-body-large"
              , HH.ClassName "site-header__lede"
              ]
          ]
          [ HH.text
              "Live read-only view across the five registered \
              \scopes of the Amaru 2026 treasury."
          ]
      , statusBanner st
      ]

  totalsStrip totals =
    HH.div
      [ HP.classes [ HH.ClassName "totals" ] ]
      [ totalTile "Total ADA" (showAda totals.ada)
      , totalTile "Total USDM" (showUsdm totals.usdm)
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

  statusBanner st =
    md "md-chip-set"
      []
      [ chip "chain tip"
          ( case firstChainTipSlot st of
              Just s -> "slot " <> formatThousands s
              Nothing -> "—"
          )
      , chip "last refresh" (fromMaybe "—" st.lastRefresh)
      , chip "scopes loaded"
          ( show (countLoaded st) <> " / "
              <> show (Array.length allScopeNames)
          )
      ]

  chip label_ value_ =
    md "md-assist-chip"
      [ HP.prop (HH.PropName "label")
          (label_ <> "  " <> value_)
      ]
      []

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
            , scopeKvList name j
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
                    [ HH.text "⎘ Copy inspect JSON" ]
                , JsonView.render
                    ( Argonaut.fromObject
                        (FO.singleton "details" j)
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
      H.modify_ \s -> s { theme = theme }
      handleAction LoadStatic
      handleAction RefreshAll
      emitter <- H.liftEffect refreshTimer
      void $ H.subscribe emitter

    ToggleTheme -> do
      st <- H.get
      let t' = Theme.next st.theme
      H.liftEffect (Theme.applyTheme t')
      H.liftEffect (Theme.persistTheme t')
      H.modify_ \s -> s { theme = t' }

    RefreshAll -> do
      traverse_ (handleAction <<< RefreshOne) allScopeNames
      now <- H.liftEffect nowIso
      H.modify_ \s -> s { lastRefresh = Just now }

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
      [ stat "ADA" (showAda lovelace)
      , stat "USDM" (showUsdm usdm)
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

scopeKvList :: forall w i. ScopeName -> Json -> HH.HTML w i
scopeKvList name j =
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
      [ kvLink "treasury address"
          (shortAddr addr)
          addr
          ("https://cardanoscan.io/address/" <> addr)
      , kvLink "treasury script hash"
          (shortHex scriptHash)
          scriptHash
          ("https://cardanoscan.io/script/" <> scriptHash)
      , kvItem "pending swap orders"
          (formatThousands pendingCount) ""
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

-- ---------------------------------------------------------------------------
-- Formatting

showAda :: Number -> String
showAda lovelace =
  formatThousands (Int.round (lovelace / 1000000.0))

showUsdm :: Number -> String
showUsdm n = formatThousands (Int.round (n / 1000000.0))

formatThousands :: Int -> String
formatThousands n =
  let
    s = show n
    chars = CodePoints.toCodePointArray s
    rev = Array.reverse chars
    grouped = chunkBy 3 rev
    withSep =
      Array.intercalate
        (CodePoints.toCodePointArray ",")
        grouped
  in
    CodePoints.fromCodePointArray (Array.reverse withSep)

chunkBy :: forall a. Int -> Array a -> Array (Array a)
chunkBy n xs =
  case Array.length xs of
    0 -> []
    _ ->
      let
        { before, after } = Array.splitAt n xs
      in
        Array.cons before (chunkBy n after)

shortHex :: String -> String
shortHex s
  | CodePoints.length s <= 14 = s
  | otherwise =
      CodePoints.take 8 s
        <> "…"
        <> CodePoints.drop (CodePoints.length s - 6) s

shortAddr :: String -> String
shortAddr s
  | CodePoints.length s <= 18 = s
  | otherwise =
      CodePoints.take 11 s
        <> "…"
        <> CodePoints.drop (CodePoints.length s - 6) s

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

countLoaded :: State -> Int
countLoaded st =
  Array.length
    ( Array.filter
        ( \n -> case scopeOf st n of
            Loaded _ -> true
            _ -> false
        )
        allScopeNames
    )

refreshTimer :: Effect (HS.Emitter Action)
refreshTimer = do
  { emitter, listener } <- HS.create
  _ <- setInterval 30000 (HS.notify listener RefreshAll)
  pure emitter

foreign import nowIso :: Effect String
