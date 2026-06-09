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

import Data.Argonaut.Core (Json, jsonEmptyObject, stringify)
import Data.Argonaut.Core as Argonaut
import Foreign.Object as FO
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.DateTime (date, time, day, hour, minute, month, second, year)
import Data.DateTime.Instant (toDateTime)
import Data.Either (Either(..))
import Data.Enum (fromEnum)
import Data.Maybe (Maybe(..))
import Data.Set (Set)
import Data.Set as Set
import Data.String as String
import Format (truncateMid)
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

import BooksPage.Import (DiffRow, ImportDestination(..))
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
  , autoSaveName
  , clear
  , loadAutoSave
  , loadFreeText
  , loadNamed
  , loadNamedVisible
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
  , references :: Array NamedEntry
  , descriptions :: Array String
  , justifications :: Array String
  , destinationLabels :: Array String
  , validityHours :: Array String
  , slippageBps :: Array String
  , splitCounts :: Array String
  -- #288 — operator-curated drafts + auto-captured history
  -- of /operate form snapshots.  Loaded via
  -- 'loadNamedVisible' so the reserved '__autosave__' slot
  -- never reaches /books — only entries the operator
  -- explicitly named (drafts) OR the on-build-success
  -- write produced (history) are rendered.
  , operateDrafts :: Array NamedEntry
  , operateHistory :: Array NamedEntry
  }

emptyBooks :: Books
emptyBooks =
  { wallets: []
  , references: []
  , descriptions: []
  , justifications: []
  , destinationLabels: []
  , validityHours: []
  , slippageBps: []
  , splitCounts: []
  , operateDrafts: []
  , operateHistory: []
  }

loadAllBooks :: Effect Books
loadAllBooks = do
  ws <- loadNamed WalletsBook
  rs <- loadNamed ReferencesBook
  ds <- loadFreeText DescriptionsBook
  js <- loadFreeText JustificationsBook
  dl <- loadFreeText DestinationLabelsBook
  vh <- loadFreeText ValidityHoursBook
  sb <- loadFreeText SlippageBpsBook
  sc <- loadFreeText SplitCountsBook
  od <- loadNamedVisible OperateDraftsBook
  oh <- loadNamedVisible OperateHistoryBook
  pure
    { wallets: ws
    , references: rs
    , descriptions: ds
    , justifications: js
    , destinationLabels: dl
    , validityHours: vh
    , slippageBps: sb
    , splitCounts: sc
    , operateDrafts: od
    , operateHistory: oh
    }

allBooksEmpty :: Books -> Boolean
allBooksEmpty b =
  Array.null b.wallets
    && Array.null b.references
    && Array.null b.descriptions
    && Array.null b.justifications
    && Array.null b.destinationLabels
    && Array.null b.validityHours
    && Array.null b.slippageBps
    && Array.null b.splitCounts
    && Array.null b.operateDrafts
    && Array.null b.operateHistory

freeTextEntries :: FreeTextBookKey -> Books -> Array String
freeTextEntries k b = case k of
  DescriptionsBook -> b.descriptions
  JustificationsBook -> b.justifications
  DestinationLabelsBook -> b.destinationLabels
  ValidityHoursBook -> b.validityHours
  SlippageBpsBook -> b.slippageBps
  SplitCountsBook -> b.splitCounts

namedEntries :: NamedBookKey -> Books -> Array NamedEntry
namedEntries k b = case k of
  WalletsBook -> b.wallets
  ReferencesBook -> b.references
  OperateDraftsBook -> b.operateDrafts
  OperateHistoryBook -> b.operateHistory

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
  , destination :: Maybe ImportDestination
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
  , draftLabel :: String
  , draftType :: String
  , clearConfirm :: Maybe FreeTextBookKey
  , theme :: Theme.Theme
  , importDialog :: ImportDialogState
  -- #338 SB4 — one-line summary shown after a successful
  -- import (entry counts per affected book), cleared the
  -- next time the import dialog opens.
  , importSummary :: Maybe String
  , confirmingRemove :: Maybe RemoveTarget
  , recentlyCopied :: Maybe String
  -- #289 slice G — groups whose disclosure is currently
  -- collapsed.  Populated at 'Initialize' (and after every
  -- book mutation) with every group where ALL cards are
  -- empty, then toggled by the operator clicking the
  -- one-line disclosure.  Non-empty groups never appear in
  -- this set — they always render normally.
  , collapsedGroups :: Set BooksGroup
  }

