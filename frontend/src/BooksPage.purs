-- | #267 — /books route.
-- |
-- | Per-browser management surface for the operator's
-- | history books.  One card per book in the FR-005
-- | mapping, grouped by shape:
-- |
-- |   * **Named cards** (@wallets@, @reference_uris@)
-- |     show rename-on-blur name inputs, a read-only typed
-- |     value cell with full-value @title@ hover, and an
-- |     `Add new` editor for manually populating entries
-- |     before the first build.
-- |   * **Free-text cards** (descriptions, justifications,
-- |     destination labels, validity hours, slippage,
-- |     splits, reference @types, reference labels) show
-- |     plain text rows with per-entry deletion and a
-- |     `Clear all` button gated behind a confirm prompt.
-- |
-- | Import / export lives in slice D.  This slice carries
-- | the read + mutate surfaces only.
module BooksPage (component) where

import Prelude

import Data.Array as Array
import Data.Maybe (Maybe(..))
import Data.String as String
import Effect (Effect)
import Effect.Aff.Class (class MonadAff)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

import Routing (Route(..))
import Shell as Shell
import Shell
  ( initialTheme
  , themeLabel
  , toggleThemeEff
  , topbar
  )
import Shell.Book
  ( BookKey(..)
  , FreeTextBookKey(..)
  , NamedBookKey(..)
  , NamedEntry(..)
  , addNamed
  , clear
  , loadFreeText
  , loadNamed
  , namedTypedValue
  , removeFreeText
  , removeNamed
  , renameNamed
  )
import Theme as Theme
import Web.UIEvent.KeyboardEvent (KeyboardEvent)
import Web.UIEvent.KeyboardEvent as KE

-- ---------------------------------------------------------------------------
-- Books cache
--
-- Duplicated from `OperatePage` rather than factored to a
-- shared `Shell.Book.Cache` module — slice C is the second
-- consumer; factoring after the third is the rule.

type Books =
  { wallets :: Array NamedEntry
  , referenceUris :: Array NamedEntry
  , descriptions :: Array String
  , justifications :: Array String
  , destinationLabels :: Array String
  , validityHours :: Array String
  , slippageBps :: Array String
  , splitCounts :: Array String
  , referenceTypes :: Array String
  , referenceLabels :: Array String
  }

emptyBooks :: Books
emptyBooks =
  { wallets: []
  , referenceUris: []
  , descriptions: []
  , justifications: []
  , destinationLabels: []
  , validityHours: []
  , slippageBps: []
  , splitCounts: []
  , referenceTypes: []
  , referenceLabels: []
  }

loadAllBooks :: Effect Books
loadAllBooks = do
  ws <- loadNamed WalletsBook
  rs <- loadNamed ReferenceUrisBook
  ds <- loadFreeText DescriptionsBook
  js <- loadFreeText JustificationsBook
  dl <- loadFreeText DestinationLabelsBook
  vh <- loadFreeText ValidityHoursBook
  sb <- loadFreeText SlippageBpsBook
  sc <- loadFreeText SplitCountsBook
  rt <- loadFreeText ReferenceTypesBook
  rl <- loadFreeText ReferenceLabelsBook
  pure
    { wallets: ws
    , referenceUris: rs
    , descriptions: ds
    , justifications: js
    , destinationLabels: dl
    , validityHours: vh
    , slippageBps: sb
    , splitCounts: sc
    , referenceTypes: rt
    , referenceLabels: rl
    }

allBooksEmpty :: Books -> Boolean
allBooksEmpty b =
  Array.null b.wallets
    && Array.null b.referenceUris
    && Array.null b.descriptions
    && Array.null b.justifications
    && Array.null b.destinationLabels
    && Array.null b.validityHours
    && Array.null b.slippageBps
    && Array.null b.splitCounts
    && Array.null b.referenceTypes
    && Array.null b.referenceLabels

