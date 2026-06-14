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
import Data.DateTime (date, day, hour, minute, month, second, time, year)
import Data.DateTime.Instant (toDateTime)
import Data.Either (Either(..))
import Data.Enum (fromEnum)
import Data.Int as Int
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Nullable as Nullable
import Data.String as String
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Aff (Aff, makeAff, nonCanceler)
import Effect.Aff as Aff
import Effect.Aff.Class (class MonadAff)
import Effect.Exception as Error
import Effect.Now (now)
import Foreign.Object as FO
import Format (shortAddr, shortHex, showAda)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP
import Routing (Route(..))
import Shell as Shell
import Shell.Clipboard as Clipboard
import Store.PendingTx as PendingTx
import Theme as Theme

type State =
  { entries :: Array PendingTx.PendingTxEntry
  , selectedTxid :: Maybe String
  , loadError :: Maybe String
  , tipSlot :: Maybe Int
  , witnessText :: String
  , witnessStatus :: Maybe WitnessStatus
  , verifyingWitness :: Boolean
  , submitStatus :: Maybe SubmitStatus
  , submittingTxid :: Maybe String
  , rebuildStatus :: Maybe RebuildStatus
  , rebuildingTxid :: Maybe String
  , theme :: Theme.Theme
  }

data WitnessStatus
  = WitnessSuccess String
  | WitnessFailure String

data SubmitStatus
  = SubmitSuccess String
  | SubmitFailure String

data RebuildStatus
  = RebuildSuccess String
  | RebuildFailure String

