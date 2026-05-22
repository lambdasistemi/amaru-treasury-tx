-- | #239 T013–T021 — top-level Halogen component for the
-- | treasury-inspect dashboard.
-- |
-- | Layout (top to bottom):
-- |   * Site header — title + tagline.
-- |   * Status banner — chain tip slot + last-refreshed
-- |     timestamp + degraded-state hint if any scope failed.
-- |   * Scope cards (4) — per-scope summary numbers
-- |     (lovelace, USDM, UTxO count) plus the full JSON tree
-- |     rendered via JsonView (FR-010a coverage,
-- |     FR-010b resolution).
-- |   * Recent-txs section — last 10 treasury txs as
-- |     cardanoscan links.
-- |   * Footer — docs / source / build-identity chip.

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
import Halogen.HTML.Properties as HP
import Halogen.Subscription as HS
import JsonView as JsonView

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
  -- ^ ISO timestamp of last completed refresh (best-effort).
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
    HH.div
      [ HP.classes [ HH.ClassName "app" ] ]
      [ siteHeader
      , statusBanner st
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

  statusBanner st =
    HH.section
      [ HP.classes [ HH.ClassName "status-banner" ] ]
      [ HH.div_
          [ chip "chain tip"
              ( case firstChainTipSlot st of
                  Just s -> "slot " <> show s
                  Nothing -> "—"
              )
          , chip "last refresh"
              (fromMaybe "—" st.lastRefresh)
          , chip "scopes"
              ( show (countLoaded st) <> " / "
                  <> show (Array.length allScopeNames)
                  <> " loaded"
              )
          ]
      , if anyFailed st then
          HH.p
            [ HP.classes [ HH.ClassName "status-hint" ] ]
            [ HH.text
                "Some chain queries timed out. \
                \The upstream cardano-node may still be syncing; \
                \the page will retry every 30 s."
            ]
        else
          HH.text ""
      ]

  chip label_ value_ =
    HH.span
      [ HP.classes [ HH.ClassName "chip" ] ]
      [ HH.span [ HP.classes [ HH.ClassName "chip-label" ] ]
          [ HH.text label_ ]
      , HH.span [ HP.classes [ HH.ClassName "chip-value" ] ]
          [ HH.text value_ ]
      ]

  renderScope st name =
    let
      ss = scopeOf st name
      body = case ss of
        Loading ->
          HH.div
            [ HP.classes [ HH.ClassName "scope-loading" ] ]
            [ HH.text "Loading…" ]
        Failed err ->
          HH.div
            [ HP.classes [ HH.ClassName "scope-error" ] ]
            [ HH.text err ]
        Loaded j ->
          HH.div_
            [ scopeSummary name j
            , HH.details_
                [ HH.summary_ [ HH.text "Full inspect JSON" ]
                , JsonView.render j
                ]
            ]
    in
      HH.section
        [ HP.classes [ HH.ClassName "scope-card" ] ]
        [ HH.h2_ [ HH.text (scopeTitle name) ]
        , HH.div
            [ HP.classes [ HH.ClassName "scope-id" ] ]
            [ HH.text (scopeKey name) ]
        , body
        ]

  recentTxsSection st =
    let
      entries = fromMaybe [] (map _.rtmEntries st.recent)
    in
      HH.section
        [ HP.classes [ HH.ClassName "recent-txs" ] ]
        [ HH.h2_ [ HH.text "Recent treasury txs" ]
        , if Array.null entries then
            HH.p
              [ HP.classes [ HH.ClassName "muted" ] ]
              [ HH.text "(manifest empty)" ]
          else
            HH.ul_ (map recentLi entries)
        ]

  recentLi e =
    HH.li_
      [ HH.span
          [ HP.classes [ HH.ClassName "tx-scope" ] ]
          [ HH.text e.rteScope ]
      , HH.text " · "
      , HH.span
          [ HP.classes [ HH.ClassName "tx-time" ] ]
          [ HH.text e.rteSubmittedAt ]
      , HH.text " · "
      , HH.a
          [ HP.href e.rteCardanoscanUrl
          , HP.target "_blank"
          , HP.rel "noopener"
          , HP.title e.rteTxid
          , HP.classes [ HH.ClassName "tx-link" ]
          ]
          [ HH.text (shortHex e.rteTxid) ]
      ]

  siteFooter st =
    HH.footer
      [ HP.classes [ HH.ClassName "site-footer" ] ]
      [ HH.div
          [ HP.classes [ HH.ClassName "footer-links" ] ]
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
          , HH.a
              [ HP.href "/v1/version"
              , HP.target "_blank"
              ]
              [ HH.text "/v1/version" ]
          ]
      , HH.div
          [ HP.classes [ HH.ClassName "build-id" ] ]
          [ HH.text
              ( case st.version of
                  Nothing -> "version pending…"
                  Just v ->
                    "build "
                      <> v.biGitCommit
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
      handleAction LoadStatic
      handleAction RefreshAll
      emitter <- H.liftEffect refreshTimer
      void $ H.subscribe emitter

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
-- Helpers

-- | Pretty render of a UTxO count + lovelace + USDM derived
-- | directly from the inspect JSON for a single scope. Falls
-- | back to a placeholder if the JSON shape changes upstream.
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
      [ HP.classes [ HH.ClassName "scope-summary" ] ]
      [ summaryStat "ADA"
          (showAda lovelace)
      , summaryStat "USDM"
          (showUsdm usdm)
      , summaryStat "UTxOs"
          (show utxoCount)
      ]

summaryStat :: forall w i. String -> String -> HH.HTML w i
summaryStat label_ value_ =
  HH.div
    [ HP.classes [ HH.ClassName "summary-stat" ] ]
    [ HH.div [ HP.classes [ HH.ClassName "stat-value" ] ]
        [ HH.text value_ ]
    , HH.div [ HP.classes [ HH.ClassName "stat-label" ] ]
        [ HH.text label_ ]
    ]

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

showAda :: Number -> String
showAda lovelace =
  let
    ada = lovelace / 1000000.0
  in
    formatThousands (Int.round ada)

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

anyFailed :: State -> Boolean
anyFailed st =
  Array.any
    ( \n -> case scopeOf st n of
        Failed _ -> true
        _ -> false
    )
    allScopeNames

refreshTimer :: Effect (HS.Emitter Action)
refreshTimer = do
  { emitter, listener } <- HS.create
  _ <- setInterval 30000 (HS.notify listener RefreshAll)
  pure emitter

foreign import nowIso :: Effect String