freeTextEntries :: FreeTextBookKey -> Books -> Array String
freeTextEntries k b = case k of
  DescriptionsBook -> b.descriptions
  JustificationsBook -> b.justifications
  DestinationLabelsBook -> b.destinationLabels
  ValidityHoursBook -> b.validityHours
  SlippageBpsBook -> b.slippageBps
  SplitCountsBook -> b.splitCounts
  ReferenceTypesBook -> b.referenceTypes
  ReferenceLabelsBook -> b.referenceLabels

namedEntries :: NamedBookKey -> Books -> Array NamedEntry
namedEntries k b = case k of
  WalletsBook -> b.wallets
  ReferenceUrisBook -> b.referenceUris

-- ---------------------------------------------------------------------------
-- Component state

-- | Identifies which named entry's name input is currently
-- | the focused / draft target.  The String is the entry's
-- | typed value (address / cid) — the stable identity
-- | within a named book.
data EditingId = EditingId NamedBookKey String

derive instance eqEditingId :: Eq EditingId

type State =
  { books :: Books
  , editing :: Maybe EditingId
  , adding :: Maybe NamedBookKey
  , draftName :: String
  , draftValue :: String
  , clearConfirm :: Maybe FreeTextBookKey
  , theme :: Theme.Theme
  }

initialState :: State
initialState =
  { books: emptyBooks
  , editing: Nothing
  , adding: Nothing
  , draftName: ""
  , draftValue: ""
  , clearConfirm: Nothing
  , theme: Theme.Dark
  }

data Action
  = Initialize
  | ToggleTheme
  | StartRename EditingId String
  | UpdateDraftName String
  | CommitRename
  | CancelRename
  | RenameKeyDown KeyboardEvent
  | RemoveNamedEntry NamedBookKey String
  | RemoveFreeTextEntry FreeTextBookKey String
  | RequestClearFreeText FreeTextBookKey
  | ConfirmClearFreeText
  | CancelClearFreeText
  | OpenAddNamed NamedBookKey
  | UpdateDraftValue String
  | CommitAdd
  | CancelAdd
  | AddKeyDown KeyboardEvent

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
          { handleAction = handleAction
          , initialize = Just Initialize
          }
    }

-- ---------------------------------------------------------------------------
-- Render

render :: forall m. State -> H.ComponentHTML Action () m
render st =
  HH.div_
    [ topbar RouteBooks
        { themeLabel: themeLabel st.theme
        , onToggleTheme: ToggleTheme
        }
    , siteHeader
    , HH.div
        [ HP.classes [ cn "build-layout" ]
        , HP.style "flex-direction:column;gap:1rem"
        ]
        ( emptyStateNotice st
            <> namedCardSection st
            <> freeTextCardSection st
        )
    , Shell.siteFooter { buildIdentityLine: "" }
    ]

siteHeader :: forall m. H.ComponentHTML Action () m
siteHeader =
  HH.div [ HP.classes [ cn "site-header" ] ]
    [ HH.h1
        [ HP.classes
            [ cn "md-typescale-display-medium"
            , cn "site-header__title"
            ]
        ]
        [ HH.text "Books" ]
    , HH.p
        [ HP.classes
            [ cn "md-typescale-body-large"
            , cn "site-header__lede"
            ]
        ]
        [ HH.text
            "Per-browser history for every booked field on \
            \/operate.  Submitted values populate \
            \automatically; you can also add, rename, or \
            \remove entries here."
        ]
    ]

emptyStateNotice
  :: forall m
   . State -> Array (H.ComponentHTML Action () m)
emptyStateNotice st
  | allBooksEmpty st.books =
      [ HH.div
          [ HP.classes [ cn "form-section" ]
          , HP.style "padding:1rem;opacity:.8"
          ]
          [ HH.p
              [ HP.classes
                  [ cn "md-typescale-body-medium" ]
              ]
              [ HH.text
                  "Books are per-browser — values appear \
                  \after you submit a build on /operate.  \
                  \Named books can also be populated \
                  \manually via + Add new.  No \
                  \cross-device sync."
              ]
          ]
      ]
  | otherwise = []

