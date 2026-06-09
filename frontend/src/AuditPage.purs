-- | #310 — tx audit history view backed by the indexer API.

module AuditPage where

import Prelude

import Api as Api
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
import Data.String as String
import Effect.Aff.Class (class MonadAff)
import Format (formatThousands, shortAddr, shortHex)
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
    , kv "redeemer" (fromMaybe "-" detail.redeemer)
    , sectionList "Required signers" detail.requiredSigners identity
    , sectionList "Inputs" detail.inputs inputRow
    , sectionList "Outputs" detail.outputs outputRow
    , sectionList "Lines" detail.lines identity
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

inputRow :: Api.TxDetailInput -> String
inputRow input =
  shortHex input.txIn
    <> " | "
    <> fromMaybe "-" input.scope
    <> " | "
    <> input.value

outputRow :: Api.TxDetailOutput -> String
outputRow output =
  "#"
    <> show output.index
    <> " | "
    <> shortAddr output.address
    <> " | "
    <> output.value
    <> " | datum "
    <> fromMaybe "-" output.datum

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