type RebuildRecipe =
  { buildEndpoint :: String
  , buildRequest :: Json
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
  | SetWitnessText String
  | WitnessFilePicked
  | VerifyWitness
  | SubmitSelected
  | RebuildSelected
  | CopyText String

initialState :: State
initialState =
  { entries: []
  , selectedTxid: Nothing
  , loadError: Nothing
  , tipSlot: Nothing
  , witnessText: ""
  , witnessStatus: Nothing
  , verifyingWitness: false
  , submitStatus: Nothing
  , submittingTxid: Nothing
  , rebuildStatus: Nothing
  , rebuildingTxid: Nothing
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
      , witnessText: ""
      , witnessStatus: Nothing
      , verifyingWitness: false
      , submitStatus: Nothing
      , submittingTxid: Nothing
      , rebuildStatus: Nothing
      , rebuildingTxid: Nothing
      , theme
      }
  ToggleTheme -> do
    st <- H.get
    next <- H.liftEffect (Shell.toggleThemeEff st.theme)
    H.modify_ (_ { theme = next })
  CopyText value -> H.liftEffect (Clipboard.writeText value)
  SelectEntry txid ->
    H.modify_
      ( _
          { selectedTxid = Just txid
          , witnessText = ""
          , witnessStatus = Nothing
          , submitStatus = Nothing
          , rebuildStatus = Nothing
          }
      )
  SetWitnessText txt ->
    H.modify_
      ( _
          { witnessText = txt
          , witnessStatus = Nothing
          }
      )
  WitnessFilePicked -> do
    picked <- H.liftAff (Aff.try (readFileAff "#pending-witness-file"))
    H.modify_ \s -> case picked of
      Right txt ->
        s
          { witnessText = String.trim txt
          , witnessStatus = Nothing
          }
      Left err ->
        s
          { witnessStatus =
              Just (WitnessFailure (Error.message err))
          }
  VerifyWitness -> do
    st <- H.get
    case selectedEntry st of
      Nothing -> pure unit
      Just entry -> do
        let
          witnessHex = String.trim st.witnessText
        if witnessHex == "" then
          H.modify_
            ( _
                { witnessStatus =
                    Just
                      (WitnessFailure "paste or upload a witness first")
                }
            )
        else do
          H.modify_
            ( _
                { verifyingWitness = true
                , witnessStatus = Nothing
                }
            )
          verified <-
            H.liftAff
              (Api.verifyWitness entry.unsignedTxHex witnessHex)
          case verified of
            Left err ->
              H.modify_
                ( _
                    { verifyingWitness = false
                    , witnessStatus =
                        Just (WitnessFailure err)
                    }
                )
            Right response ->
              if response.ok then
                case response.signerKeyHash of
                  Nothing ->
                    H.modify_
                      ( _
                          { verifyingWitness = false
                          , witnessStatus =
                              Just
                                ( WitnessFailure
                                    "verified witness did not include \
                                    \a signer key hash"
                                )
                          }
                      )
                  Just signerKeyHash -> do
                    stored <-
                      H.liftAff
                        ( Aff.try do
                            PendingTx.addWitness
                              entry.txid
                              signerKeyHash
                              witnessHex
                            PendingTx.list
                        )
                    H.modify_ \s -> case stored of
                      Right entries ->
                        s
                          { entries = entries
                          , selectedTxid = Just entry.txid
                          , witnessText = ""
                          , verifyingWitness = false
                          , witnessStatus =
                              Just
                                ( WitnessSuccess
                                    ( "Witness accepted for "
                                        <> shortHex signerKeyHash
                                    )
                                )
                          }
                      Left err ->
                        s
                          { verifyingWitness = false
                          , witnessStatus =
                              Just
                                (WitnessFailure (Error.message err))
                          }
              else
                H.modify_
                  ( _
                      { verifyingWitness = false
                      , witnessStatus =
                          Just
                            ( WitnessFailure
                                ( fromMaybe
                                    "witness rejected"
                                    response.reason
                                )
                            )
                      }
                  )
  SubmitSelected -> do
    st <- H.get
    case selectedEntry st of
      Nothing -> pure unit
      Just entry ->
        if not (entryCanSubmit st entry) || submitBusy st then
          pure unit
        else do
          let
            witnesses = collectedWitnesses entry
          H.modify_
            ( _
                { submittingTxid = Just entry.txid
                , submitStatus = Nothing
                }
            )
          attached <-
            H.liftAff (Api.attach entry.unsignedTxHex witnesses)
          case attached of
            Left err ->
              H.modify_
                ( finishSubmit
                    entry.txid
                    (SubmitFailure ("Attach failed: " <> err))
                )
            Right attachedTx -> do
              submitted <- H.liftAff (Api.submit attachedTx.cborHex)
              case submitted of
                Left err ->
                  H.modify_
                    ( finishSubmit
                        entry.txid
                        (SubmitFailure ("Submit failed: " <> err))
                    )
                Right response ->
                  H.modify_
                    ( finishSubmit
                        entry.txid
                        (SubmitSuccess response.txid)
                    )
  RebuildSelected -> do
    st <- H.get
    case selectedEntry st of
      Nothing -> pure unit
      Just entry ->
        if rebuildBusy st then
          pure unit
        else case rebuildRecipeFromIntent entry.intent of
          Nothing ->
            H.modify_
              ( _
                  { rebuildStatus =
                      Just
                        ( RebuildFailure
                            "rebuild unavailable for this entry"
                        )
                  }
              )
          Just recipe -> do
            H.modify_
              ( _
                  { rebuildingTxid = Just entry.txid
                  , rebuildStatus = Nothing
                  }
              )
            built <-
              H.liftAff
                ( Api.rebuildFromRecipe
                    recipe.buildEndpoint
                    recipe.buildRequest
                )
            case built of
              Left err ->
                H.modify_
                  ( finishRebuild
                      entry.txid
                      (RebuildFailure ("Rebuild failed: " <> err))
                  )
              Right buildResponse -> do
                introspected <-
                  H.liftAff (Api.introspectTx buildResponse.cborHex)
                case introspected of
                  Left err ->
                    H.modify_
                      ( finishRebuild
                          entry.txid
                          (RebuildFailure ("Introspect failed: " <> err))
                      )
                  Right meta -> do
                    savedAt <- H.liftEffect utcTimestamp
                    let
                      newEntry =
                        rebuiltEntry
                          entry
                          buildResponse.cborHex
                          buildResponse.graphEffect
                          meta
                          savedAt
                    stored <-
                      H.liftAff
                        ( Aff.try do
                            PendingTx.supersede entry.txid newEntry
                            PendingTx.list
                        )
                    H.modify_ \s -> case stored of
                      Right entries ->
                        s
                          { entries = entries
                          , selectedTxid = Just meta.txid
                          , witnessText = ""
                          , witnessStatus = Nothing
                          , submitStatus = Nothing
                          , rebuildStatus =
                              Just (RebuildSuccess meta.txid)
                          , rebuildingTxid = Nothing
                          }
                      Left err ->
                        s
                          { rebuildStatus =
                              Just
                                ( RebuildFailure
                                    ( "Rebuild failed: "
                                        <> Error.message err
                                    )
                                )
                          , rebuildingTxid = Nothing
                          }

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
              [ HP.classes [ cn "pending-entry-card__title" ]
              , HP.title entry.txid
              ]
              [ HH.text (shortHex entry.txid) ]
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
              [ HP.classes [ cn "pending-entry-card__history" ]
              , HP.title previous
              ]
              [ HH.text ("supersedes " <> shortHex previous) ]
      , case supersededBy st.entries entry of
          Nothing -> HH.text ""
          Just successor ->
            HH.p
              [ HP.classes [ cn "pending-entry-card__history" ]
              , HP.title successor
              ]
              [ HH.text ("superseded by " <> shortHex successor) ]
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
      [ HH.span [ HP.title signer ] [ HH.text (shortHex signer) ]
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
            [ HH.h2 [ HP.title entry.txid ] [ HH.text (shortHex entry.txid) ]
            , HH.code_ [ HH.text entry.scope ]
            ]
        , distributePanel entry
        , witnessRoster entry
        , witnessVerifier st entry
        , submitPanel st entry
        , rebuildPanel st entry
        , graphProjection entry
        ]

-- | Copy the selected entry's unsigned tx for distribution to
-- | co-signers, either as raw CBOR hex or as the cardano-cli text
-- | envelope.
distributePanel
  :: forall w
   . PendingTx.PendingTxEntry
  -> HH.HTML w Action
distributePanel entry =
  HH.section
    [ HP.classes [ cn "pending-detail__section" ] ]
    [ HH.h3_ [ HH.text "Distribute" ]
    , HH.p
        [ HP.classes [ cn "pending-submit__hint" ] ]
        [ HH.text "Copy the unsigned transaction to send to co-signers." ]
    , HH.div
        [ HP.classes [ cn "pending-submit__row" ] ]
        [ HH.button
            [ HP.type_ HP.ButtonButton
            , HP.classes [ cn "btn", cn "btn--ghost" ]
            , HP.title "Copy raw CBOR hex"
            , HE.onClick (\_ -> CopyText entry.unsignedTxHex)
            ]
            [ HH.text "Copy CBOR" ]
        , HH.button
            [ HP.type_ HP.ButtonButton
            , HP.classes [ cn "btn", cn "btn--ghost" ]
            , HP.title "Copy cardano-cli text envelope (Tx ConwayEra)"
            , HE.onClick (\_ -> CopyText (txEnvelopeJson entry.unsignedTxHex))
            ]
            [ HH.text "Copy envelope" ]
        ]
    ]

-- | Wrap raw tx CBOR hex as the cardano-cli Conway text envelope,
-- | byte-identical to the server's @envelope-tx@ output (4-space
-- | indent, @type@/@description@/@cborHex@ key order, trailing
-- | newline) so it pipes straight into @cardano-cli transaction
-- | witness@.
txEnvelopeJson :: String -> String
txEnvelopeJson hex =
  "{\n"
    <> "    \"type\": \"Tx ConwayEra\",\n"
    <> "    \"description\": \"Ledger Cddl Format\",\n"
    <> "    \"cborHex\": \""
    <> hex
    <> "\"\n"
    <> "}\n"

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
      [ HH.code [ HP.title signer ] [ HH.text (shortHex signer) ]
      , HH.span_
          [ HH.text (if collected then "Collected" else "Missing") ]
      ]