-- ---------------------------------------------------------------------------
-- Named cards

namedCardSection
  :: forall m
   . State -> Array (H.ComponentHTML Action () m)
namedCardSection st =
  [ namedCard st WalletsBook
  , namedCard st ReferenceUrisBook
  ]

namedCard
  :: forall m
   . State
  -> NamedBookKey
  -> H.ComponentHTML Action () m
namedCard st key =
  let
    entries = namedEntries key st.books
  in
    bookCard (namedHeader key)
      ( if Array.null entries then
          [ emptyCardCaption (namedEmpty key) ]
        else
          map (namedEntryRow st key) entries
      )
      [ namedFooter st key ]

namedEntryRow
  :: forall m
   . State
  -> NamedBookKey
  -> NamedEntry
  -> H.ComponentHTML Action () m
namedEntryRow st key entry =
  let
    tv = namedTypedValue entry
    eid = EditingId key tv
    nameForDisplay = case st.editing of
      Just other | other == eid -> st.draftName
      _ -> entryName entry
  in
    HH.div
      [ HP.classes [ cn "reference-row" ]
      , HP.style "align-items:center;gap:.5rem"
      ]
      [ HH.input
          [ HP.value nameForDisplay
          , HP.type_ HP.InputText
          , HP.classes [ cn "field__input" ]
          , HP.placeholder "name"
          , HE.onFocus (\_ -> StartRename eid (entryName entry))
          , HE.onValueInput UpdateDraftName
          , HE.onBlur (\_ -> CommitRename)
          , HE.onKeyDown RenameKeyDown
          , HP.style "flex:1"
          ]
      , HH.span
          [ HP.classes [ cn "field__input", cn "field__input--mono" ]
          , HP.title tv
          , HP.style
              "flex:1.4;display:block;\
              \overflow:hidden;text-overflow:ellipsis;\
              \white-space:nowrap;padding:.5rem;\
              \background:transparent;cursor:default"
          ]
          [ HH.text (truncate tv) ]
      , HH.button
          [ HP.classes [ cn "btn", cn "btn--ghost" ]
          , HE.onClick (\_ -> RemoveNamedEntry key tv)
          , HP.type_ HP.ButtonButton
          , HP.title "Remove this entry"
          ]
          [ HH.text "×" ]
      ]

namedFooter
  :: forall m
   . State
  -> NamedBookKey
  -> H.ComponentHTML Action () m
namedFooter st key = case st.adding of
  Just k | k == key -> namedAddEditor st key
  _ ->
    HH.button
      [ HP.classes [ cn "btn", cn "btn--ghost" ]
      , HE.onClick (\_ -> OpenAddNamed key)
      , HP.type_ HP.ButtonButton
      ]
      [ HH.text "+ Add new" ]

namedAddEditor
  :: forall m
   . State
  -> NamedBookKey
  -> H.ComponentHTML Action () m
namedAddEditor st key =
  HH.div
    [ HP.classes [ cn "reference-row" ]
    , HP.style "gap:.5rem;align-items:center"
    ]
    [ HH.input
        [ HP.value st.draftName
        , HP.type_ HP.InputText
        , HP.classes [ cn "field__input" ]
        , HP.placeholder "Friendly name"
        , HE.onValueInput UpdateDraftName
        , HE.onKeyDown AddKeyDown
        , HP.style "flex:1"
        ]
    , HH.input
        [ HP.value st.draftValue
        , HP.type_ HP.InputText
        , HP.classes [ cn "field__input", cn "field__input--mono" ]
        , HP.placeholder (namedValuePlaceholder key)
        , HE.onValueInput UpdateDraftValue
        , HE.onKeyDown AddKeyDown
        , HP.style "flex:1.4"
        ]
    , HH.button
        [ HP.classes [ cn "btn", cn "btn--primary" ]
        , HE.onClick (\_ -> CommitAdd)
        , HP.type_ HP.ButtonButton
        ]
        [ HH.text "Save" ]
    , HH.button
        [ HP.classes [ cn "btn", cn "btn--ghost" ]
        , HE.onClick (\_ -> CancelAdd)
        , HP.type_ HP.ButtonButton
        ]
        [ HH.text "Cancel" ]
    ]

