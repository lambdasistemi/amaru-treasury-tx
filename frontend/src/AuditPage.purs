-- | #310 — tx audit history view backed by the indexer API.

module AuditPage where

import Prelude

import Api as Api
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
import Data.Tuple (Tuple(..))
import Effect.Aff.Class (class MonadAff)
import Foreign.Object as FO
import Format
  ( assetNameText
  , formatThousands
  , formatThousandsN
  , shortAddr
  , shortHex
  , showAda
  )
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Routing (Route(..))
import Shell as Shell
import Shell.Clipboard as Clipboard
import Theme as Theme

data LoadState
  = Loading
  | Loaded Api.ScopeHistoryResponse
  | Failed String

data DetailState
  = DetailIdle
  | DetailLoading String
  | DetailLoaded Api.TxDetailResponse
  | DetailNotFound String
  | DetailFailed String

-- | State of the RDF lens: a named SPARQL query result or a
-- | named SHACL validation result over the selected scope's
-- | history lattice.
data LensState
  = LensIdle
  | LensLoading
  | LensQuery Api.ScopeHistoryQueryResponse
  | LensShacl Api.ScopeHistoryShaclResponse
  | LensFailed String

-- | A parsed lens selection: a backend-known query name or a
-- | backend-known SHACL shape name.
data LensKind
  = LensQueryKind String
  | LensShaclKind String

type Filters =
  { role :: String
  , asset :: String
  , direction :: String
  , since :: String
  , until :: String
  , limit :: String
  }

type State =
  { selectedScope :: Shell.Scope
  , filters :: Filters
  , history :: LoadState
  , selectedTx :: Maybe Api.ScopeHistoryEntry
  , detail :: DetailState
  , lensSel :: String
  , lens :: LensState
  , theme :: Theme.Theme
  }

data Action
  = Initialize
  | ToggleTheme
  | LoadHistory
  | SetScope String
  | SetRole String
  | SetAsset String
  | SetDirection String
  | SetSince String
  | SetUntil String
  | SetLimit String
  | ApplyFilters
  | ResetFilters
  | SelectTx Api.ScopeHistoryEntry
  | SetLens String
  | RunLens
  | CopyText String

initialFilters :: Filters
initialFilters =
  { role: ""
  , asset: ""
  , direction: ""
  , since: ""
  , until: ""
  , limit: "50"
  }

