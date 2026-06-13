-- | /pending route: browser-local unsigned tx listing.
-- |
-- | This page is intentionally a thin renderer over
-- | Store.PendingTx. It never decodes CBOR, verifies
-- | witnesses, hashes tx bodies, or derives signer sets.
module PendingPage (component) where

import Prelude

import Api as Api
import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as Argonaut
import Data.Argonaut.Decode (decodeJson)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Nullable as Nullable
import Data.String as String
import Data.Tuple (Tuple(..))
import Effect.Aff as Aff
import Effect.Aff.Class (class MonadAff)
import Effect.Exception as Error
import Foreign.Object as FO
import Format (showAda)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Routing (Route(..))
import Shell as Shell
import Store.PendingTx as PendingTx
import Theme as Theme

type State =
  { entries :: Array PendingTx.PendingTxEntry
  , selectedTxid :: Maybe String
  , loadError :: Maybe String
  , tipSlot :: Maybe Int
  , theme :: Theme.Theme
  }

type Lanes =
  { active :: Array PendingTx.PendingTxEntry
  , expired :: Array PendingTx.PendingTxEntry
  , history :: Array PendingTx.PendingTxEntry
  }

data Action
  = Initialize
  | ToggleTheme
  | SelectEntry String

initialState :: State
initialState =
  { entries: []
  , selectedTxid: Nothing
  , loadError: Nothing
  , tipSlot: Nothing
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

handleAction
  :: forall output m
   . MonadAff m
  => Action
  -> H.HalogenM State Action () output m Unit
handleAction = case _ of
  Initialize -> do
    theme <- H.liftEffect Shell.initialTheme
    loaded <- H.liftAff (Aff.try PendingTx.list)
    tip <- H.liftAff Api.fetchTip
    let
      entries = case loaded of
        Right xs -> xs
        Left _ -> []
      loadError = case loaded of
        Right _ -> Nothing
        Left err -> Just (Error.message err)
      selectedTxid = _.txid <$> Array.head entries
      tipSlot = case tip of
        Right t -> Just t.slot
        Left _ -> Nothing
    H.put
      { entries
      , selectedTxid
      , loadError
      , tipSlot
      , theme
      }
  ToggleTheme -> do
    st <- H.get
    next <- H.liftEffect (Shell.toggleThemeEff st.theme)
    H.modify_ (_ { theme = next })
  SelectEntry txid ->
    H.modify_ (_ { selectedTxid = Just txid })

render
  :: forall m
   . State
  -> H.ComponentHTML Action () m
render st =
  let
    lanes = lanesFor st
  in
    HH.div_
      [ Shell.topbar RoutePending
          { themeLabel: Shell.themeLabel st.theme
          , onToggleTheme: ToggleTheme
          }
      , headerView st lanes
      , case st.loadError of
          Nothing -> HH.text ""
          Just msg ->
            HH.div
              [ HP.classes [ cn "pending-banner" ] ]
              [ HH.text ("Pending store unavailable: " <> msg) ]
      , HH.div
          [ HP.classes [ cn "pending-layout" ] ]
          [ HH.div
              [ HP.classes [ cn "pending-lanes" ] ]
              [ laneView st "Active" "Active pending transactions"
                  lanes.active
              , laneView st "Expired" "Expired pending transactions"
                  lanes.expired
              , laneView st "History" "Pending transaction history"
                  lanes.history
              ]
          , detailView st
          ]
      , Shell.siteFooter
          { buildIdentityLine:
              "Pending entries are stored in this browser."
          }
      ]

headerView :: forall w. State -> Lanes -> HH.HTML w Action
headerView st lanes =
  HH.header
    [ HP.classes [ cn "site-header", cn "pending-header" ] ]
    [ HH.div
        [ HP.classes [ cn "site-header__eyebrow" ] ]
        [ HH.text "Local co-signing queue" ]
    , HH.h1
        [ HP.classes [ cn "site-header__title" ] ]
        [ HH.text "Pending" ]
    , HH.p
        [ HP.classes [ cn "site-header__lede" ] ]
        [ HH.text
            "Unsigned treasury transactions saved in this browser, \
            \grouped by current signing state."
        ]
    , HH.div
        [ HP.classes [ cn "pending-summary" ] ]
        [ summaryChip "Active" (Array.length lanes.active)
        , summaryChip "Expired" (Array.length lanes.expired)
        , summaryChip "History" (Array.length lanes.history)
        , HH.span
            [ HP.classes [ cn "pending-summary__slot" ] ]
            [ HH.text ("slot " <> slotText st.tipSlot) ]
        ]
    ]

summaryChip :: forall w i. String -> Int -> HH.HTML w i
summaryChip label count =
  HH.span
    [ HP.classes [ cn "pending-summary__chip" ] ]
    [ HH.span_ [ HH.text label ]
    , HH.code_ [ HH.text (show count) ]
    ]

laneView
  :: forall w
   . State
  -> String
  -> String
  -> Array PendingTx.PendingTxEntry
  -> HH.HTML w Action
laneView st title label entries =
  HH.section
    [ HP.classes [ cn "pending-lane" ]
    , HP.attr (HH.AttrName "role") "region"
    , HP.attr (HH.AttrName "aria-label") label
    ]
    [ HH.div
        [ HP.classes [ cn "pending-lane__head" ] ]
        [ HH.h2_ [ HH.text title ]
        , HH.code_ [ HH.text (show (Array.length entries)) ]
        ]
    , if Array.null entries then
        HH.p
          [ HP.classes [ cn "pending-empty" ] ]
          [ HH.text "No entries." ]
      else
        HH.div
          [ HP.classes [ cn "pending-entry-list" ] ]
          (map (entryCard st) entries)
    ]

entryCard
  :: forall w
   . State
  -> PendingTx.PendingTxEntry
  -> HH.HTML w Action
entryCard st entry =
  let
    selected = st.selectedTxid == Just entry.txid
  in
    HH.article
      [ HP.classes [ cn "pending-entry-card" ]
      , HP.attr (HH.AttrName "data-selected") (boolAttr selected)
      ]
      [ HH.button
          [ HP.classes [ cn "pending-entry-card__button" ]
          , HP.type_ HP.ButtonButton
          , HP.attr (HH.AttrName "aria-label")
              ("View pending transaction " <> entry.txid)
          , HE.onClick (\_ -> SelectEntry entry.txid)
          ]
          [ HH.span
              [ HP.classes [ cn "pending-entry-card__title" ] ]
              [ HH.text entry.txid ]
          , HH.span
              [ HP.classes [ cn "pending-entry-card__meta" ] ]
              [ HH.text
                  ( entry.scope <> " · saved "
                      <> entry.savedAt
                      <> " · expires "
                      <> fromMaybe "unknown"
                        (Nullable.toMaybe entry.invalidHereafter)
                  )
              ]
          ]
      , signerChips entry
      , case Nullable.toMaybe entry.supersedes of
          Nothing -> HH.text ""
          Just previous ->
            HH.p
              [ HP.classes [ cn "pending-entry-card__history" ] ]
              [ HH.text ("supersedes " <> previous) ]
      ]

signerChips
  :: forall w i
   . PendingTx.PendingTxEntry
  -> HH.HTML w i
signerChips entry =
  HH.div
    [ HP.classes [ cn "signers-picker" ] ]
    (map (signerChip entry) entry.requiredSigners)

signerChip
  :: forall w i
   . PendingTx.PendingTxEntry
  -> String
  -> HH.HTML w i
signerChip entry signer =
  let
    collected = signerCollected entry signer
  in
    HH.span
      [ HP.classes [ cn "signer-chip", cn "signer-chip--required" ]
      , HP.attr (HH.AttrName "data-active") (boolAttr collected)
      ]
      [ HH.span_ [ HH.text signer ]
      , HH.span
          [ HP.classes [ cn "signer-chip__req" ] ]
          [ HH.text (if collected then "Collected" else "Missing") ]
      ]

detailView :: forall w. State -> HH.HTML w Action
detailView st =
  HH.aside
    [ HP.classes [ cn "pending-detail" ]
    , HP.attr (HH.AttrName "role") "region"
    , HP.attr (HH.AttrName "aria-label") "Pending transaction detail"
    ]
    case selectedEntry st of
      Nothing ->
        [ HH.h2_ [ HH.text "Details" ]
        , HH.p
            [ HP.classes [ cn "pending-empty" ] ]
            [ HH.text "Select an entry to inspect its signer roster." ]
        ]
      Just entry ->
        [ HH.div
            [ HP.classes [ cn "pending-detail__head" ] ]
            [ HH.h2_ [ HH.text entry.txid ]
            , HH.code_ [ HH.text entry.scope ]
            ]
        , witnessRoster entry
        , graphProjection entry
        ]

witnessRoster
  :: forall w i
   . PendingTx.PendingTxEntry
  -> HH.HTML w i
witnessRoster entry =
  HH.section
    [ HP.classes [ cn "pending-detail__section" ] ]
    [ HH.h3_ [ HH.text "Witness roster" ]
    , HH.div
        [ HP.classes [ cn "pending-roster" ] ]
        (map (rosterRow entry) entry.requiredSigners)
    ]

rosterRow
  :: forall w i
   . PendingTx.PendingTxEntry
  -> String
  -> HH.HTML w i
rosterRow entry signer =
  let
    collected = signerCollected entry signer
  in
    HH.div
      [ HP.classes [ cn "pending-roster__row" ]
      , HP.attr (HH.AttrName "data-active") (boolAttr collected)
      ]
      [ HH.code_ [ HH.text signer ]
      , HH.span_
          [ HH.text (if collected then "Collected" else "Missing") ]
      ]

graphProjection
  :: forall w i
   . PendingTx.PendingTxEntry
  -> HH.HTML w i
graphProjection entry = case graphEffectFromIntent entry.intent of
  Nothing ->
    HH.section
      [ HP.classes [ cn "pending-detail__section" ] ]
      [ HH.h3_ [ HH.text "Inputs and outputs" ]
      , HH.p
          [ HP.classes [ cn "pending-empty" ] ]
          [ HH.text "No graph-effect metadata is stored for this entry." ]
      ]
  Just effect ->
    HH.div
      [ HP.classes [ cn "pending-graph" ] ]
      [ graphSection "Inputs" effect.spends inputRow
      , graphSection "Outputs" effect.produces outputRow
      ]

graphSection
  :: forall a w i
   . String
  -> Array a
  -> (a -> HH.HTML w i)
  -> HH.HTML w i
graphSection title rows renderRow =
  HH.section
    [ HP.classes [ cn "pending-detail__section" ] ]
    [ HH.h3_ [ HH.text title ]
    , if Array.null rows then
        HH.p
          [ HP.classes [ cn "pending-empty" ] ]
          [ HH.text "None" ]
      else
        HH.div
          [ HP.classes [ cn "pending-graph__rows" ] ]
          (map renderRow rows)
    ]

inputRow :: forall w i. Api.TxDetailInput -> HH.HTML w i
inputRow input =
  HH.div
    [ HP.classes [ cn "pending-graph-card" ] ]
    [ kv "input" input.txIn
    , kv "scope"
        ( if input.resolved then fromMaybe "external" input.scope
          else "unresolved"
        )
    , kv "role" (fromMaybe "-" input.role)
    , kv "value" (maybeValueText input.value)
    ]

outputRow :: forall w i. Api.TxDetailOutput -> HH.HTML w i
outputRow output =
  HH.div
    [ HP.classes [ cn "pending-graph-card" ] ]
    [ kv "output" ("#" <> show output.index)
    , kv "address" output.address
    , kv "scope" (fromMaybe "external" output.scope)
    , kv "role" (fromMaybe "-" output.role)
    , kv "value" (valueText output.value)
    ]

kv :: forall w i. String -> String -> HH.HTML w i
kv label value =
  HH.div
    [ HP.classes [ cn "pending-kv" ] ]
    [ HH.span_ [ HH.text label ]
    , HH.code_ [ HH.text value ]
    ]

lanesFor :: State -> Lanes
lanesFor st =
  let
    isHistory = entryInHistory st.entries
    isExpired = entryExpired st.tipSlot
  in
    { active:
        Array.filter
          (\entry -> not (isHistory entry) && not (isExpired entry))
          st.entries
    , expired:
        Array.filter
          (\entry -> not (isHistory entry) && isExpired entry)
          st.entries
    , history: Array.filter isHistory st.entries
    }

entryInHistory
  :: Array PendingTx.PendingTxEntry
  -> PendingTx.PendingTxEntry
  -> Boolean
entryInHistory entries entry = case Nullable.toMaybe entry.supersedes of
  Just _ -> true
  Nothing ->
    Array.any
      (\candidate -> Nullable.toMaybe candidate.supersedes == Just entry.txid)
      entries

entryExpired
  :: Maybe Int
  -> PendingTx.PendingTxEntry
  -> Boolean
entryExpired (Just currentSlot) entry =
  case Nullable.toMaybe entry.invalidHereafter >>= Int.fromString of
    Just invalidHereafter -> invalidHereafter <= currentSlot
    Nothing -> false
entryExpired Nothing _ = false

selectedEntry :: State -> Maybe PendingTx.PendingTxEntry
selectedEntry st = do
  txid <- st.selectedTxid
  Array.find (\entry -> entry.txid == txid) st.entries

signerCollected :: PendingTx.PendingTxEntry -> String -> Boolean
signerCollected entry signer = case FO.lookup signer entry.witnesses of
  Just _ -> true
  Nothing -> false

graphEffectFromIntent :: Json -> Maybe Api.GraphEffect
graphEffectFromIntent intent = do
  object <- Argonaut.toObject intent
  let
    fields :: Array (Tuple String Json)
    fields = FO.toUnfoldable object
  Array.head (Array.mapMaybe decodeField fields)
  where
  decodeField (Tuple key value)
    | String.contains (String.Pattern "GraphEffect") key =
        case decodeJson value of
          Right effect -> Just effect
          Left _ -> Nothing
    | otherwise = Nothing

maybeValueText :: Maybe Api.ValueSummary -> String
maybeValueText = case _ of
  Nothing -> "-"
  Just value -> valueText value

valueText :: Api.ValueSummary -> String
valueText value = showAda value.lovelace

slotText :: Maybe Int -> String
slotText = case _ of
  Nothing -> "unknown"
  Just slot -> show slot

boolAttr :: Boolean -> String
boolAttr true = "true"
boolAttr false = "false"

cn :: String -> HH.ClassName
cn = HH.ClassName