namedHeader :: NamedBookKey -> String
namedHeader = case _ of
  WalletsBook -> "Wallets"
  ReferenceUrisBook -> "Reference URIs"

namedEmpty :: NamedBookKey -> String
namedEmpty = case _ of
  WalletsBook ->
    "No wallets yet.  Click + Add new or submit a build on \
    \/operate."
  ReferenceUrisBook ->
    "No reference URIs yet.  Click + Add new or submit a \
    \build on /operate."

namedValuePlaceholder :: NamedBookKey -> String
namedValuePlaceholder = case _ of
  WalletsBook -> "addr1q…"
  ReferenceUrisBook -> "bafy… (CID)"

entryName :: NamedEntry -> String
entryName = case _ of
  WalletE w -> w.name
  ReferenceUriE r -> r.name

-- ---------------------------------------------------------------------------
-- Free-text cards

freeTextCardSection
  :: forall m
   . State -> Array (H.ComponentHTML Action () m)
freeTextCardSection st =
  map (freeTextCard st)
    [ DescriptionsBook
    , JustificationsBook
    , DestinationLabelsBook
    , ValidityHoursBook
    , SlippageBpsBook
    , SplitCountsBook
    , ReferenceTypesBook
    , ReferenceLabelsBook
    ]

freeTextCard
  :: forall m
   . State
  -> FreeTextBookKey
  -> H.ComponentHTML Action () m
freeTextCard st key =
  let
    entries = freeTextEntries key st.books
  in
    bookCard (freeTextHeader key)
      ( if Array.null entries then
          [ emptyCardCaption (freeTextEmpty key) ]
        else
          map (freeTextRow key) entries
      )
      [ freeTextFooter st key (Array.length entries) ]

freeTextRow
  :: forall m
   . FreeTextBookKey
  -> String
  -> H.ComponentHTML Action () m
freeTextRow key value =
  HH.div
    [ HP.classes [ cn "reference-row" ]
    , HP.style "gap:.5rem;align-items:center"
    ]
    [ HH.span
        [ HP.classes [ cn "field__input" ]
        , HP.style
            "flex:1;display:block;padding:.5rem;\
            \overflow:hidden;text-overflow:ellipsis;\
            \white-space:nowrap;background:transparent"
        , HP.title value
        ]
        [ HH.text value ]
    , HH.button
        [ HP.classes [ cn "btn", cn "btn--ghost" ]
        , HE.onClick (\_ -> RemoveFreeTextEntry key value)
        , HP.type_ HP.ButtonButton
        , HP.title "Remove this entry"
        ]
        [ HH.text "×" ]
    ]

freeTextFooter
  :: forall m
   . State
  -> FreeTextBookKey
  -> Int
  -> H.ComponentHTML Action () m
freeTextFooter st key count = case st.clearConfirm of
  Just k | k == key ->
    HH.div
      [ HP.style
          "display:flex;gap:.5rem;align-items:center;\
          \flex-wrap:wrap"
      ]
      [ HH.span
          [ HP.classes [ cn "md-typescale-body-medium" ] ]
          [ HH.text
              ( "Clear all " <> show count <> " "
                  <> freeTextSingular key
                  <> "?  This cannot be undone."
              )
          ]
      , HH.button
          [ HP.classes [ cn "btn", cn "btn--primary" ]
          , HE.onClick (\_ -> ConfirmClearFreeText)
          , HP.type_ HP.ButtonButton
          ]
          [ HH.text "Clear" ]
      , HH.button
          [ HP.classes [ cn "btn", cn "btn--ghost" ]
          , HE.onClick (\_ -> CancelClearFreeText)
          , HP.type_ HP.ButtonButton
          ]
          [ HH.text "Cancel" ]
      ]
  _
    | count == 0 -> HH.text ""
    | otherwise ->
        HH.button
          [ HP.classes [ cn "btn", cn "btn--ghost" ]
          , HE.onClick (\_ -> RequestClearFreeText key)
          , HP.type_ HP.ButtonButton
          ]
          [ HH.text "Clear all" ]

