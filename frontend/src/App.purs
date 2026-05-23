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
import Data.Argonaut.Core (Json, caseJsonObject)
import Data.Argonaut.Core as Argonaut
import Data.Array as Array
import Data.Either (Either(..))
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
import JsonView as JsonView
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

derive instance eqScopeName :: Eq ScopeName

scopeKey :: ScopeName -> String
scopeKey = case _ of
  CoreDevelopment -> "core_development"
  OpsAndUseCases -> "ops_and_use_cases"
  NetworkCompliance -> "network_compliance"
  Middleware -> "middleware"

scopeTitle :: ScopeName -> String
scopeTitle = case _ of
  CoreDevelopment -> "Core development"
  OpsAndUseCases -> "Ops & use cases"
  NetworkCompliance -> "Network compliance"
  Middleware -> "Middleware"

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
  , lastRefresh: Nothing
  , theme: Theme.Dark
  }

scopeOf :: State -> ScopeName -> ScopeState
scopeOf st = case _ of
  CoreDevelopment -> st.scopes.core_development
  OpsAndUseCases -> st.scopes.ops_and_use_cases
  NetworkCompliance -> st.scopes.network_compliance
  Middleware -> st.scopes.middleware

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
    HH.div_
      [ topbar st
      , siteHeader
      , statusBanner st
      , scopeGrid st
      , siteFooter st
      ]

  topbar st =
    HH.div
      [ HP.style
          "display:flex;align-items:center;\
          \justify-content:space-between;gap:16px;"
      ]
      [ HH.div
          [ HP.classes [ HH.ClassName "md-typescale-title-large" ]
          , HP.style
              "display:flex;align-items:center;gap:8px;\
              \color:var(--md-sys-color-on-surface);"
          ]
          [ HH.text "amaru-treasury" ]
      , md "md-text-button"
          [ HE.onClick (\_ -> ToggleTheme) ]
          [ HH.text
              ( case st.theme of
                  Theme.Dark -> "Light"
                  Theme.Light -> "Dark"
              )
          ]
      ]

  siteHeader =
    HH.div_
      [ HH.div
          [ HP.classes
              [ HH.ClassName "md-typescale-label-small" ]
          , HP.style
              "color:var(--md-sys-color-on-surface-variant);\
              \text-transform:uppercase;letter-spacing:0.1em;"
          ]
          [ HH.text "amaru-treasury.plutimus.com" ]
      , HH.h1
          [ HP.classes
              [ HH.ClassName "md-typescale-display-medium" ]
          , HP.style "margin:4px 0 8px 0;"
          ]
          [ HH.text "Amaru Treasury" ]
      , HH.p
          [ HP.classes
              [ HH.ClassName "md-typescale-body-large" ]
          , HP.style
              "margin:0;color:var(--md-sys-color-on-surface-variant);\
              \max-width:64ch;"
          ]
          [ HH.text
              "Live read-only view across the four registered \
              \scopes of the Amaru 2026 treasury."
          ]
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

  scopeGrid st =
    HH.div
      [ HP.style
          "display:grid;grid-template-columns:repeat(auto-fit,\
          \minmax(min(100%,420px),1fr));gap:16px;"
      ]
      (map (renderScope st) allScopeNames)

  renderScope st name =
    let
      ss = scopeOf st name
      body = case ss of
        Loading ->
          HH.p
            [ HP.classes
                [ HH.ClassName "md-typescale-body-medium" ]
            , HP.style
                "color:var(--md-sys-color-on-surface-variant);"
            ]
            [ HH.text "Loading live treasury state…" ]
        Failed err ->
          HH.p
            [ HP.classes
                [ HH.ClassName "md-typescale-body-medium" ]
            , HP.style
                "color:var(--md-sys-color-error);"
            ]
            [ HH.text err ]
        Loaded j ->
          HH.div_
            [ scopeSummary name j
            , scopeKvList name j
            , md "md-divider" [] []
            , HH.details_
                [ HH.summary
                    [ HP.classes
                        [ HH.ClassName
                            "md-typescale-label-large"
                        ]
                    , HP.style
                        "cursor:pointer;\
                        \color:var(--md-sys-color-primary);\
                        \padding:8px 0;"
                    ]
                    [ HH.text "Full inspect JSON" ]
                , JsonView.render j
                ]
            ]
    in
      md "md-elevated-card"
        [ HP.style
            "padding:20px;display:block;\
            \background:var(--md-sys-color-surface);\
            \color:var(--md-sys-color-on-surface);"
        ]
        [ HH.h2
            [ HP.classes
                [ HH.ClassName "md-typescale-title-large" ]
            , HP.style "margin:0 0 4px 0;"
            ]
            [ HH.text (scopeTitle name) ]
        , HH.div
            [ HP.classes
                [ HH.ClassName "md-typescale-label-small" ]
            , HP.style
                "color:var(--md-sys-color-on-surface-variant);\
                \margin-bottom:16px;"
            ]
            [ HH.text (scopeKey name) ]
        , body
        ]

  siteFooter st =
    HH.div
      [ HP.classes [ HH.ClassName "md-typescale-body-small" ]
      , HP.style
          "color:var(--md-sys-color-on-surface-variant);\
          \display:flex;flex-wrap:wrap;gap:12px;\
          \justify-content:space-between;\
          \padding:12px 0;border-top:1px solid \
          \var(--md-sys-color-outline-variant);"
      ]
      [ HH.div
          [ HP.style "display:flex;flex-wrap:wrap;gap:12px;" ]
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
          [ HP.style
              "font-family:'Roboto Mono',monospace;font-size:0.75rem;"
          ]
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
      handleAction (RefreshOne CoreDevelopment)
      handleAction (RefreshOne OpsAndUseCases)
      handleAction (RefreshOne NetworkCompliance)
      handleAction (RefreshOne Middleware)
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
      [ HP.style
          "display:grid;grid-template-columns:repeat(3,1fr);\
          \gap:8px;margin-bottom:12px;"
      ]
      [ stat "ADA" (showAda lovelace)
      , stat "USDM" (showUsdm usdm)
      , stat "UTxOs" (formatThousands utxoCount)
      ]

stat :: forall w i. String -> String -> HH.HTML w i
stat label_ value_ =
  HH.div
    [ HP.style
        "padding:10px 12px;\
        \background:var(--md-sys-color-surface-variant);\
        \color:var(--md-sys-color-on-surface-variant);\
        \border-radius:12px;"
    ]
    [ HH.div
        [ HP.classes [ HH.ClassName "md-typescale-title-medium" ]
        , HP.style
            "font-family:'Roboto Mono',monospace;\
            \color:var(--md-sys-color-on-surface);"
        ]
        [ HH.text value_ ]
    , HH.div
        [ HP.classes [ HH.ClassName "md-typescale-label-small" ]
        , HP.style "text-transform:uppercase;letter-spacing:0.08em;"
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
      , kvLink "view on cardanoscan"
          "history & balance"
          ("Recent activity at " <> addr)
          ("https://cardanoscan.io/address/" <> addr)
      ]

kvItem
  :: forall w i
   . String -> String -> String -> HH.HTML w i
kvItem label_ value_ titleAttr =
  md "md-list-item"
    [ HP.title titleAttr ]
    [ HH.div
        [ HP.attr (HH.AttrName "slot") "headline"
        , HP.style
            "font-family:'Roboto Mono',monospace;\
            \overflow-wrap:anywhere;"
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
        , HP.style
            "font-family:'Roboto Mono',monospace;\
            \overflow-wrap:anywhere;color:var(--md-sys-color-primary);"
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
