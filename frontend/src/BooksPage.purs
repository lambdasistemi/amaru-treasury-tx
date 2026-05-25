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

import Data.Argonaut.Core (stringify)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.DateTime (date, time, day, hour, minute, month, second, year)
import Data.DateTime.Instant (toDateTime)
import Data.Either (Either(..))
import Data.Enum (fromEnum)
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Time.Duration (Milliseconds(..))
import Effect (Effect)
import Effect.Aff (Aff, delay, makeAff, nonCanceler)
import Effect.Aff.Class (class MonadAff)
import Effect.Exception (Error)
import Effect.Now (now)
import Halogen as H
import Halogen.HTML as HH
import Halogen.HTML.Events as HE
import Halogen.HTML.Properties as HP

import BooksPage.Import (DiffRow)
import BooksPage.Import as Import
import Routing (Route(..))
import Shell as Shell
import Shell
  ( initialTheme
  , themeLabel
  , toggleThemeEff
  , topbar
  )
import Shell.Clipboard as Clipboard
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
  , replaceFreeText
  , replaceNamed
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

-- | Identifies one row whose trash icon was just clicked
-- | and is awaiting an explicit confirm (slice E's guarded
-- | delete).  The String is the entry's typed value for
-- | named rows, or the string content for free-text rows.
data RemoveTarget
  = RemoveNamedT NamedBookKey String
  | RemoveFreeTextT FreeTextBookKey String

derive instance eqRemoveTarget :: Eq RemoveTarget

type ImportPreview =
  { afterBooks :: Books
  , diffRows :: Array DiffRow
  , warnings :: Array String
  }

type ImportDialogState =
  { open :: Boolean
  , text :: String
  , destination :: Maybe FreeTextBookKey
  , error :: Maybe String
  , preview :: Maybe ImportPreview
  }

emptyImportDialog :: ImportDialogState
emptyImportDialog =
  { open: false
  , text: ""
  , destination: Nothing
  , error: Nothing
  , preview: Nothing
  }

type State =
  { books :: Books
  , editing :: Maybe EditingId
  , adding :: Maybe NamedBookKey
  , draftName :: String
  , draftValue :: String
  , clearConfirm :: Maybe FreeTextBookKey
  , theme :: Theme.Theme
  , importDialog :: ImportDialogState
  , confirmingRemove :: Maybe RemoveTarget
  , recentlyCopied :: Maybe String
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
  , importDialog: emptyImportDialog
  , confirmingRemove: Nothing
  , recentlyCopied: Nothing
  }

data Action
  = Initialize
  | ToggleTheme
  | StartRename EditingId String
  | UpdateDraftName String
  | CommitRename
  | CancelRename
  | RenameKeyDown KeyboardEvent
  | RequestRemove RemoveTarget
  | CancelRemove
  | ConfirmRemove
  | CopyValue String
  | ClearCopiedFlag String
  | RequestClearFreeText FreeTextBookKey
  | ConfirmClearFreeText
  | CancelClearFreeText
  | OpenAddNamed NamedBookKey
  | UpdateDraftValue String
  | CommitAdd
  | CancelAdd
  | AddKeyDown KeyboardEvent
  | ExportAll
  | CopyAll
  | ExportBookByKey BookKey
  | CopyBookByKey BookKey
  | OpenImport
  | CloseImport
  | UpdateImportText String
  | ImportFilePicked
  | UpdateImportDestination String
  | PreviewImport
  | ConfirmImport

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
    ( [ topbar RouteBooks
          { themeLabel: themeLabel st.theme
          , onToggleTheme: ToggleTheme
          }
      , siteHeader
      , HH.div
          [ HP.style
              "display:flex;flex-direction:column;\
              \gap:1rem;width:100%;max-width:1100px;\
              \margin:0 auto;padding:1rem 1.25rem 2rem;\
              \box-sizing:border-box"
          ]
          ( [ topOfPageActions ]
              <> emptyStateNotice st
              <> booksGroupSection st
          )
      , Shell.siteFooter { buildIdentityLine: "" }
      ]
        <> importDialogView st
    )