freeTextHeader :: FreeTextBookKey -> String
freeTextHeader = case _ of
  DescriptionsBook -> "Descriptions"
  JustificationsBook -> "Justifications"
  DestinationLabelsBook -> "Destination labels"
  ValidityHoursBook -> "Validity hours"
  SlippageBpsBook -> "Slippage (bps)"
  SplitCountsBook -> "Split counts"
  ReferenceTypesBook -> "Reference @types"
  ReferenceLabelsBook -> "Reference labels"

freeTextSingular :: FreeTextBookKey -> String
freeTextSingular = case _ of
  DescriptionsBook -> "descriptions"
  JustificationsBook -> "justifications"
  DestinationLabelsBook -> "destination labels"
  ValidityHoursBook -> "validity-hours entries"
  SlippageBpsBook -> "slippage entries"
  SplitCountsBook -> "split counts"
  ReferenceTypesBook -> "reference @types"
  ReferenceLabelsBook -> "reference labels"

freeTextEmpty :: FreeTextBookKey -> String
freeTextEmpty = case _ of
  DescriptionsBook ->
    "No descriptions yet.  Submit a build on /operate to \
    \record entries."
  JustificationsBook ->
    "No justifications yet.  Submit a build on /operate to \
    \record entries."
  DestinationLabelsBook ->
    "No destination labels yet.  Submit a build on /operate \
    \to record entries."
  ValidityHoursBook ->
    "No validity-hours values yet.  Submit a build on \
    \/operate to record entries."
  SlippageBpsBook ->
    "No slippage values yet.  Submit a build on /operate to \
    \record entries."
  SplitCountsBook ->
    "No split counts yet.  Submit a build on /operate to \
    \record entries."
  ReferenceTypesBook ->
    "No reference @types yet.  Submit a build on /operate \
    \to record entries."
  ReferenceLabelsBook ->
    "No reference labels yet.  Submit a build on /operate \
    \to record entries."

-- ---------------------------------------------------------------------------
-- Card chrome + small helpers

bookCard
  :: forall m
   . String
  -> Array (H.ComponentHTML Action () m)
  -> Array (H.ComponentHTML Action () m)
  -> H.ComponentHTML Action () m
bookCard title body footer =
  HH.section
    [ HP.classes [ cn "form-section" ]
    , HP.style "padding:1rem;display:flex;flex-direction:column;gap:.5rem"
    ]
    ( [ HH.h2
          [ HP.classes
              [ cn "form-section__title"
              , cn "md-typescale-title-medium"
              ]
          ]
          [ HH.text title ]
      ]
        <> body
        <> footer
    )

emptyCardCaption
  :: forall m. String -> H.ComponentHTML Action () m
emptyCardCaption msg =
  HH.p
    [ HP.classes [ cn "md-typescale-body-small" ]
    , HP.style "opacity:.65"
    ]
    [ HH.text msg ]

-- | Display-only truncation for the typed-value cell on a
-- | named row.  Same shape `Shell.Book.deriveDefaultName`
-- | uses for placeholders, but inlined here to avoid
-- | exposing it from the sealed module.
truncate :: String -> String
truncate s
  | String.length s > 18 =
      String.take 8 s
        <> "…"
        <> String.drop (String.length s - 6) s
  | otherwise = s

cn :: String -> HH.ClassName
cn = HH.ClassName