witnessVerifier
  :: forall w
   . State
  -> PendingTx.PendingTxEntry
  -> HH.HTML w Action
witnessVerifier st _entry =
  HH.section
    [ HP.classes
        [ cn "pending-detail__section"
        , cn "pending-witness"
        ]
    ]
    [ HH.h3_ [ HH.text "Add witness" ]
    , HH.label
        [ HP.classes [ cn "field" ] ]
        [ HH.span
            [ HP.classes [ cn "field__label" ] ]
            [ HH.text "Witness hex" ]
        , HH.textarea
            [ HP.value st.witnessText
            , HE.onValueInput SetWitnessText
            , HP.classes
                [ cn "field__input"
                , cn "field__input--mono"
                , cn "field__textarea"
                ]
            , HP.attr (HH.AttrName "rows") "5"
            , HP.attr
                (HH.AttrName "autocomplete")
                "off"
            ]
        ]
    , HH.div
        [ HP.classes [ cn "pending-witness__row" ] ]
        [ HH.label
            [ HP.classes [ cn "field", cn "pending-witness__file" ] ]
            [ HH.span
                [ HP.classes [ cn "field__label" ] ]
                [ HH.text "Witness file" ]
            , HH.input
                [ HP.type_ HP.InputFile
                , HP.id "pending-witness-file"
                , HP.classes [ cn "field__input" ]
                , HP.attr
                    (HH.AttrName "accept")
                    ".hex,.txt,text/plain"
                , HE.onChange (\_ -> WitnessFilePicked)
                ]
            ]
        , HH.button
            [ HP.type_ HP.ButtonButton
            , HP.classes [ cn "btn", cn "btn--filled" ]
            , HP.disabled
                ( st.verifyingWitness
                    || String.trim st.witnessText == ""
                )
            , HE.onClick (\_ -> VerifyWitness)
            ]
            [ HH.text
                ( if st.verifyingWitness then "Verifying"
                  else "Verify witness"
                )
            ]
        ]
    , case st.witnessStatus of
        Nothing -> HH.text ""
        Just status -> witnessStatusView status
    ]