initialState :: State
initialState =
  { selectedScope: Shell.CoreDevelopment
  , filters: initialFilters
  , history: Loading
  , selectedTx: Nothing
  , detail: DetailIdle
  , lensSel: defaultLensSel
  , lens: LensIdle
  , theme: Theme.Dark
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
    HH.div_
      [ Shell.topbar RouteAudit
          { themeLabel: Shell.themeLabel st.theme
          , onToggleTheme: ToggleTheme
          }
      , HH.main
          [ HP.classes [ cn "audit-page" ] ]
          [ auditHeader
          , auditControls st
          , lensPanel st
          , auditBody st
          ]
      , Shell.siteFooter
          { buildIdentityLine: "tx audit view - indexer history API" }
      ]

  handleAction
    :: Action -> H.HalogenM State Action () output m Unit
  handleAction = case _ of
    Initialize -> do
      theme <- H.liftEffect Shell.initialTheme
      H.modify_ \s -> s { theme = theme }
      handleAction LoadHistory

    ToggleTheme -> do
      st <- H.get
      t' <- H.liftEffect (Shell.toggleThemeEff st.theme)
      H.modify_ \s -> s { theme = t' }

    LoadHistory -> do
      st <- H.get
      H.modify_ \s -> s
        { history = Loading
        , selectedTx = Nothing
        , detail = DetailIdle
        }
      res <- H.liftAff
        ( Api.fetchScopeHistory
            (Shell.scopeSlug st.selectedScope)
            (apiFilters st.filters)
        )
      case res of
        Right ok -> do
          H.modify_ \s -> s
            { history = Loaded ok
            , selectedTx = Array.head ok.entries
            , detail = DetailIdle
            }
          case Array.head ok.entries of
            Nothing -> pure unit
            Just tx -> loadTxDetail tx
        Left err ->
          H.modify_ \s -> s
            { history = Failed err
            , selectedTx = Nothing
            , detail = DetailIdle
            }

    SetScope slug -> do
      H.modify_ \s -> s
        { selectedScope = scopeFromSlug slug
        , selectedTx = Nothing
        , detail = DetailIdle
        , lens = LensIdle
        }
      handleAction LoadHistory

    SetRole value ->
      H.modify_ \s -> s { filters = s.filters { role = value } }

    SetAsset value ->
      H.modify_ \s -> s { filters = s.filters { asset = value } }

    SetDirection value ->
      H.modify_ \s -> s
        { filters = s.filters { direction = value } }

    SetSince value ->
      H.modify_ \s -> s { filters = s.filters { since = value } }

    SetUntil value ->
      H.modify_ \s -> s { filters = s.filters { until = value } }

    SetLimit value ->
      H.modify_ \s -> s { filters = s.filters { limit = value } }

    ApplyFilters ->
      handleAction LoadHistory

    ResetFilters -> do
      H.modify_ \s -> s
        { filters = initialFilters
        , selectedTx = Nothing
        , detail = DetailIdle
        }
      handleAction LoadHistory

    SelectTx tx -> do
      H.modify_ \s -> s { selectedTx = Just tx }
      loadTxDetail tx

    SetLens value ->
      H.modify_ \s -> s { lensSel = value }

    RunLens -> do
      st <- H.get
      H.modify_ \s -> s { lens = LensLoading }
      let scope = Shell.scopeSlug st.selectedScope
      case parseLensSel st.lensSel of
        LensQueryKind name -> do
          res <- H.liftAff (Api.fetchScopeHistoryQuery scope name)
          H.modify_ \s -> s
            { lens = case res of
                Right ok -> LensQuery ok
                Left err -> LensFailed err
            }
        LensShaclKind name -> do
          res <- H.liftAff (Api.fetchScopeHistoryShacl scope name)
          H.modify_ \s -> s
            { lens = case res of
                Right ok -> LensShacl ok
                Left err -> LensFailed err
            }

    CopyText value -> H.liftEffect (Clipboard.writeText value)

  loadTxDetail
    :: Api.ScopeHistoryEntry
    -> H.HalogenM State Action () output m Unit
  loadTxDetail tx = do
    H.modify_ \s -> s { detail = DetailLoading tx.txid }
    res <- H.liftAff (Api.fetchTxDetail tx.txid)
    current <- H.get
    case current.selectedTx of
      Just selected
        | selected.txid == tx.txid ->
            H.modify_ \s -> s
              { detail = case res of
                  Right detail -> DetailLoaded detail
                  Left err ->
                    if isNotFound404 err then
                      DetailNotFound tx.txid
                    else
                      DetailFailed err
              }
      _ -> pure unit

auditHeader :: forall w i. HH.HTML w i
auditHeader =
  HH.div
    [ HP.classes [ cn "audit-header" ] ]
    [ HH.h1
        [ HP.classes
            [ cn "md-typescale-headline-medium"
            , cn "audit-header__title"
            ]
        ]
        [ HH.text "Tx audit" ]
    , HH.p
        [ HP.classes
            [ cn "md-typescale-body-medium"
            , cn "audit-header__lede"
            ]
        ]
        [ HH.text
            "Indexer-backed treasury history by scope, role, \
            \asset, direction, and slot range."
        ]
    ]

auditControls
  :: forall w
   . State
  -> HH.HTML w Action
auditControls st =
  HH.div
    [ HP.classes [ cn "audit-controls" ] ]
    [ selectField
        { label: "scope"
        , value: Shell.scopeSlug st.selectedScope
        , onChange: SetScope
        , options:
            map
              ( \scope ->
                  { value: Shell.scopeSlug scope
                  , label: Shell.scopeLong scope
                  }
              )
              Shell.allScopes
        }
    , textField "role" st.filters.role SetRole
        "disburse"
    , textField "asset" st.filters.asset SetAsset
        "ada"
    , selectField
        { label: "direction"
        , value: st.filters.direction
        , onChange: SetDirection
        , options:
            [ { value: "", label: "Any" }
            , { value: "inbound", label: "Inbound" }
            , { value: "outbound", label: "Outbound" }
            ]
        }
    , textField "since slot" st.filters.since SetSince
        "0"
    , textField "until slot" st.filters.until SetUntil
        "200000000"
    , textField "limit" st.filters.limit SetLimit
        "50"
    , HH.div
        [ HP.classes [ cn "audit-controls__actions" ] ]
        [ HH.button
            [ HP.classes [ cn "audit-btn", cn "audit-btn--primary" ]
            , HP.type_ HP.ButtonButton
            , HE.onClick (\_ -> ApplyFilters)
            ]
            [ md "md-icon" [] [ HH.text "filter_alt" ]
            , HH.span_ [ HH.text "Apply" ]
            ]
        , HH.button
            [ HP.classes [ cn "audit-btn" ]
            , HP.type_ HP.ButtonButton
            , HE.onClick (\_ -> ResetFilters)
            ]
            [ md "md-icon" [] [ HH.text "restart_alt" ]
            , HH.span_ [ HH.text "Reset" ]
            ]
        ]
    ]

auditBody :: forall w. State -> HH.HTML w Action
auditBody st =
  HH.div
    [ HP.classes [ cn "audit-layout" ] ]
    [ HH.section
        [ HP.classes [ cn "audit-panel" ] ]
        [ case st.history of
            Loading -> stateMessage
              "Loading indexed history"
              "Waiting for the history API response."
            Failed err ->
              if isLagging503 err then
                stateMessage
                  "Indexer lagging"
                  "The API returned 503 while the indexer catches up."
              else
                stateMessage "History request failed" err
            Loaded response ->
              if Array.null response.entries then
                stateMessage
                  "No transactions"
                  "The selected scope and filters returned no history rows."
              else
                historyTable response.entries st.selectedTx
        ]
    , detailPanel st.selectedTx st.detail
    ]

historyTable
  :: forall w
   . Array Api.ScopeHistoryEntry
  -> Maybe Api.ScopeHistoryEntry
  -> HH.HTML w Action
historyTable entries selectedTx =
  HH.div
    [ HP.classes [ cn "audit-table-wrap" ] ]
    [ HH.div
        [ HP.classes [ cn "audit-table-meta" ] ]
        [ HH.span_ [ HH.text (show (Array.length entries) <> " rows") ] ]
    , HH.table
        [ HP.classes [ cn "audit-table" ] ]
        [ HH.thead_
            [ HH.tr_
                [ HH.th_ [ HH.text "slot" ]
                , HH.th_ [ HH.text "txid" ]
                , HH.th_ [ HH.text "role" ]
                , HH.th_ [ HH.text "direction" ]
                ]
            ]
        , HH.tbody_
            (map (historyRow selectedTx) entries)
        ]
    ]

historyRow
  :: forall w
   . Maybe Api.ScopeHistoryEntry
  -> Api.ScopeHistoryEntry
  -> HH.HTML w Action
historyRow selectedTx entry =
  let
    selected = case selectedTx of
      Just current -> current.txid == entry.txid
      Nothing -> false
  in
    HH.tr
      ( if selected then
          [ HP.attr (HH.AttrName "data-selected") "true" ]
        else []
      )
      [ HH.td
          [ HP.classes [ cn "mono" ] ]
          [ HH.text (formatThousands entry.slot) ]
      , HH.td_
          [ HH.button
              [ HP.classes [ cn "audit-link-btn", cn "mono" ]
              , HP.type_ HP.ButtonButton
              , HP.title entry.txid
              , HE.onClick (\_ -> SelectTx entry)
              ]
              [ HH.text (shortHex entry.txid) ]
          ]
      , HH.td_ [ badge entry.role ]
      , HH.td_ [ badge entry.direction ]
      ]

detailPanel
  :: forall w
   . Maybe Api.ScopeHistoryEntry
  -> DetailState
  -> HH.HTML w Action
detailPanel selectedTx detail =
  HH.aside
    [ HP.classes [ cn "audit-detail" ] ]
    [ HH.h2
        [ HP.classes [ cn "md-typescale-title-medium" ] ]
        [ HH.text "Transaction detail" ]
    , case selectedTx of
        Nothing ->
          stateMessage
            "No row selected"
            "A transaction summary will appear here."
        Just tx ->
          detailContent tx detail
    ]

detailContent
  :: forall w
   . Api.ScopeHistoryEntry
  -> DetailState
  -> HH.HTML w Action
detailContent tx (DetailLoaded response) =
  txDetail response
detailContent tx detail =
  HH.div_
    [ kv "slot" (formatThousands tx.slot)
    , kvCopy "txid" shortHex tx.txid
    , kv "role" tx.role
    , kv "direction" tx.direction
    , case detail of
        DetailIdle ->
          stateMessage
            "Detail not loaded"
            "Select the transaction again to load its full record."
        DetailLoading txid ->
          stateMessage
            "Loading transaction detail"
            ("Fetching /v1/tx/" <> txid)
        DetailNotFound _ ->
          stateMessage
            "Transaction not found"
            "The detail API returned 404 for this txid."
        DetailFailed err ->
          stateMessage "Detail request failed" err
        DetailLoaded _ ->
          stateMessage
            "Detail loaded"
            "The selected transaction detail is ready."
    ]

txDetail :: forall w. Api.TxDetailResponse -> HH.HTML w Action
txDetail detail =
  HH.div
    [ HP.classes [ cn "audit-detail__body" ] ]
    [ kv "slot" (formatThousands detail.slot)
    , kvCopy "txid" shortHex detail.txid
    , kv "scope" detail.scope
    , kv "role" detail.role
    , kv "direction" detail.direction
    , case detail.blockHash of
        Just h -> kvCopy "block hash" shortHex h
        Nothing -> kv "block hash" "-"
    , kv "fee" (maybeText (\f -> formatThousands f <> " lovelace") detail.fee)
    , case detail.redeemer of
        Just r -> kvCopy "redeemer" shortHex r
        Nothing -> kv "redeemer" "-"
    , cardSection "Projected redeemers"
        detail.projectedRedeemers
        redeemerCard
    , sectionList "Required signers" detail.requiredSigners identity
    , cardSection "Inputs" detail.inputs inputCard
    , cardSection "Outputs" detail.outputs outputCard
    ]

-- | A detail section whose rows are rich HTML cards
-- | (`.repeated-row-card`) rather than plain mono text. Used for
-- | inputs / outputs / projected redeemers, where each row
-- | carries resolved labels, copy buttons and projected fields.
cardSection
  :: forall a w
   . String
  -> Array a
  -> (a -> HH.HTML w Action)
  -> HH.HTML w Action
cardSection title rows renderRow =
  HH.section
    [ HP.classes [ cn "audit-detail__section" ] ]
    [ HH.h3_ [ HH.text title ]
    , if Array.null rows then
        HH.p
          [ HP.classes [ cn "audit-detail__empty" ] ]
          [ HH.text "None" ]
      else
        HH.div
          [ HP.classes [ cn "repeated-row-list" ] ]
          (map renderRow rows)
    ]

sectionList
  :: forall a w i
   . String
  -> Array a
  -> (a -> String)
  -> HH.HTML w i
sectionList title rows renderRow =
  HH.section
    [ HP.classes [ cn "audit-detail__section" ] ]
    [ HH.h3_ [ HH.text title ]
    , if Array.null rows then
        HH.p
          [ HP.classes [ cn "audit-detail__empty" ] ]
          [ HH.text "None" ]
      else
        HH.ul_
          ( map
              ( \row ->
                  HH.li
                    [ HP.classes [ cn "mono" ] ]
                    [ HH.text (renderRow row) ]
              )
              rows
          )
    ]

-- | One transaction input rendered as a card: the outref (copy),
-- | its resolved scope (or @unresolved@ — input source-address
-- | resolution is a deferred backend follow-up) and value.
inputCard :: forall w. Api.TxDetailInput -> HH.HTML w Action
inputCard input =
  HH.div
    [ HP.classes [ cn "repeated-row-card" ] ]
    [ kvCopy "tx in" shortHex input.txIn
    , kv "scope" (fromMaybe "unresolved" input.scope)
    , kv "value" input.value
    ]

-- | One transaction output rendered as a card: address (copy),
-- | the resolved treasury scope/role labels (never a raw
-- | @null@), the ADA-denominated value plus any native assets,
-- | and either the projected SundaeSwap order fields or a
-- | truncated raw datum.
outputCard :: forall w. Api.TxDetailOutput -> HH.HTML w Action
outputCard output =
  let
    chips = assetChips output.value.assets <> datumChips output
  in
    HH.div
      [ HP.classes [ cn "repeated-row-card", cn "audit-output-card" ] ]
      ( [ HH.div
            [ HP.classes [ cn "repeated-row-card__head" ] ]
            [ HH.span
                [ HP.classes [ cn "repeated-row-card__title" ] ]
                [ HH.text ("output #" <> show output.index) ]
            , HH.span
                [ HP.classes [ cn "audit-output-card__badges" ] ]
                ( [ badge (fromMaybe "external" output.scope) ]
                    <> roleBadges output.role
                )
            ]
        , HH.div
            [ HP.classes [ cn "audit-output-card__summary" ] ]
            [ compactField "address"
                [ copyInline "address" shortAddr output.address ]
            , compactField "value"
                [ HH.code [ HP.classes [ cn "mono" ] ]
                    [ HH.text (showAda output.value.lovelace) ]
                ]
            ]
        ]
          <> chipRow chips
      )

chipRow
  :: forall w
   . Array (HH.HTML w Action)
  -> Array (HH.HTML w Action)
chipRow chips
  | Array.null chips = []
  | otherwise =
      [ HH.div
          [ HP.classes [ cn "audit-output-card__chips" ] ]
          chips
      ]

roleBadges :: forall w i. Maybe String -> Array (HH.HTML w i)
roleBadges = case _ of
  Just role -> [ badge role ]
  Nothing -> []

compactField
  :: forall w
   . String
  -> Array (HH.HTML w Action)
  -> HH.HTML w Action
compactField label_ body =
  HH.div
    [ HP.classes [ cn "audit-output-field" ] ]
    [ HH.span
        [ HP.classes [ cn "audit-output-field__label" ] ]
        [ HH.text label_ ]
    , HH.span
        [ HP.classes [ cn "audit-output-field__value" ] ]
        body
    ]

copyInline
  :: forall w
   . String
  -> (String -> String)
  -> String
  -> HH.HTML w Action
copyInline label_ trunc full =
  HH.span
    [ HP.classes [ cn "audit-copy" ] ]
    [ HH.code
        [ HP.classes [ cn "mono" ], HP.title full ]
        [ HH.text (trunc full) ]
    , HH.button
        [ HP.classes [ cn "copy-icon-btn" ]
        , HP.type_ HP.ButtonButton
        , HP.title ("Copy " <> label_)
        , HP.attr (HH.AttrName "aria-label") ("Copy " <> label_)
        , HE.onClick (\_ -> CopyText full)
        ]
        [ md "md-icon" [] [ HH.text "content_copy" ] ]
    ]

assetChips
  :: forall w
   . FO.Object (FO.Object Number)
  -> Array (HH.HTML w Action)
assetChips assets = do
  Tuple policy inner <- FO.toUnfoldable assets
  Tuple name quantity <- FO.toUnfoldable inner
  pure
    ( outputChip "asset"
        [ HH.code
            [ HP.classes [ cn "mono" ], HP.title policy ]
            [ HH.text (shortHex policy) ]
        , HH.span_ [ HH.text "·" ]
        , HH.code
            [ HP.classes [ cn "mono" ], HP.title name ]
            [ HH.text (assetNameText name) ]
        , HH.span_ [ HH.text ("× " <> formatThousandsN quantity) ]
        ]
    )

-- | The projected SundaeSwap order datum (recipient, min
-- | received, scooper fee) when the output carries one, else the
-- | truncated raw datum, else nothing.
datumChips :: forall w. Api.TxDetailOutput -> Array (HH.HTML w Action)
datumChips output = case output.projectedDatum of
  Just order ->
    [ outputChip "datum" [ HH.text "swap order" ]
    , outputChip "recipient"
        [ copyInline "recipient" shortHex order.recipient ]
    , outputChip "min received"
        [ projectedAssetInline order.minReceived ]
    , outputChip "scooper fee"
        [ HH.text (showAda order.scooperFee) ]
    ]
  Nothing -> case output.datum of
    Just d ->
      [ outputChip "datum" [ copyInline "datum" shortHex d ] ]
    Nothing -> []

outputChip
  :: forall w
   . String
  -> Array (HH.HTML w Action)
  -> HH.HTML w Action
outputChip label_ body =
  HH.span
    [ HP.classes [ cn "audit-output-chip" ] ]
    ( [ HH.span
          [ HP.classes [ cn "audit-output-chip__label" ] ]
          [ HH.text label_ ]
      ]
        <> body
    )

projectedAssetInline :: forall w i. Api.ProjectedAsset -> HH.HTML w i
projectedAssetInline a
  | a.policy == "" && a.asset == "" =
      HH.text (showAda a.quantity)
  | otherwise =
      HH.span_
        [ HH.code
            [ HP.classes [ cn "mono" ], HP.title a.policy ]
            [ HH.text (shortHex a.policy) ]
        , HH.span_ [ HH.text " · " ]
        , HH.code
            [ HP.classes [ cn "mono" ], HP.title a.asset ]
            [ HH.text (assetNameText a.asset) ]
        , HH.span_ [ HH.text (" × " <> formatThousandsN a.quantity) ]
        ]

-- | One projected treasury-spend redeemer rendered as a card:
-- | the variant badge plus an @amount@ row per projected asset.
redeemerCard
  :: forall w i. Api.ProjectedTreasurySpend -> HH.HTML w i
redeemerCard spend =
  HH.div
    [ HP.classes [ cn "repeated-row-card" ] ]
    ( [ HH.div
          [ HP.classes [ cn "repeated-row-card__head" ] ]
          [ HH.span
              [ HP.classes [ cn "repeated-row-card__title" ] ]
              [ HH.text "treasury spend" ]
          , badge spend.variant
          ]
      ]
        <>
          ( if Array.null spend.amount then
              [ HH.p
                  [ HP.classes [ cn "audit-detail__empty" ] ]
                  [ HH.text "no amount" ]
              ]
            else
              map
                (\a -> kv "amount" (projectedAssetText a))
                spend.amount
          )
    )

-- | Render a projected asset. Empty policy + asset names denote
-- | ADA (lovelace); otherwise show the truncated policy/asset and
-- | the grouped quantity.
projectedAssetText :: Api.ProjectedAsset -> String
projectedAssetText a
  | a.policy == "" && a.asset == "" = showAda a.quantity
  | otherwise =
      shortHex a.policy
        <> " · "
        <> assetNameText a.asset
        <> " × "
        <> formatThousandsN a.quantity

-- | #340 — the RDF lens: pick a backend-known SPARQL query or
-- | SHACL shape and render its result over the selected scope's
-- | history lattice. A thin renderer — the UI never sends SPARQL
-- | or SHACL, only a fixed name the server recognises.
lensPanel :: forall w. State -> HH.HTML w Action
lensPanel st =
  HH.section
    [ HP.classes [ cn "audit-detail", cn "audit-lens" ] ]
    [ HH.h2
        [ HP.classes [ cn "md-typescale-title-medium" ] ]
        [ HH.text "RDF lens" ]
    , HH.p
        [ HP.classes [ cn "audit-detail__empty" ] ]
        [ HH.text
            ( "Named SPARQL queries and SHACL shapes over the "
                <> Shell.scopeLong st.selectedScope
                <> " history lattice."
            )
        ]
    , HH.div
        [ HP.classes [ cn "audit-controls" ] ]
        [ selectField
            { label: "lens"
            , value: st.lensSel
            , onChange: SetLens
            , options: lensOptions
            }
        , HH.div
            [ HP.classes [ cn "audit-controls__actions" ] ]
            [ HH.button
                [ HP.classes
                    [ cn "audit-btn", cn "audit-btn--primary" ]
                , HP.type_ HP.ButtonButton
                , HE.onClick (\_ -> RunLens)
                ]
                [ md "md-icon" [] [ HH.text "play_arrow" ]
                , HH.span_ [ HH.text "Run" ]
                ]
            ]
        ]
    , lensResults st.lens
    ]

lensResults :: forall w. LensState -> HH.HTML w Action
lensResults = case _ of
  LensIdle ->
    stateMessage
      "No lens run"
      "Pick a query or shape and press Run."
  LensLoading ->
    stateMessage
      "Running lens"
      "Waiting for the RDF engine response."
  LensFailed err ->
    if isLagging503 err then
      stateMessage
        "Indexer lagging"
        "The API returned 503 while the indexer catches up."
    else
      stateMessage "Lens request failed" err
  LensQuery resp -> lensQueryTable resp
  LensShacl resp -> lensShaclReport resp

lensQueryTable
  :: forall w i. Api.ScopeHistoryQueryResponse -> HH.HTML w i
lensQueryTable resp =
  HH.section
    [ HP.classes [ cn "audit-detail__section" ] ]
    [ HH.h3_
        [ HH.text
            ( resp.query
                <> " — "
                <> show (Array.length resp.rows)
                <> " rows"
            )
        ]
    , if Array.null resp.rows then
        HH.p
          [ HP.classes [ cn "audit-detail__empty" ] ]
          [ HH.text "No rows." ]
      else
        HH.div
          [ HP.classes [ cn "audit-table-wrap" ] ]
          [ HH.table
              [ HP.classes [ cn "audit-table" ] ]
              [ HH.thead_
                  [ HH.tr_
                      ( map
                          (\c -> HH.th_ [ HH.text c ])
                          resp.columns
                      )
                  ]
              , HH.tbody_ (map lensRow resp.rows)
              ]
          ]
    ]

lensRow :: forall w i. Array String -> HH.HTML w i
lensRow cells =
  HH.tr_
    ( map
        ( \c ->
            HH.td [ HP.classes [ cn "mono" ] ] [ HH.text c ]
        )
        cells
    )

lensShaclReport
  :: forall w i. Api.ScopeHistoryShaclResponse -> HH.HTML w i
lensShaclReport resp =
  HH.section
    [ HP.classes [ cn "audit-detail__section" ] ]
    [ HH.h3_ [ HH.text resp.shape ]
    , kv "conforms" (if resp.conforms then "yes" else "no")
    , if resp.conforms then
        HH.p
          [ HP.classes [ cn "audit-detail__empty" ] ]
          [ HH.text "No violations." ]
      else
        HH.ul_
          ( map
              ( \ln ->
                  HH.li
                    [ HP.classes [ cn "mono" ] ]
                    [ HH.text ln ]
              )
              (reportLines resp.report)
          )
    ]

reportLines :: String -> Array String
reportLines = String.split (String.Pattern "\n")

-- | The backend-known SPARQL query names (the server rejects
-- | any other value).
lensQueryNames :: Array String
lensQueryNames =
  [ "history-entries"
  , "tx-count"
  , "asset-flow"
  , "spend-edges"
  , "entity-occurrences"
  , "address-resolution"
  ]

-- | The backend-known SHACL shape names.
lensShapeNames :: Array String
lensShapeNames = [ "history-entry", "indexed-tx-body" ]

-- | Dropdown options: every query name then every shape name,
-- | each tagged so 'parseLensSel' can route the request.
lensOptions :: Array { value :: String, label :: String }
lensOptions =
  map
    (\n -> { value: "query:" <> n, label: "query · " <> n })
    lensQueryNames
    <> map
      (\n -> { value: "shacl:" <> n, label: "shacl · " <> n })
      lensShapeNames

defaultLensSel :: String
defaultLensSel = "query:history-entries"

-- | Route a tagged dropdown value to a query or a shape request.
parseLensSel :: String -> LensKind
parseLensSel s =
  case String.stripPrefix (String.Pattern "shacl:") s of
    Just name -> LensShaclKind name
    Nothing ->
      LensQueryKind
        ( fromMaybe s
            (String.stripPrefix (String.Pattern "query:") s)
        )

stateMessage :: forall w i. String -> String -> HH.HTML w i
stateMessage title body =
  HH.div
    [ HP.classes [ cn "audit-state" ] ]
    [ HH.div
        [ HP.classes [ cn "audit-state__title" ] ]
        [ HH.text title ]
    , HH.p_ [ HH.text body ]
    ]

kv :: forall w i. String -> String -> HH.HTML w i
kv label_ value_ =
  HH.div
    [ HP.classes [ cn "audit-detail__kv" ] ]
    [ HH.span_ [ HH.text label_ ]
    , HH.code_ [ HH.text value_ ]
    ]

-- | #338 SB1 — like 'kv' but the value is a long hash/address:
-- | shown truncated (the full value on a `title` tooltip) next
-- | to a copy button that writes the full value to the
-- | clipboard.  Mirrors the dashboard copy-row affordance.
kvCopy
  :: forall w
   . String
  -> (String -> String)
  -> String
  -> HH.HTML w Action
kvCopy label_ trunc full =
  HH.div
    [ HP.classes [ cn "audit-detail__kv" ] ]
    [ HH.span_ [ HH.text label_ ]
    , HH.span
        [ HP.classes [ cn "audit-copy" ] ]
        [ HH.code
            [ HP.classes [ cn "mono" ], HP.title full ]
            [ HH.text (trunc full) ]
        , HH.button
            [ HP.classes [ cn "copy-icon-btn" ]
            , HP.type_ HP.ButtonButton
            , HP.title ("Copy " <> label_)
            , HP.attr (HH.AttrName "aria-label") ("Copy " <> label_)
            , HE.onClick (\_ -> CopyText full)
            ]
            [ md "md-icon" [] [ HH.text "content_copy" ] ]
        ]
    ]

badge :: forall w i. String -> HH.HTML w i
badge value =
  HH.span
    [ HP.classes [ cn "audit-badge" ] ]
    [ HH.text (if value == "-" then "funding" else value) ]

textField
  :: forall w
   . String
  -> String
  -> (String -> Action)
  -> String
  -> HH.HTML w Action
textField label_ value_ action placeholder_ =
  HH.label
    [ HP.classes [ cn "audit-field" ] ]
    [ HH.span_ [ HH.text label_ ]
    , HH.input
        [ HP.classes [ cn "audit-field__input" ]
        , HP.type_ HP.InputText
        , HP.value value_
        , HP.placeholder placeholder_
        , HE.onValueInput action
        ]
    ]

selectField
  :: forall w
   . { label :: String
     , value :: String
     , onChange :: String -> Action
     , options :: Array { value :: String, label :: String }
     }
  -> HH.HTML w Action
selectField cfg =
  HH.label
    [ HP.classes [ cn "audit-field" ] ]
    [ HH.span_ [ HH.text cfg.label ]
    , HH.select
        [ HP.classes [ cn "audit-field__input" ]
        , HE.onValueChange cfg.onChange
        ]
        (map option cfg.options)
    ]
  where
  option opt =
    HH.option
      [ HP.value opt.value
      , HP.selected (opt.value == cfg.value)
      ]
      [ HH.text opt.label ]

apiFilters :: Filters -> Api.ScopeHistoryFilters
apiFilters f =
  { role: blankToMaybe f.role
  , asset: blankToMaybe f.asset
  , direction: blankToMaybe f.direction
  , since: blankToMaybe f.since
  , until: blankToMaybe f.until
  , limit: blankToMaybe f.limit
  }

blankToMaybe :: String -> Maybe String
blankToMaybe "" = Nothing
blankToMaybe s = Just s

maybeText :: forall a. (a -> String) -> Maybe a -> String
maybeText _ Nothing = "-"
maybeText f (Just a) = f a

scopeFromSlug :: String -> Shell.Scope
scopeFromSlug slug =
  fromMaybe Shell.CoreDevelopment
    ( Array.find
        (\scope -> Shell.scopeSlug scope == slug)
        Shell.allScopes
    )

isLagging503 :: String -> Boolean
isLagging503 err =
  String.contains (String.Pattern "503") err
    || String.contains (String.Pattern "ServiceUnavailable") err
    || String.contains (String.Pattern "Service Unavailable") err

isNotFound404 :: String -> Boolean
isNotFound404 err =
  String.contains (String.Pattern "404") err
    || String.contains (String.Pattern "NotFound") err
    || String.contains (String.Pattern "Not Found") err

md
  :: forall r w i
   . String
  -> Array (HH.IProp r i)
  -> Array (HH.HTML w i)
  -> HH.HTML w i
md tag = HH.element (HH.ElemName tag)

cn :: String -> HH.ClassName
cn = HH.ClassName