initialState :: State
initialState =
  { books: emptyBooks
  , editing: Nothing
  , adding: Nothing
  , draftName: ""
  , draftValue: ""
  , draftLabel: ""
  , draftType: ""
  , clearConfirm: Nothing
  , theme: Theme.Dark
  , importDialog: emptyImportDialog
  , importSummary: Nothing
  , confirmingRemove: Nothing
  , recentlyCopied: Nothing
  , collapsedGroups: Set.empty
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
  | UpdateDraftLabel String
  | UpdateDraftType String
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
  -- #289 slice G — toggle a group's empty-state disclosure.
  | ToggleGroup BooksGroup

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
              <> importSummaryView st
              <> emptyStateNotice st
              <> booksGroupSection st
          )
      , Shell.siteFooter { buildIdentityLine: "" }
      ]
        <> importDialogView st
    )

-- | #338 SB4 — post-import success banner.  Empty until an
-- | import completes; cleared again when the dialog reopens.
importSummaryView
  :: forall m. State -> Array (H.ComponentHTML Action () m)
importSummaryView st = case st.importSummary of
  Just msg ->
    [ HH.div
        [ HP.classes [ cn "field__hint", cn "books-import-summary" ]
        , HP.attr (HH.AttrName "role") "status"
        ]
        [ HH.text ("✓ " <> msg) ]
    ]
  Nothing -> []

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
        , HP.title
            "Merge a books bundle (JSON exported from another \
            \browser or teammate) into your saved values."
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
  = Drafts
  | Identities
  | References
  | RationaleText
  | BuildParameters

derive instance eqBooksGroup :: Eq BooksGroup
derive instance ordBooksGroup :: Ord BooksGroup

-- #288 — 'Drafts' goes at the TOP: it carries the
-- highest-value operator state (recurring transaction
-- templates + the full Build history).  Identities /
-- references / rationale / build-parameter books stay in
-- their previous slice-F order below.
allGroups :: Array BooksGroup
allGroups =
  [ Drafts
  , Identities
  , References
  , RationaleText
  , BuildParameters
  ]

groupTitle :: BooksGroup -> String
groupTitle = case _ of
  Drafts -> "Drafts"
  Identities -> "Identities"
  References -> "References"
  RationaleText -> "Rationale text"
  BuildParameters -> "Build parameters"

-- | Whether the per-book entry list for the given key is
-- | empty.  Used by 'groupIsEmpty' and by 'perCardExport'
-- | to gate the Copy / Export `aria-disabled` state.
bookKeyIsEmpty :: BookKey -> Books -> Boolean
bookKeyIsEmpty key b = case key of
  N nk -> Array.null (namedEntries nk b)
  F fk -> Array.null (freeTextEntries fk b)

-- | A group is empty when every book under it is empty.
-- | Drives the slice-G one-line disclosure: instead of
-- | rendering N stacked "(no entries yet)" cards, the
-- | whole group collapses behind a single `<group> · N
-- | books empty · expand` button.
groupIsEmpty :: BooksGroup -> Books -> Boolean
groupIsEmpty g b =
  Array.all (\k -> bookKeyIsEmpty k b) (groupContents g)