witnessStatusView
  :: forall w i
   . WitnessStatus
  -> HH.HTML w i
witnessStatusView = case _ of
  WitnessSuccess msg ->
    HH.p
      [ HP.classes
          [ cn "pending-witness__status"
          , cn "pending-witness__status--ok"
          ]
      ]
      [ HH.text msg ]
  WitnessFailure msg ->
    HH.p
      [ HP.classes
          [ cn "pending-witness__status"
          , cn "pending-witness__status--error"
          ]
      ]
      [ HH.text msg ]

submitPanel
  :: forall w
   . State
  -> PendingTx.PendingTxEntry
  -> HH.HTML w Action
submitPanel st entry =
  let
    busy = submitBusy st
    disabled = busy || not (entryCanSubmit st entry)
  in
    HH.section
      [ HP.classes
          [ cn "pending-detail__section"
          , cn "pending-submit"
          ]
      ]
      [ HH.h3_ [ HH.text "Submit" ]
      , HH.div
          [ HP.classes [ cn "pending-submit__row" ] ]
          [ HH.button
              [ HP.type_ HP.ButtonButton
              , HP.classes [ cn "btn", cn "btn--filled" ]
              , HP.disabled disabled
              , HE.onClick (\_ -> SubmitSelected)
              ]
              [ HH.text "Submit transaction" ]
          ]
      , submitGateStatus st entry
      , case st.submitStatus of
          Nothing -> HH.text ""
          Just status -> submitStatusView status
      ]

submitGateStatus
  :: forall w i
   . State
  -> PendingTx.PendingTxEntry
  -> HH.HTML w i
submitGateStatus st entry
  | submitBusy st =
      HH.p
        [ HP.classes [ cn "pending-submit__hint" ] ]
        [ HH.text "Submitting" ]
  | otherwise = case submitUnavailableReason st entry of
      Nothing -> HH.text ""
      Just reason ->
        HH.p
          [ HP.classes [ cn "pending-submit__hint" ] ]
          [ HH.text reason ]

submitStatusView
  :: forall w i
   . SubmitStatus
  -> HH.HTML w i
submitStatusView = case _ of
  SubmitSuccess txid ->
    HH.p
      [ HP.classes
          [ cn "pending-submit__status"
          , cn "pending-submit__status--ok"
          ]
      ]
      [ HH.text "Submitted txid "
      , HH.code [ HP.title txid ] [ HH.text (shortHex txid) ]
      ]
  SubmitFailure msg ->
    HH.p
      [ HP.classes
          [ cn "pending-submit__status"
          , cn "pending-submit__status--error"
          ]
      ]
      [ HH.text msg ]