topOfPageActions :: forall m. H.ComponentHTML Action () m
topOfPageActions =
  HH.div
    [ HP.style
        "display:flex;gap:.5rem;flex-wrap:wrap;\
        \align-items:center"
    ]
    [ HH.button
        [ HP.classes [ cn "btn", cn "btn--primary" ]
        , HP.type_ HP.ButtonButton
        , HE.onClick (\_ -> ExportAll)
        ]
        [ HH.text "Export all" ]
    , HH.button
        [ HP.classes [ cn "btn", cn "btn--ghost" ]
        , HP.type_ HP.ButtonButton
        , HE.onClick (\_ -> CopyAll)
        ]
        [ HH.text "Copy all" ]
    , HH.button
        [ HP.classes [ cn "btn", cn "btn--ghost" ]
        , HP.type_ HP.ButtonButton
        , HE.onClick (\_ -> OpenImport)
        ]
        [ HH.text "Import…" ]
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
-- Card grouping (slice F)
--
-- Cards render under four semantic group headers in a fixed
-- order.  The grouping reflects how operators actually use
-- the fields — wallet identities, the three reference-row
-- columns, the rationale-text trio, and the numeric build
-- parameters.  Same per-card render path; only the
-- WRAPPING changes from "flat list" to "group-then-cards".

data BooksGroup
  = Identities
  | References
  | RationaleText
  | BuildParameters

allGroups :: Array BooksGroup
allGroups =
  [ Identities
  , References
  , RationaleText
  , BuildParameters
  ]

groupTitle :: BooksGroup -> String
groupTitle = case _ of
  Identities -> "Identities"
  References -> "References"
  RationaleText -> "Rationale text"
  BuildParameters -> "Build parameters"

groupContents :: BooksGroup -> Array BookKey
groupContents = case _ of
  Identities ->
    [ N WalletsBook ]
  References ->
    [ N ReferenceUrisBook
    , F ReferenceTypesBook
    , F ReferenceLabelsBook
    ]
  RationaleText ->
    [ F DescriptionsBook
    , F JustificationsBook
    , F DestinationLabelsBook
    ]
  BuildParameters ->
    [ F ValidityHoursBook
    , F SlippageBpsBook
    , F SplitCountsBook
    ]

booksGroupSection
  :: forall m
   . State -> Array (H.ComponentHTML Action () m)
booksGroupSection st =
  Array.concatMap (renderGroup st) allGroups

renderGroup
  :: forall m
   . State
  -> BooksGroup
  -> Array (H.ComponentHTML Action () m)
renderGroup st g =
  [ HH.h2
      [ HP.classes
          [ cn "md-typescale-headline-small"
          , cn "books-group"
          ]
      , HP.style
          "margin:2rem 0 .75rem 0;\
          \padding-bottom:.4rem;\
          \border-bottom:1px solid \
          \var(--md-sys-color-outline-variant,#44474e);\
          \letter-spacing:.01em"
      ]
      [ HH.text (groupTitle g) ]
  ]
    <> map (renderCard st) (groupContents g)

renderCard
  :: forall m
   . State
  -> BookKey
  -> H.ComponentHTML Action () m
renderCard st = case _ of
  N nk -> namedCard st nk
  F fk -> freeTextCard st fk

-- ---------------------------------------------------------------------------
-- Named cards

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
      [ namedFooter st key, perCardExport (N key) ]

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
    target = RemoveNamedT key tv
    nameForDisplay = case st.editing of
      Just other | other == eid -> st.draftName
      _ -> entryName entry
  in
    HH.div
      [ HP.style (rowStyle (st.confirmingRemove == Just target))
      ]
      [ HH.input
          [ HP.value nameForDisplay
          , HP.type_ HP.InputText
          , HP.placeholder "name"
          , HE.onFocus (\_ -> StartRename eid (entryName entry))
          , HE.onValueInput UpdateDraftName
          , HE.onBlur (\_ -> CommitRename)
          , HE.onKeyDown RenameKeyDown
          , HP.style
              "flex:1 1 auto;min-width:8rem;\
              \background:transparent;\
              \border:1px solid transparent;\
              \border-radius:4px;\
              \padding:.4rem .55rem;\
              \color:inherit;font:inherit;outline:none"
          ]
      , HH.a
          [ HP.href (namedLinkHref key tv)
          , HP.target "_blank"
          , HP.rel "noopener noreferrer"
          , HP.title tv
          , HP.style
              "flex:0 1 16rem;min-width:0;\
              \overflow:hidden;text-overflow:ellipsis;\
              \white-space:nowrap;padding:.4rem .25rem;\
              \font-family:'Roboto Mono',ui-monospace,monospace;\
              \font-size:13px;\
              \text-decoration:underline;color:inherit"
          ]
          [ HH.text tv ]
      , copyButton (st.recentlyCopied == Just tv) tv (copyLabel key)
      , deleteCluster st target (removeLabel key)
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
          map (freeTextRow st key) entries
      )
      [ freeTextFooter st key (Array.length entries)
      , perCardExport (F key)
      ]

freeTextRow
  :: forall m
   . State
  -> FreeTextBookKey
  -> String
  -> H.ComponentHTML Action () m
freeTextRow st key value =
  let
    target = RemoveFreeTextT key value
  in
    HH.div
      [ HP.style (rowStyle (st.confirmingRemove == Just target))
      ]
      [ HH.span
          [ HP.classes [ cn "field__input" ]
          , HP.style
              "flex:1 1 auto;min-width:0;display:block;\
              \padding:.5rem;background:transparent;\
              \overflow-wrap:anywhere;word-break:break-word"
          ]
          [ HH.text value ]
      , copyButton (st.recentlyCopied == Just value) value
          ("Copy " <> freeTextSingular key)
      , deleteCluster st target
          ("Remove " <> freeTextSingular key <> " entry")
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

-- ---------------------------------------------------------------------------
-- Export/import action rows (slice D)

-- | Per-card `Export` + `Copy` row.  Sits below the card's
-- | shape-specific footer (Add new / Clear all).  Wire-shape
-- | is the same bare per-book JSON the bundle import
-- | dispatches to a single book, so a single-card export
-- | drops directly into Lace / a Pinning Service / a script.
perCardExport
  :: forall m
   . BookKey
  -> H.ComponentHTML Action () m
perCardExport key =
  HH.div
    [ HP.style
        "display:flex;gap:.5rem;flex-wrap:wrap;\
        \align-items:center;\
        \border-top:1px solid var(--md-sys-color-outline-variant,#44474e);\
        \margin-top:.25rem;padding-top:.5rem;opacity:.85"
    ]
    [ HH.button
        [ HP.classes [ cn "btn", cn "btn--ghost" ]
        , HP.type_ HP.ButtonButton
        , HE.onClick (\_ -> ExportBookByKey key)
        ]
        [ HH.text "Export" ]
    , HH.button
        [ HP.classes [ cn "btn", cn "btn--ghost" ]
        , HP.type_ HP.ButtonButton
        , HE.onClick (\_ -> CopyBookByKey key)
        ]
        [ HH.text "Copy" ]
    ]

-- | Modal import dialog.  Rendered as a sibling of the
-- | page chrome so the backdrop covers the topbar too.
-- | Closed-state returns @[]@ so the parent's `<>` no-ops
-- | cleanly.
importDialogView
  :: forall m
   . State -> Array (H.ComponentHTML Action () m)
importDialogView st
  | not st.importDialog.open = []
  | otherwise =
      [ HH.div
          [ HP.style
              "position:fixed;inset:0;z-index:30;\
              \background:rgba(0,0,0,.45);\
              \display:flex;align-items:flex-start;\
              \justify-content:center;padding:3rem 1rem;\
              \overflow-y:auto"
          ]
          [ HH.div
              [ HP.classes [ cn "form-section" ]
              , HP.style
                  "background:var(--md-sys-color-surface-container,#22252b);\
                  \border:1px solid var(--md-sys-color-outline-variant,#44474e);\
                  \border-radius:8px;padding:1.25rem;\
                  \width:min(640px,100%);display:flex;\
                  \flex-direction:column;gap:.75rem;\
                  \box-shadow:0 12px 32px rgba(0,0,0,.35)"
              ]
              ( [ HH.h2
                    [ HP.classes
                        [ cn "form-section__title"
                        , cn "md-typescale-title-medium"
                        ]
                    ]
                    [ HH.text "Import books" ]
                , HH.p
                    [ HP.classes
                        [ cn "md-typescale-body-small" ]
                    , HP.style "opacity:.75"
                    ]
                    [ HH.text
                        "Accepts an `amaru.book.bundle.v1` \
                        \JSON document OR a bare array \
                        \(wallets / reference URIs / \
                        \strings — pick a destination for \
                        \the last)."
                    ]
                , HH.label
                    [ HP.classes [ cn "field" ] ]
                    [ HH.span
                        [ HP.classes [ cn "field__label" ] ]
                        [ HH.text "File" ]
                    , HH.input
                        [ HP.type_ HP.InputFile
                        , HP.id "books-import-file"
                        , HP.attr
                            (HH.AttrName "accept")
                            "application/json,.json"
                        , HE.onChange
                            (\_ -> ImportFilePicked)
                        , HP.classes [ cn "field__input" ]
                        ]
                    ]
                , HH.label
                    [ HP.classes [ cn "field" ] ]
                    [ HH.span
                        [ HP.classes [ cn "field__label" ] ]
                        [ HH.text "Or paste JSON" ]
                    , HH.textarea
                        [ HP.value st.importDialog.text
                        , HE.onValueInput UpdateImportText
                        , HP.classes
                            [ cn "field__input"
                            , cn "field__input--mono"
                            ]
                        , HP.attr
                            (HH.AttrName "rows")
                            "8"
                        , HP.style
                            "min-height:8rem;resize:vertical;\
                            \font-family:ui-monospace,\
                            \SFMono-Regular,monospace"
                        ]
                    ]
                , HH.label
                    [ HP.classes [ cn "field" ] ]
                    [ HH.span
                        [ HP.classes [ cn "field__label" ] ]
                        [ HH.text
                            "Destination (for bare \
                            \string arrays)"
                        ]
                    , HH.select
                        [ HE.onValueChange
                            UpdateImportDestination
                        , HP.classes [ cn "field__input" ]
                        ]
                        ( [ HH.option
                              [ HP.value "" ]
                              [ HH.text "— auto / N/A —" ]
                          ]
                            <>
                              map
                                ( \k ->
                                    HH.option
                                      [ HP.value
                                          (Import.freeTextSuffix k)
                                      , HP.selected
                                          ( st.importDialog.destination
                                              == Just k
                                          )
                                      ]
                                      [ HH.text
                                          (freeTextHeader k)
                                      ]
                                )
                                Import.allFreeTextKeys
                        )
                    ]
                ]
                  <> errorRow st.importDialog.error
                  <> previewRows st.importDialog.preview
                  <> dialogFooter st
              )
          ]
      ]

errorRow
  :: forall m
   . Maybe String -> Array (H.ComponentHTML Action () m)
errorRow = case _ of
  Nothing -> []
  Just msg ->
    [ HH.div
        [ HP.classes [ cn "field__error" ]
        , HP.style "padding:.5rem 0"
        ]
        [ HH.text msg ]
    ]

previewRows
  :: forall m
   . Maybe ImportPreview
  -> Array (H.ComponentHTML Action () m)
previewRows = case _ of
  Nothing -> []
  Just p ->
    [ HH.div
        [ HP.style "display:flex;flex-direction:column;gap:.4rem" ]
        ( [ HH.p
              [ HP.classes
                  [ cn "md-typescale-body-medium" ]
              ]
              [ HH.text "Diff — entries per book:" ]
          ]
            <> map diffRowView p.diffRows
            <> warningsView p.warnings
        )
    ]

diffRowView
  :: forall m. DiffRow -> H.ComponentHTML Action () m
diffRowView row =
  HH.div
    [ HP.style
        "display:flex;gap:1rem;\
        \font-family:ui-monospace,SFMono-Regular,monospace;\
        \font-size:.85rem"
    ]
    [ HH.span
        [ HP.style "flex:1" ]
        [ HH.text (bookKeyLabel row.book) ]
    , HH.span
        [ HP.style "opacity:.7" ]
        [ HH.text
            ( show row.beforeCount <> " → "
                <> show row.afterCount
            )
        ]
    ]

warningsView
  :: forall m
   . Array String -> Array (H.ComponentHTML Action () m)
warningsView ws
  | Array.null ws = []
  | otherwise =
      [ HH.div
          [ HP.style "margin-top:.5rem;opacity:.7" ]
          ( map
              ( \w ->
                  HH.p
                    [ HP.classes
                        [ cn "md-typescale-body-small" ]
                    ]
                    [ HH.text ("⚠ " <> w) ]
              )
              ws
          )
      ]

bookKeyLabel :: BookKey -> String
bookKeyLabel = case _ of
  N k -> namedHeader k
  F k -> freeTextHeader k

dialogFooter
  :: forall m
   . State -> Array (H.ComponentHTML Action () m)
dialogFooter st =
  [ HH.div
      [ HP.style
          "display:flex;gap:.5rem;justify-content:flex-end;\
          \margin-top:.5rem"
      ]
      ( case st.importDialog.preview of
          Nothing ->
            [ HH.button
                [ HP.classes [ cn "btn", cn "btn--ghost" ]
                , HP.type_ HP.ButtonButton
                , HE.onClick (\_ -> CloseImport)
                ]
                [ HH.text "Cancel" ]
            , HH.button
                [ HP.classes [ cn "btn", cn "btn--primary" ]
                , HP.type_ HP.ButtonButton
                , HE.onClick (\_ -> PreviewImport)
                ]
                [ HH.text "Preview" ]
            ]
          Just _ ->
            [ HH.button
                [ HP.classes [ cn "btn", cn "btn--ghost" ]
                , HP.type_ HP.ButtonButton
                , HE.onClick (\_ -> CloseImport)
                ]
                [ HH.text "Cancel" ]
            , HH.button
                [ HP.classes [ cn "btn", cn "btn--primary" ]
                , HP.type_ HP.ButtonButton
                , HE.onClick (\_ -> ConfirmImport)
                ]
                [ HH.text "Confirm" ]
            ]
      )
  ]

-- ---------------------------------------------------------------------------
-- Per-row affordances (slice E): clickable typed value,
-- copy icon-button (with 1s "✓" flash), guarded trash icon
-- that flips the row into a check / cancel pair.

rowStyle :: Boolean -> String
rowStyle confirming =
  "display:flex;gap:.5rem;align-items:center;\
  \padding:.25rem .25rem;\
  \border-bottom:1px solid \
  \var(--md-sys-color-outline-variant,#44474e);\
  \transition:background .15s ease" <>
    if confirming then ";background:rgba(186,26,26,.18)"
    else ""

-- | External-link URL for a named book entry.  Wallets go
-- | to Cardanoscan; reference URIs pass through if they
-- | already carry an `ipfs://` / `http(s)://` scheme,
-- | otherwise are sniffed as a bare CID and routed via the
-- | public IPFS gateway (best-effort — operators can swap
-- | the gateway by storing a full URL instead of a CID).
namedLinkHref :: NamedBookKey -> String -> String
namedLinkHref key value = case key of
  WalletsBook ->
    "https://cardanoscan.io/address/" <> value
  ReferenceUrisBook ->
    if hasUriScheme value then value
    else "https://ipfs.io/ipfs/" <> value

hasUriScheme :: String -> Boolean
hasUriScheme v =
  String.take 7 v == "ipfs://"
    || String.take 8 v == "https://"
    || String.take 7 v == "http://"

copyLabel :: NamedBookKey -> String
copyLabel = case _ of
  WalletsBook -> "Copy wallet address"
  ReferenceUrisBook -> "Copy CID"

removeLabel :: NamedBookKey -> String
removeLabel = case _ of
  WalletsBook -> "Remove wallet entry"
  ReferenceUrisBook -> "Remove reference URI"

-- | One copy icon-button.  Renders `content_copy` by
-- | default; when 'recently' is true it temporarily shows
-- | `check` to confirm the clipboard write landed.
copyButton
  :: forall m
   . Boolean
  -> String
  -> String
  -> H.ComponentHTML Action () m
copyButton recently val ariaLabel =
  mdIconButton
    (if recently then "check" else "content_copy")
    ariaLabel
    (CopyValue val)

-- | Trash icon-button OR the confirm/cancel pair, depending
-- | on whether 'state.confirmingRemove' targets THIS row.
deleteCluster
  :: forall m
   . State
  -> RemoveTarget
  -> String
  -> H.ComponentHTML Action () m
deleteCluster st target ariaLabel
  | st.confirmingRemove == Just target =
      HH.span
        [ HP.style "display:inline-flex;gap:.1rem" ]
        [ mdIconButton "check"
            ("Confirm: " <> ariaLabel)
            ConfirmRemove
        , mdIconButton "close"
            ("Cancel: " <> ariaLabel)
            CancelRemove
        ]
  | otherwise =
      mdIconButton "delete" ariaLabel (RequestRemove target)

-- | Thin Halogen wrapper for Material Web's
-- | `<md-icon-button>` + `<md-icon>` pair.  Plain `<button>`
-- | doesn't work here because MWC's icon-button registers
-- | as a custom element with its own click affordance and
-- | ripple — we'd lose the MD styling.
mdIconButton
  :: forall m
   . String
  -> String
  -> Action
  -> H.ComponentHTML Action () m
mdIconButton iconName ariaLabel action =
  HH.element (HH.ElemName "md-icon-button")
    [ HP.attr (HH.AttrName "aria-label") ariaLabel
    , HP.title ariaLabel
    , HE.onClick (\_ -> action)
    ]
    [ HH.element (HH.ElemName "md-icon") []
        [ HH.text iconName ]
    ]

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

  RequestRemove target ->
    H.modify_ \s -> s { confirmingRemove = Just target }

  CancelRemove ->
    H.modify_ \s -> s { confirmingRemove = Nothing }

  ConfirmRemove -> do
    st <- H.get
    case st.confirmingRemove of
      Just (RemoveNamedT key value) -> do
        H.liftEffect (removeNamed key value)
        books' <- H.liftEffect loadAllBooks
        H.modify_ \s -> s
          { books = books'
          , confirmingRemove = Nothing
          , editing = case s.editing of
              Just (EditingId k v)
                | k == key && v == value -> Nothing
              other -> other
          }
      Just (RemoveFreeTextT key value) -> do
        H.liftEffect (removeFreeText key value)
        books' <- H.liftEffect loadAllBooks
        H.modify_ \s -> s
          { books = books'
          , confirmingRemove = Nothing
          }
      Nothing -> pure unit

  CopyValue val -> do
    H.liftEffect (Clipboard.writeText val)
    H.modify_ \s -> s { recentlyCopied = Just val }
    _ <- H.fork do
      H.liftAff (delay (Milliseconds 1000.0))
      handleAction (ClearCopiedFlag val)
    pure unit

  ClearCopiedFlag val ->
    H.modify_ \s ->
      if s.recentlyCopied == Just val then
        s { recentlyCopied = Nothing }
      else s

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

  ExportAll -> do
    st <- H.get
    H.liftEffect do
      ts <- utcTimestamp
      _downloadText
        ("amaru-treasury-books-" <> ts <> ".json")
        (stringify (Import.encodeBundleJson st.books))

  CopyAll -> do
    st <- H.get
    H.liftEffect
      ( _writeClipboard
          (stringify (Import.encodeBundleJson st.books))
      )

  ExportBookByKey key -> do
    st <- H.get
    H.liftEffect do
      ts <- utcTimestamp
      case key of
        N nk ->
          _downloadText
            (Import.namedSuffix nk <> "-" <> ts <> ".json")
            ( stringify
                ( Import.encodeNamedBookJson
                    (namedEntries nk st.books)
                )
            )
        F fk ->
          _downloadText
            ( Import.freeTextSuffix fk <> "-" <> ts
                <> ".json"
            )
            ( stringify
                ( Import.encodeFreeTextBookJson
                    (freeTextEntries fk st.books)
                )
            )

  CopyBookByKey key -> do
    st <- H.get
    H.liftEffect case key of
      N nk ->
        _writeClipboard
          ( stringify
              ( Import.encodeNamedBookJson
                  (namedEntries nk st.books)
              )
          )
      F fk ->
        _writeClipboard
          ( stringify
              ( Import.encodeFreeTextBookJson
                  (freeTextEntries fk st.books)
              )
          )

  OpenImport ->
    H.modify_ \s -> s
      { importDialog = emptyImportDialog { open = true } }

  CloseImport ->
    H.modify_ \s -> s { importDialog = emptyImportDialog }

  UpdateImportText txt ->
    H.modify_ \s -> s
      { importDialog = s.importDialog
          { text = txt
          , error = Nothing
          , preview = Nothing
          }
      }

  ImportFilePicked -> do
    txt <-
      H.liftAff (readFileAff "#books-import-file")
    H.modify_ \s -> s
      { importDialog = s.importDialog
          { text = txt
          , error = Nothing
          , preview = Nothing
          }
      }

  UpdateImportDestination suffix ->
    H.modify_ \s -> s
      { importDialog = s.importDialog
          { destination = Import.freeTextSuffixToKey suffix
          , error = Nothing
          , preview = Nothing
          }
      }

  PreviewImport -> do
    st <- H.get
    let
      raw = String.trim st.importDialog.text
    if raw == "" then
      H.modify_ \s -> s
        { importDialog = s.importDialog
            { error =
                Just "paste JSON or pick a file first"
            , preview = Nothing
            }
        }
    else case jsonParser raw of
      Left err ->
        H.modify_ \s -> s
          { importDialog = s.importDialog
              { error =
                  Just ("invalid JSON: " <> err)
              , preview = Nothing
              }
          }
      Right j -> case Import.parseImport j of
        Left ierr ->
          H.modify_ \s -> s
            { importDialog = s.importDialog
                { error =
                    Just (Import.describeError ierr)
                , preview = Nothing
                }
            }
        Right payload ->
          case
            Import.merge
              payload
              st.importDialog.destination
              st.books
            of
            Left ierr ->
              H.modify_ \s -> s
                { importDialog = s.importDialog
                    { error =
                        Just (Import.describeError ierr)
                    , preview = Nothing
                    }
                }
            Right after -> do
              let
                warnings = case payload of
                  Import.BundlePayload bd -> bd.warnings
                  _ -> []
              H.modify_ \s -> s
                { importDialog = s.importDialog
                    { error = Nothing
                    , preview = Just
                        { afterBooks: after
                        , diffRows: Import.diff st.books after
                        , warnings
                        }
                    }
                }

  ConfirmImport -> do
    st <- H.get
    case st.importDialog.preview of
      Just preview -> do
        let after = preview.afterBooks
        H.liftEffect do
          replaceNamed WalletsBook after.wallets
          replaceNamed ReferenceUrisBook after.referenceUris
          replaceFreeText
            DescriptionsBook
            after.descriptions
          replaceFreeText
            JustificationsBook
            after.justifications
          replaceFreeText
            DestinationLabelsBook
            after.destinationLabels
          replaceFreeText
            ValidityHoursBook
            after.validityHours
          replaceFreeText
            SlippageBpsBook
            after.slippageBps
          replaceFreeText
            SplitCountsBook
            after.splitCounts
          replaceFreeText
            ReferenceTypesBook
            after.referenceTypes
          replaceFreeText
            ReferenceLabelsBook
            after.referenceLabels
        books' <- H.liftEffect loadAllBooks
        H.modify_ \s -> s
          { books = books'
          , importDialog = emptyImportDialog
          }
      Nothing -> pure unit

-- ---------------------------------------------------------------------------
-- File-picker FFI bridged into Aff via `makeAff`

readFileAff :: String -> Aff String
readFileAff selector = makeAff \cb -> do
  _readFileFromInput
    selector
    (cb <<< Right)
    (cb <<< Left)
  pure nonCanceler

foreign import _downloadText
  :: String -> String -> Effect Unit

foreign import _writeClipboard :: String -> Effect Unit

foreign import _readFileFromInput
  :: String
  -> (String -> Effect Unit)
  -> (Error -> Effect Unit)
  -> Effect Unit

-- | UTC timestamp formatted @YYYY-MM-DDTHH-MM-SSZ@ — colons
-- | replaced with dashes so the filename works on Windows
-- | too (contract per FR-018).
utcTimestamp :: Effect String
utcTimestamp = do
  inst <- now
  let
    dt = toDateTime inst
    d = date dt
    t = time dt
    yy = show (fromEnum (year d))
    mm = pad2 (fromEnum (month d))
    dd = pad2 (fromEnum (day d))
    hh = pad2 (fromEnum (hour t))
    mi = pad2 (fromEnum (minute t))
    ss = pad2 (fromEnum (second t))
  pure
    ( yy <> "-" <> mm <> "-" <> dd <> "T"
        <> hh
        <> "-"
        <> mi
        <> "-"
        <> ss
        <> "Z"
    )

pad2 :: Int -> String
pad2 n
  | n < 10 = "0" <> show n
  | otherwise = show n

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