-- ---------------------------------------------------------------------------
-- Handlers

handleAction
  :: forall output m
   . MonadAff m
  => Action
  -> H.HalogenM State Action () output m Unit
handleAction = case _ of
  Initialize -> do
    t <- H.liftEffect initialTheme
    books <- H.liftEffect loadAllBooks
    H.modify_ \s -> s { theme = t, books = books }

  ToggleTheme -> do
    st <- H.get
    t' <- H.liftEffect (toggleThemeEff st.theme)
    H.modify_ \s -> s { theme = t' }

  StartRename eid initial ->
    H.modify_ \s -> s { editing = Just eid, draftName = initial }

  UpdateDraftName s ->
    H.modify_ \st -> st { draftName = s }

  CommitRename -> do
    st <- H.get
    case st.editing of
      Just (EditingId key tv) -> do
        H.liftEffect (renameNamed key tv st.draftName)
        books' <- H.liftEffect loadAllBooks
        H.modify_ \s -> s
          { books = books'
          , editing = Nothing
          , draftName = ""
          }
      Nothing -> pure unit

  CancelRename ->
    H.modify_ \s -> s { editing = Nothing, draftName = "" }

  RenameKeyDown ev -> case KE.key ev of
    "Enter" -> handleAction CommitRename
    "Escape" -> handleAction CancelRename
    _ -> pure unit

  RemoveNamedEntry key value -> do
    H.liftEffect (removeNamed key value)
    books' <- H.liftEffect loadAllBooks
    H.modify_ \s -> s
      { books = books'
      , editing = case s.editing of
          Just (EditingId k v)
            | k == key && v == value -> Nothing
          other -> other
      }

  RemoveFreeTextEntry key value -> do
    H.liftEffect (removeFreeText key value)
    books' <- H.liftEffect loadAllBooks
    H.modify_ \s -> s { books = books' }

  RequestClearFreeText key ->
    H.modify_ \s -> s { clearConfirm = Just key }

  ConfirmClearFreeText -> do
    st <- H.get
    case st.clearConfirm of
      Just key -> do
        H.liftEffect (clear (F key))
        books' <- H.liftEffect loadAllBooks
        H.modify_ \s -> s
          { books = books'
          , clearConfirm = Nothing
          }
      Nothing -> pure unit

  CancelClearFreeText ->
    H.modify_ \s -> s { clearConfirm = Nothing }

  OpenAddNamed key ->
    H.modify_ \s -> s
      { adding = Just key
      , draftName = ""
      , draftValue = ""
      }

  UpdateDraftValue s ->
    H.modify_ \st -> st { draftValue = s }

  CommitAdd -> do
    st <- H.get
    case st.adding of
      Just key
        | String.trim st.draftValue /= "" -> do
            let entry = mkNamedEntry key st.draftName st.draftValue
            H.liftEffect (addNamed key entry)
            books' <- H.liftEffect loadAllBooks
            H.modify_ \s -> s
              { books = books'
              , adding = Nothing
              , draftName = ""
              , draftValue = ""
              }
      _ -> pure unit

  CancelAdd ->
    H.modify_ \s -> s
      { adding = Nothing
      , draftName = ""
      , draftValue = ""
      }

  AddKeyDown ev -> case KE.key ev of
    "Enter" -> handleAction CommitAdd
    "Escape" -> handleAction CancelAdd
    _ -> pure unit

-- | Build a 'NamedEntry' for 'addNamed' given the key.  If
-- | the operator left the name blank we fall back to the
-- | typed value so the dropdown still has a label.
mkNamedEntry
  :: NamedBookKey -> String -> String -> NamedEntry
mkNamedEntry key rawName value =
  let
    name =
      if String.trim rawName == "" then value
      else rawName
  in
    case key of
      WalletsBook -> WalletE { name, address: value }
      ReferenceUrisBook -> ReferenceUriE { name, cid: value }