-- | Recompute the collapsed-groups set after a book
-- | mutation: any group that is NOW empty is added to the
-- | set so its disclosure starts in the collapsed state.
-- | Groups already in the set stay (preserves the
-- | operator's prior toggle).  Non-empty groups are not
-- | removed — they simply don't render the disclosure,
-- | so set membership is moot.
collapseAllEmpty :: Books -> Set BooksGroup -> Set BooksGroup
collapseAllEmpty b s =
  Array.foldl
    ( \acc g ->
        if groupIsEmpty g b then Set.insert g acc
        else acc
    )
    s
    allGroups

groupContents :: BooksGroup -> Array BookKey
groupContents = case _ of
  Drafts ->
    [ N OperateDraftsBook
    , N OperateHistoryBook
    ]
  Identities ->
    [ N WalletsBook ]
  References ->
    [ N ReferencesBook ]
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
  let
    cards = groupContents g
    allEmpty = groupIsEmpty g st.books
    collapsed = Set.member g st.collapsedGroups
    -- The slice-G disclosure only renders when EVERY card
    -- in the group is empty.  Non-empty groups keep the
    -- pre-slice-G normal heading + cards layout.
  in
    if allEmpty then
      [ groupDisclosure g (Array.length cards) collapsed ]
        <>
          ( if collapsed then []
            else map (renderCard st) cards
          )
    else
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
        <> map (renderCard st) cards

-- | #289 slice G — one-line disclosure replacing the
-- | normal group heading when every card in the group is
-- | empty.  Clicking the button toggles its membership in
-- | 'state.collapsedGroups'.
groupDisclosure
  :: forall m
   . BooksGroup
  -> Int
  -> Boolean
  -> H.ComponentHTML Action () m
groupDisclosure g cardCount collapsed =
  let
    arrow = if collapsed then "▸ " else "▾ "
    plural = if cardCount == 1 then "" else "s"
    suffix = if collapsed then "expand" else "collapse"
    text =
      arrow
        <> groupTitle g
        <> " · "
        <> show cardCount
        <> " book"
        <> plural
        <> " empty · "
        <> suffix
  in
    HH.button
      [ HP.classes
          [ cn "books-group"
          , cn "books-group--empty"
          , cn "group-disclosure"
          ]
      , HP.type_ HP.ButtonButton
      , HP.attr (HH.AttrName "aria-expanded")
          (if collapsed then "false" else "true")
      , HE.onClick (\_ -> ToggleGroup g)
      ]
      [ HH.text text ]

renderCard
  :: forall m
   . State
  -> BookKey
  -> H.ComponentHTML Action () m
renderCard st = case _ of
  N OperateDraftsBook -> snapshotCard st OperateDraftsBook
  N OperateHistoryBook -> snapshotCard st OperateHistoryBook
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
      [ namedFooter st key
      , perCardExport (N key) (Array.null entries)
      ]

-- ---------------------------------------------------------------------------
-- Snapshot cards (#288 — Drafts + History)
--
-- Snapshot books share an entry shape but render slightly
-- differently from each other:
--
--   * Drafts: operator-named, inline-rename-on-blur input.
--   * History: timestamp-named, read-only span (timestamps
--     are content-addressable; renaming would be confusing).
--
-- Both share the snapshot-summary middle cell and the
-- copy + guarded-trash right-side cluster.  Neither carries
-- an `Add new` button — drafts come from /operate's
-- `Save as draft…` editor, history from on-build append.

snapshotCard
  :: forall m
   . State
  -> NamedBookKey
  -> H.ComponentHTML Action () m
snapshotCard st key =
  let
    entries = namedEntries key st.books
  in
    bookCard (namedHeader key)
      ( if Array.null entries then
          [ emptyCardCaption (namedEmpty key) ]
        else
          map (snapshotEntryRow st key) entries
      )
      [ perCardExport (N key) (Array.null entries) ]

snapshotEntryRow
  :: forall m
   . State
  -> NamedBookKey
  -> NamedEntry
  -> H.ComponentHTML Action () m
snapshotEntryRow st key entry =
  let
    tv = namedTypedValue entry
    eid = EditingId key tv
    target = RemoveNamedT key tv
    snap = entrySnapshot entry
    snapJson = stringify snap
    nameCell = case key of
      OperateDraftsBook -> draftNameCell st eid entry
      _ -> readonlyNameCell entry
  in
    HH.div
      [ HP.style (rowStyle (st.confirmingRemove == Just target))
      ]
      [ nameCell
      , HH.span
          [ HP.title snapJson
          , HP.style
              "flex:1 1 auto;min-width:0;\
              \overflow:hidden;text-overflow:ellipsis;\
              \white-space:nowrap;\
              \padding:.4rem .25rem;\
              \font-size:13px;opacity:.85;\
              \font-family:'Roboto Mono',ui-monospace,monospace"
          ]
          [ HH.text (snapshotSummary snap) ]
      , copyButton
          (st.recentlyCopied == Just snapJson)
          snapJson
          (copyLabel key)
      , deleteCluster st target (removeLabel key)
      ]

-- | Drafts cell: editable name input wired into the shared
-- | rename flow (`StartRename` / `UpdateDraftName` /
-- | `CommitRename`).  Reuses the same blur-commits and
-- | Enter-commits behaviour as the wallet / reference
-- | name inputs.
draftNameCell
  :: forall m
   . State
  -> EditingId
  -> NamedEntry
  -> H.ComponentHTML Action () m
draftNameCell st eid entry =
  let
    nameForDisplay = case st.editing of
      Just other | other == eid -> st.draftName
      _ -> entryName entry
  in
    HH.input
      [ HP.value nameForDisplay
      , HP.type_ HP.InputText
      , HP.placeholder "name"
      , HE.onFocus (\_ -> StartRename eid (entryName entry))
      , HE.onValueInput UpdateDraftName
      , HE.onBlur (\_ -> CommitRename)
      , HE.onKeyDown RenameKeyDown
      , HP.style
          "flex:0 1 14rem;min-width:8rem;\
          \background:transparent;\
          \border:1px solid transparent;\
          \border-radius:4px;\
          \padding:.4rem .55rem;\
          \color:inherit;font:inherit;outline:none"
      ]

-- | History cell: read-only timestamp span.  No <input>
-- | (DOM-visible attribute the smoke checks for).
readonlyNameCell
  :: forall m. NamedEntry -> H.ComponentHTML Action () m
readonlyNameCell entry =
  HH.span
    [ HP.style
        "flex:0 1 14rem;min-width:8rem;\
        \padding:.4rem .55rem;\
        \font-family:'Roboto Mono',ui-monospace,monospace;\
        \font-size:13px;opacity:.9"
    ]
    [ HH.text (entryName entry) ]

-- | Project the snapshot blob out of a 'NamedEntry'.  Only
-- | snapshot entries carry one; the legacy variants return
-- | an empty object so the summary cell stays defensive.
entrySnapshot :: NamedEntry -> Json
entrySnapshot = case _ of
  OperateSnapshotE s -> s.snapshot
  _ -> jsonEmptyObject

-- | One-line preview of an /operate snapshot.  Format:
-- |
-- |   `<mode> · <scope> · <beneficiary trunc> · <amount> USDM`
-- |
-- | Missing fields render as `—` (em dash) so each segment
-- | stays visually present.  Reads keys from slice-B's
-- | actual on-disk schema (`beneficiaryAddr`, plus
-- | `disburseAmount` for disburse mode and `usdm` for swap
-- | mode).
snapshotSummary :: Json -> String
snapshotSummary j = case Argonaut.toObject j of
  Nothing -> "—"
  Just o ->
    let
      getStr k = FO.lookup k o >>= Argonaut.toString
      mode = orDash (getStr "mode")
      scope = orDash (getStr "scope")
      bnf = case getStr "beneficiaryAddr" of
        Just b | b /= "" -> truncateMid 12 6 b
        _ -> "—"
      amt = case mode of
        "disburse" -> orDash (nonEmpty (getStr "disburseAmount"))
        "swap" -> orDash (nonEmpty (getStr "usdm"))
        _ -> "—"
    in
      mode
        <> " · "
        <> scope
        <> " · "
        <> bnf
        <> " · "
        <> amt
        <> " USDM"

orDash :: Maybe String -> String
orDash = case _ of
  Just s -> s
  Nothing -> "—"

nonEmpty :: Maybe String -> Maybe String
nonEmpty = case _ of
  Just "" -> Nothing
  other -> other

-- | #338 SB4 — one-line post-import summary: how many entries
-- | were added, across how many books, and how many parse
-- | warnings were surfaced.
importSummaryText :: Int -> Int -> Int -> String
importSummaryText added nBooks warns =
  "Imported "
    <> show added
    <> plural added " new entry" " new entries"
    <> " across "
    <> show nBooks
    <> plural nBooks " book" " books"
    <> if warns > 0 then
         " (" <> show warns <> plural warns " warning" " warnings" <> ")"
       else ""
  where
  plural n one many = if n == 1 then one else many

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
    -- Slice G: references show an extra label cell
    -- between the name input and the URI link.  Wallets
    -- have no label, so the wallet row stays as
    -- [name|link|copy|trash].
    extraCells = case entry of
      ReferenceE r ->
        [ HH.span
            [ HP.title r.label
            , HP.style
                "flex:0 1 12rem;min-width:0;\
                \overflow:hidden;text-overflow:ellipsis;\
                \white-space:nowrap;padding:.4rem .25rem;\
                \opacity:.85;font-size:13px"
            ]
            [ HH.text
                ( if r.label == "" then "—" else r.label )
            ]
        ]
      _ -> []
  in
    HH.div
      [ HP.style (rowStyle (st.confirmingRemove == Just target))
      ]
      ( [ HH.input
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
        ]
          <> extraCells
          <>
            [ HH.a
                [ HP.href (namedLinkHref key tv)
                , HP.target "_blank"
                , HP.rel "noopener noreferrer"
                , HP.title tv
                , HP.style
                    "flex:0 1 14rem;min-width:0;\
                    \overflow:hidden;text-overflow:ellipsis;\
                    \white-space:nowrap;\
                    \padding:.4rem .25rem;\
                    \font-family:'Roboto Mono',ui-monospace,monospace;\
                    \font-size:13px;\
                    \text-decoration:underline;color:inherit"
                ]
                [ HH.text tv ]
            , copyButton
                (st.recentlyCopied == Just tv)
                tv
                (copyLabel key)
            , deleteCluster st target (removeLabel key)
            ]
      )

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
  let
    fields = case key of
      WalletsBook ->
        [ draftNameInput st "Friendly name"
        , draftValueInput st (namedValuePlaceholder key)
        ]
      ReferencesBook ->
        [ draftNameInput st "Friendly name"
        , draftLabelInput st
            "Contract - CRYPTO ACCOUNTING GROUP"
        , draftValueInput st "ipfs://bafy…"
        , draftTypeInput st "Other"
        ]
      -- #288 slice A: snapshot books are populated via
      -- /operate's `Save as draft…` editor (slice B) and
      -- the on-Build auto-append (slice B); /books has no
      -- Add-new affordance for them, so this branch is
      -- unreachable until slice C wires it.
      OperateDraftsBook -> []
      OperateHistoryBook -> []
    actions =
      [ HH.button
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
  in
    HH.div
      [ HP.style
          "display:flex;flex-wrap:wrap;\
          \gap:.5rem;align-items:center;\
          \padding:.5rem .25rem;\
          \border-top:1px solid \
          \var(--md-sys-color-outline-variant,#44474e)"
      ]
      (fields <> actions)

draftNameInput
  :: forall m
   . State
  -> String
  -> H.ComponentHTML Action () m
draftNameInput st placeholder =
  HH.input
    [ HP.value st.draftName
    , HP.type_ HP.InputText
    , HP.classes [ cn "field__input" ]
    , HP.placeholder placeholder
    , HE.onValueInput UpdateDraftName
    , HE.onKeyDown AddKeyDown
    , HP.style "flex:1 1 12rem;min-width:8rem"
    ]

draftValueInput
  :: forall m
   . State
  -> String
  -> H.ComponentHTML Action () m
draftValueInput st placeholder =
  HH.input
    [ HP.value st.draftValue
    , HP.type_ HP.InputText
    , HP.classes [ cn "field__input", cn "field__input--mono" ]
    , HP.placeholder placeholder
    , HE.onValueInput UpdateDraftValue
    , HE.onKeyDown AddKeyDown
    , HP.style "flex:1 1 14rem;min-width:8rem"
    ]

draftLabelInput
  :: forall m
   . State
  -> String
  -> H.ComponentHTML Action () m
draftLabelInput st placeholder =
  HH.input
    [ HP.value st.draftLabel
    , HP.type_ HP.InputText
    , HP.classes [ cn "field__input" ]
    , HP.placeholder placeholder
    , HE.onValueInput UpdateDraftLabel
    , HE.onKeyDown AddKeyDown
    , HP.style "flex:1 1 12rem;min-width:8rem"
    ]

draftTypeInput
  :: forall m
   . State
  -> String
  -> H.ComponentHTML Action () m
draftTypeInput st placeholder =
  HH.input
    [ HP.value st.draftType
    , HP.type_ HP.InputText
    , HP.classes [ cn "field__input" ]
    , HP.placeholder placeholder
    , HE.onValueInput UpdateDraftType
    , HE.onKeyDown AddKeyDown
    , HP.style "flex:0 1 8rem;min-width:6rem"
    ]

namedHeader :: NamedBookKey -> String
namedHeader = case _ of
  WalletsBook -> "Wallets"
  ReferencesBook -> "References"
  -- #288 slice A: Drafts / History card headers are rendered
  -- by slice C; these labels are the canonical names from
  -- the spec so iterating taxonomy helpers stays stable.
  OperateDraftsBook -> "Drafts"
  OperateHistoryBook -> "History"

namedEmpty :: NamedBookKey -> String
namedEmpty = case _ of
  WalletsBook ->
    "No wallets yet.  Click + Add new or submit a build on \
    \/operate."
  ReferencesBook ->
    "No references yet.  Click + Add new or submit a \
    \build on /operate."
  OperateDraftsBook ->
    "No drafts yet.  Use 'Save as draft…' on /operate to \
    \capture the current form."
  OperateHistoryBook ->
    "No history yet.  Every successful Build on /operate \
    \will appear here, indexed by date."

namedValuePlaceholder :: NamedBookKey -> String
namedValuePlaceholder = case _ of
  WalletsBook -> "addr1q…"
  ReferencesBook -> "ipfs://bafy…"
  -- #288 slice A: snapshot books have no manual value
  -- input on /books; populated via /operate.
  OperateDraftsBook -> ""
  OperateHistoryBook -> ""

entryName :: NamedEntry -> String
entryName = case _ of
  WalletE w -> w.name
  ReferenceE r -> r.name
  OperateSnapshotE s -> s.name

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
      , perCardExport (F key) (Array.null entries)
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

freeTextSingular :: FreeTextBookKey -> String
freeTextSingular = case _ of
  DescriptionsBook -> "descriptions"
  JustificationsBook -> "justifications"
  DestinationLabelsBook -> "destination labels"
  ValidityHoursBook -> "validity-hours entries"
  SlippageBpsBook -> "slippage entries"
  SplitCountsBook -> "split counts"

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
-- |
-- | #289 slice G — when the card is empty (zero entries),
-- | the Copy + Export buttons render with `aria-disabled="true"`
-- | and the matching CSS skin (faded + `cursor: not-allowed`
-- | + `pointer-events: none`).  An empty export would
-- | produce a bare `[]` bundle; an empty copy would put `[]`
-- | on the clipboard.  Neither is useful, so the affordance
-- | is visually de-emphasised but the buttons stay in DOM
-- | (preserves a11y tree continuity).
perCardExport
  :: forall m
   . BookKey
  -> Boolean
  -> H.ComponentHTML Action () m
perCardExport key isEmpty =
  let
    disabledAttrs =
      if isEmpty then
        [ HP.attr (HH.AttrName "aria-disabled") "true"
        , HP.attr (HH.AttrName "tabindex") "-1"
        ]
      else []
  in
    HH.div
      [ HP.style
          "display:flex;gap:.5rem;flex-wrap:wrap;\
          \align-items:center;\
          \border-top:1px solid var(--md-sys-color-outline-variant,#44474e);\
          \margin-top:.25rem;padding-top:.5rem;opacity:.85"
      ]
      [ HH.button
          ( [ HP.classes [ cn "btn", cn "btn--ghost" ]
            , HP.type_ HP.ButtonButton
            , HE.onClick (\_ -> ExportBookByKey key)
            ]
              <> disabledAttrs
          )
          [ HH.text "Export" ]
      , HH.button
          ( [ HP.classes [ cn "btn", cn "btn--ghost" ]
            , HP.type_ HP.ButtonButton
            , HE.onClick (\_ -> CopyBookByKey key)
            ]
              <> disabledAttrs
          )
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
                            "Destination (for bare arrays — \
                            \free-text strings OR \
                            \{name, snapshot} entries)"
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
                                              == Just (DestFreeText k)
                                          )
                                      ]
                                      [ HH.text
                                          (freeTextHeader k)
                                      ]
                                )
                                Import.allFreeTextKeys
                            <>
                              map
                                ( \k ->
                                    HH.option
                                      [ HP.value
                                          (Import.namedSuffix k)
                                      , HP.selected
                                          ( st.importDialog.destination
                                              == Just (DestSnapshot k)
                                          )
                                      ]
                                      [ HH.text
                                          (namedHeader k)
                                      ]
                                )
                                Import.allSnapshotKeys
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
  ReferencesBook ->
    if hasUriScheme value then value
    else "https://ipfs.io/ipfs/" <> value
  -- #288 slice A: snapshot entries have no clickable URI;
  -- slice C renders them with a non-link summary span.
  OperateDraftsBook -> ""
  OperateHistoryBook -> ""

hasUriScheme :: String -> Boolean
hasUriScheme v =
  String.take 7 v == "ipfs://"
    || String.take 8 v == "https://"
    || String.take 7 v == "http://"

copyLabel :: NamedBookKey -> String
copyLabel = case _ of
  WalletsBook -> "Copy wallet address"
  ReferencesBook -> "Copy reference URI"
  -- #288 slice A: snapshot copy labels finalised in slice C.
  OperateDraftsBook -> "Copy draft snapshot"
  OperateHistoryBook -> "Copy history snapshot"

removeLabel :: NamedBookKey -> String
removeLabel = case _ of
  WalletsBook -> "Remove wallet entry"
  ReferencesBook -> "Remove reference entry"
  -- #288 slice A: snapshot remove labels finalised in slice C.
  OperateDraftsBook -> "Remove draft"
  OperateHistoryBook -> "Remove history entry"

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
    H.modify_ \s -> s
      { theme = t
      , books = books
      , collapsedGroups = collapseAllEmpty books Set.empty
      }

  ToggleGroup g ->
    H.modify_ \s -> s
      { collapsedGroups =
          if Set.member g s.collapsedGroups then
            Set.delete g s.collapsedGroups
          else
            Set.insert g s.collapsedGroups
      }

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
          , collapsedGroups =
              collapseAllEmpty books' s.collapsedGroups
          }
      Just (RemoveFreeTextT key value) -> do
        H.liftEffect (removeFreeText key value)
        books' <- H.liftEffect loadAllBooks
        H.modify_ \s -> s
          { books = books'
          , confirmingRemove = Nothing
          , collapsedGroups =
              collapseAllEmpty books' s.collapsedGroups
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
          , collapsedGroups =
              collapseAllEmpty books' s.collapsedGroups
          }
      Nothing -> pure unit

  CancelClearFreeText ->
    H.modify_ \s -> s { clearConfirm = Nothing }

  OpenAddNamed key ->
    H.modify_ \s -> s
      { adding = Just key
      , draftName = ""
      , draftValue = ""
      , draftLabel = ""
      , draftType = ""
      }

  UpdateDraftValue s ->
    H.modify_ \st -> st { draftValue = s }

  UpdateDraftLabel s ->
    H.modify_ \st -> st { draftLabel = s }

  UpdateDraftType s ->
    H.modify_ \st -> st { draftType = s }

  CommitAdd -> do
    st <- H.get
    case st.adding of
      Just key
        | String.trim st.draftValue /= "" -> do
            let
              entry = mkNamedEntry
                { key
                , rawName: st.draftName
                , value: st.draftValue
                , label: st.draftLabel
                , refType: st.draftType
                }
            H.liftEffect (addNamed key entry)
            books' <- H.liftEffect loadAllBooks
            H.modify_ \s -> s
              { books = books'
              , adding = Nothing
              , draftName = ""
              , draftValue = ""
              , draftLabel = ""
              , draftType = ""
              , collapsedGroups =
                  collapseAllEmpty books' s.collapsedGroups
              }
      _ -> pure unit

  CancelAdd ->
    H.modify_ \s -> s
      { adding = Nothing
      , draftName = ""
      , draftValue = ""
      , draftLabel = ""
      , draftType = ""
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
      ( Clipboard.writeText
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
        Clipboard.writeText
          ( stringify
              ( Import.encodeNamedBookJson
                  (namedEntries nk st.books)
              )
          )
      F fk ->
        Clipboard.writeText
          ( stringify
              ( Import.encodeFreeTextBookJson
                  (freeTextEntries fk st.books)
              )
          )

  OpenImport ->
    H.modify_ \s -> s
      { importDialog = emptyImportDialog { open = true }
      , importSummary = Nothing
      }

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
          { destination = Import.destinationFromSuffix suffix
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
          replaceNamed ReferencesBook after.references
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
        -- #288 — snapshot books.  The merge dropped any
        -- '__autosave__' from the imported payload (FR-002:
        -- a bundle from another browser must not overwrite
        -- the local in-progress draft).  But `replaceNamed`
        -- wipes the on-disk array wholesale, so we read the
        -- local autosave slot first and re-add it after the
        -- replace.
        localAutoSave <- H.liftEffect
          (loadAutoSave OperateDraftsBook)
        H.liftEffect do
          replaceNamed OperateDraftsBook
            after.operateDrafts
          case localAutoSave of
            Just e -> addNamed OperateDraftsBook e
            Nothing -> pure unit
          replaceNamed OperateHistoryBook
            after.operateHistory
        books' <- H.liftEffect loadAllBooks
        let
          added =
            Array.foldl
              (\acc d -> acc + (d.afterCount - d.beforeCount))
              0
              preview.diffRows
          nBooks =
            Array.length
              ( Array.filter
                  (\d -> d.afterCount > d.beforeCount)
                  preview.diffRows
              )
          warns = Array.length preview.warnings
        H.modify_ \s -> s
          { books = books'
          , importDialog = emptyImportDialog
          , importSummary = Just (importSummaryText added nBooks warns)
          , collapsedGroups =
              collapseAllEmpty books' s.collapsedGroups
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

-- | Build a 'NamedEntry' for 'addNamed' given the key +
-- | the four possible draft fields.  Wallets only consume
-- | `rawName` + `value`; references consume the full
-- | triple (`label`, `value` aka uri, `refType`) too.
-- | A blank name falls back to the typed value so the
-- | dropdown still has something to display.
mkNamedEntry
  :: { key :: NamedBookKey
     , rawName :: String
     , value :: String
     , label :: String
     , refType :: String
     }
  -> NamedEntry
mkNamedEntry d =
  let
    name =
      if String.trim d.rawName == "" then d.value
      else d.rawName
  in
    case d.key of
      WalletsBook ->
        WalletE { name, address: d.value }
      ReferencesBook ->
        ReferenceE
          { name
          , label: d.label
          , uri: d.value
          , refType: d.refType
          }
      -- #288 slice A: the /books `Add new` button isn't
      -- rendered for snapshot books (no manual entry).
      -- Slice C wires the real path; this branch is dead
      -- code in slice A but keeps mkNamedEntry total.
      OperateDraftsBook ->
        OperateSnapshotE
          { name, snapshot: jsonEmptyObject }
      OperateHistoryBook ->
        OperateSnapshotE
          { name, snapshot: jsonEmptyObject }