rebuildPanel
  :: forall w
   . State
  -> PendingTx.PendingTxEntry
  -> HH.HTML w Action
rebuildPanel st entry =
  let
    busy = rebuildBusy st
  in
    HH.section
      [ HP.classes
          [ cn "pending-detail__section"
          , cn "pending-rebuild"
          ]
      ]
      [ HH.h3_ [ HH.text "Rebuild" ]
      , case rebuildRecipeFromIntent entry.intent of
          Nothing ->
            HH.p
              [ HP.classes [ cn "pending-submit__hint" ] ]
              [ HH.text "rebuild unavailable for this entry" ]
          Just _ ->
            HH.div
              [ HP.classes [ cn "pending-submit__row" ] ]
              [ HH.button
                  [ HP.type_ HP.ButtonButton
                  , HP.classes [ cn "btn", cn "btn--filled" ]
                  , HP.disabled busy
                  , HE.onClick (\_ -> RebuildSelected)
                  ]
                  [ HH.text
                      ( if busy then "Rebuilding"
                        else "Rebuild transaction"
                      )
                  ]
              ]
      , case st.rebuildStatus of
          Nothing -> HH.text ""
          Just status -> rebuildStatusView status
      ]

rebuildStatusView
  :: forall w i
   . RebuildStatus
  -> HH.HTML w i
rebuildStatusView = case _ of
  RebuildSuccess txid ->
    HH.p
      [ HP.classes
          [ cn "pending-submit__status"
          , cn "pending-submit__status--ok"
          ]
      ]
      [ HH.text "Rebuilt txid "
      , HH.code_ [ HH.text txid ]
      ]
  RebuildFailure msg ->
    HH.p
      [ HP.classes
          [ cn "pending-submit__status"
          , cn "pending-submit__status--error"
          ]
      ]
      [ HH.text msg ]

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
    [ kvT "input" shortHex input.txIn
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
    , kvT "address" shortAddr output.address
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

-- | Like `kv`, but middle-truncates a long value (txid/hash/address)
-- | with the given truncator and keeps the full value in a tooltip.
kvT :: forall w i. String -> (String -> String) -> String -> HH.HTML w i
kvT label trunc full =
  HH.div
    [ HP.classes [ cn "pending-kv" ] ]
    [ HH.span_ [ HH.text label ]
    , HH.code [ HP.title full ] [ HH.text (trunc full) ]
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
entryInHistory entries entry =
  supersededByPresent || supersedesAbsentPredecessor
  where
  supersededByPresent = case supersededBy entries entry of
    Just _ -> true
    Nothing -> false

  supersedesAbsentPredecessor =
    case Nullable.toMaybe entry.supersedes of
      Nothing -> false
      Just previous ->
        not
          ( Array.any
              (\candidate -> candidate.txid == previous)
              entries
          )

supersededBy
  :: Array PendingTx.PendingTxEntry
  -> PendingTx.PendingTxEntry
  -> Maybe String
supersededBy entries entry =
  _.txid
    <$> Array.find
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

collectedWitnesses :: PendingTx.PendingTxEntry -> Array String
collectedWitnesses entry =
  Array.mapMaybe
    (\signer -> FO.lookup signer entry.witnesses)
    entry.requiredSigners

missingRequiredSigners :: PendingTx.PendingTxEntry -> Array String
missingRequiredSigners entry =
  Array.filter (not <<< signerCollected entry) entry.requiredSigners

entryCanSubmit :: State -> PendingTx.PendingTxEntry -> Boolean
entryCanSubmit st entry =
  not (entryExpired st.tipSlot entry)
    && Array.null (missingRequiredSigners entry)

submitUnavailableReason
  :: State
  -> PendingTx.PendingTxEntry
  -> Maybe String
submitUnavailableReason st entry
  | entryExpired st.tipSlot entry =
      Just "Transaction expired"
  | otherwise =
      let
        missing = missingRequiredSigners entry
      in
        if Array.null missing then Nothing
        else Just ("Missing " <> Array.intercalate ", " (map shortHex missing))

submitBusy :: State -> Boolean
submitBusy st = case st.submittingTxid of
  Nothing -> false
  Just _ -> true

rebuildBusy :: State -> Boolean
rebuildBusy st = case st.rebuildingTxid of
  Nothing -> false
  Just _ -> true

finishSubmit :: String -> SubmitStatus -> State -> State
finishSubmit txid status st =
  if st.selectedTxid == Just txid then
    st
      { submittingTxid = Nothing
      , submitStatus = Just status
      }
  else
    st { submittingTxid = Nothing }

finishRebuild :: String -> RebuildStatus -> State -> State
finishRebuild txid status st =
  if st.selectedTxid == Just txid then
    st
      { rebuildingTxid = Nothing
      , rebuildStatus = Just status
      }
  else
    st { rebuildingTxid = Nothing }

rebuildRecipeFromIntent :: Json -> Maybe RebuildRecipe
rebuildRecipeFromIntent intent = do
  object <- Argonaut.toObject intent
  buildEndpoint <- FO.lookup "buildEndpoint" object >>= Argonaut.toString
  _ <- Api.buildCborField buildEndpoint
  buildRequest <- FO.lookup "buildRequest" object
  pure { buildEndpoint, buildRequest }

rebuiltEntry
  :: PendingTx.PendingTxEntry
  -> String
  -> Maybe Json
  -> Api.IntrospectResponse
  -> String
  -> PendingTx.PendingTxEntry
rebuiltEntry previous cborHex graphEffect meta savedAt =
  { txid: meta.txid
  , intent: mergeGraphEffect graphEffect previous.intent
  , unsignedTxHex: cborHex
  , scope: fromMaybe previous.scope meta.scope
  , requiredSigners: meta.requiredSigners
  , invalidHereafter:
      case meta.invalidHereafter of
        Nothing -> Nullable.null
        Just slot -> Nullable.notNull (show slot)
  , witnesses: emptyWitnesses
  , savedAt
  , supersedes: Nullable.null
  }

emptyWitnesses :: FO.Object String
emptyWitnesses = FO.fromFoldable []

-- | Fold a freshly-resolved graph-effect into a rebuilt entry's
-- | intent under @resolvedGraphEffect@ so the /pending detail panel
-- | can inspect it.  Replaces any stale effect and leaves the
-- | rebuild recipe (kind/buildEndpoint/buildRequest) intact.  A
-- | 'Nothing' effect (e.g. reorganize) leaves the intent unchanged.
mergeGraphEffect :: Maybe Json -> Json -> Json
mergeGraphEffect Nothing intent = intent
mergeGraphEffect (Just effect) intent = case Argonaut.toObject intent of
  Nothing -> intent
  Just object ->
    Argonaut.fromObject (FO.insert "resolvedGraphEffect" effect object)

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

utcTimestamp :: Effect String
utcTimestamp = do
  inst <- now
  let
    dt = toDateTime inst
    d = date dt
    t = time dt
    yy = show (fromEnum (year d))
    mm = padTwo (fromEnum (month d))
    dd = padTwo (fromEnum (day d))
    hh = padTwo (fromEnum (hour t))
    mi = padTwo (fromEnum (minute t))
    ss = padTwo (fromEnum (second t))
  pure
    ( yy <> "-" <> mm <> "-" <> dd <> "T"
        <> hh
        <> ":"
        <> mi
        <> ":"
        <> ss
        <> "Z"
    )

padTwo :: Int -> String
padTwo n
  | n < 10 = "0" <> show n
  | otherwise = show n

boolAttr :: Boolean -> String
boolAttr true = "true"
boolAttr false = "false"

cn :: String -> HH.ClassName
cn = HH.ClassName

readFileAff :: String -> Aff String
readFileAff selector = makeAff \cb -> do
  _readFileFromInput
    selector
    (cb <<< Right)
    (cb <<< Left)
  pure nonCanceler

foreign import _readFileFromInput
  :: String
  -> (String -> Effect Unit)
  -> (Error.Error -> Effect Unit)
  -> Effect Unit
