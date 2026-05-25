-- | #267 — Pure parse + merge + diff logic for the
-- | `/books` import path.  Carries no Halogen / Effect /
-- | FFI dependencies so it can be reasoned about
-- | independently of the surrounding page component.
-- |
-- | The auto-dispatch table (FR-016):
-- |
-- |   * Object with @kind = "amaru.book.bundle.v1"@ + a
-- |     @books@ map → 'BundlePayload'.  Unknown keys
-- |     surface as warnings; per-book parse failures fall
-- |     back to empty (atomic-reset spirit, scoped to one
-- |     book within the bundle).
-- |   * Bare 'Array' of @{name, address}@ → 'BareNamedWallets'.
-- |   * Bare 'Array' of @{name, cid}@ → 'BareNamedRefUris'.
-- |   * Bare 'Array' of 'String' → 'BareFreeText' — the
-- |     caller must supply a destination 'FreeTextBookKey'
-- |     at merge time.
-- |   * Anything else → 'ParseError'.
module BooksPage.Import
  ( Books
  , BundleData
  , ImportDestination(..)
  , ImportError(..)
  , ImportPayload(..)
  , DiffRow
  , describeError
  , parseImport
  , merge
  , diff
  , encodeBundleJson
  , encodeNamedBookJson
  , encodeFreeTextBookJson
  , allFreeTextKeys
  , allNamedKeys
  , allSnapshotKeys
  , freeTextSuffix
  , namedSuffix
  , freeTextSuffixToKey
  , snapshotSuffixToKey
  , destinationSuffix
  , destinationFromSuffix
  ) where

import Prelude

import Control.Alt ((<|>))
import Data.Argonaut.Core (Json)
import Data.Argonaut.Core as Argonaut
import Data.Argonaut.Decode (decodeJson)
import Data.Argonaut.Encode (encodeJson)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.String.Common (joinWith)
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Foreign.Object as FO

import Shell.Book
  ( BookKey(..)
  , FreeTextBookKey(..)
  , NamedBookKey(..)
  , NamedEntry(..)
  , OperateSnapshotEntry
  , ReferenceEntry
  , WalletEntry
  , autoSaveName
  , bookCap
  )

-- ---------------------------------------------------------------------------
-- The Books cache duplicated here as a structural type so this module stays
-- independent of any consumer.  Same shape used by 'OperatePage' and
-- 'BooksPage'.

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
  -- of /operate form snapshots.  Both stored as
  -- 'NamedEntry' so the per-card render path reuses the
  -- existing taxonomy; the actual entries are always
  -- 'OperateSnapshotE' constructors.
  , operateDrafts :: Array NamedEntry
  , operateHistory :: Array NamedEntry
  }

-- ---------------------------------------------------------------------------
-- Payload + error types

data ImportPayload
  = BundlePayload BundleData
  | BareNamedWallets (Array WalletEntry)
  | BareNamedReferences (Array ReferenceEntry)
  | BareNamedSnapshots (Array OperateSnapshotEntry)
  | BareFreeText (Array String)

type BundleData =
  { wallets :: Array WalletEntry
  , references :: Array ReferenceEntry
  , descriptions :: Array String
  , justifications :: Array String
  , destinationLabels :: Array String
  , validityHours :: Array String
  , slippageBps :: Array String
  , splitCounts :: Array String
  -- #288 — snapshot books carried in the same bundle.
  -- '__autosave__' entries are silently dropped at parse
  -- time so a cross-browser bundle can't overwrite the
  -- local auto-save slot (FR-002).
  , operateDrafts :: Array OperateSnapshotEntry
  , operateHistory :: Array OperateSnapshotEntry
  , warnings :: Array String
  }

-- | Destination picked by the operator for a bare-array
-- | import.  Free-text books cover the original six string
-- | books; snapshot books cover the two #288 books
-- | (`operate_drafts` / `operate_history`).
data ImportDestination
  = DestFreeText FreeTextBookKey
  | DestSnapshot NamedBookKey

derive instance eqImportDestination :: Eq ImportDestination

data ImportError
  = ParseError String
  | WrongKind String
  | UnknownShape
  | DestinationRequired
  | SnapshotDestinationRequired
  | EmptyImport

describeError :: ImportError -> String
describeError = case _ of
  ParseError msg -> "could not parse JSON: " <> msg
  WrongKind msg -> "unrecognised bundle: " <> msg
  UnknownShape ->
    "unsupported shape: expected a bundle object or a bare \
    \array of strings, wallets, reference URIs, or \
    \snapshots"
  DestinationRequired ->
    "bare string array — pick a destination free-text book \
    \from the dropdown"
  SnapshotDestinationRequired ->
    "bare snapshot array — pick 'Drafts' or 'History' from \
    \the destination dropdown"
  EmptyImport -> "import produced no entries"

-- ---------------------------------------------------------------------------
-- Parse

-- | Inspect a parsed JSON value and pick the matching
-- | 'ImportPayload'.  Pure; the caller is responsible for
-- | running 'jsonParser' on the textarea contents first.
parseImport :: Json -> Either ImportError ImportPayload
parseImport j =
  case Argonaut.toArray j of
    Just arr -> parseBareArray arr
    Nothing -> case Argonaut.toObject j of
      Just obj -> parseBundle obj
      Nothing -> Left UnknownShape

parseBareArray
  :: Array Json -> Either ImportError ImportPayload
parseBareArray arr
  | Array.null arr = Left EmptyImport
  | otherwise =
      -- Snapshot entries go FIRST: '{name, snapshot}' has
      -- the lowest field count (two), and the 'snapshot'
      -- field decodes as a Json *object* rather than a
      -- string — wallets / references / free-text all
      -- require string fields, so a snapshot blob is
      -- unambiguous against them.
      --
      -- References then go before wallets: a 'ReferenceEntry'
      -- has all the 'WalletEntry' fields except 'address' is
      -- replaced by 'uri', and references additionally has
      -- 'label' + 'type'.  Checking references before
      -- wallets means a `{name, address, uri, label, type}`
      -- blob would route to references (correct).
      case asSnapshotEntries arr of
        Just xs -> Right (BareNamedSnapshots xs)
        Nothing -> case asReferenceEntries arr of
          Just xs -> Right (BareNamedReferences xs)
          Nothing -> case asWalletEntries arr of
            Just xs -> Right (BareNamedWallets xs)
            Nothing -> case asStrings arr of
              Just xs -> Right (BareFreeText xs)
              Nothing -> Left UnknownShape

asWalletEntries :: Array Json -> Maybe (Array WalletEntry)
asWalletEntries arr = case decodeJson (Argonaut.fromArray arr) of
  Right (xs :: Array WalletEntry)
    | not (Array.null xs) -> Just xs
  _ -> Nothing

-- | A bare array is a snapshot payload when EVERY entry has
-- | a string 'name' AND a 'snapshot' field that decodes as
-- | a JSON object — defensive against legacy entries whose
-- | snapshot is a string blob.  All-or-nothing per the
-- | FR-011 spirit (a single bad entry rejects the bare
-- | dispatch and falls through to the next codec).
asSnapshotEntries
  :: Array Json -> Maybe (Array OperateSnapshotEntry)
asSnapshotEntries arr = case traverse decodeSnapshotEntry arr of
  Just xs | not (Array.null xs) -> Just xs
  _ -> Nothing

decodeSnapshotEntry :: Json -> Maybe OperateSnapshotEntry
decodeSnapshotEntry j = do
  obj <- Argonaut.toObject j
  name <- FO.lookup "name" obj >>= Argonaut.toString
  snapshot <- FO.lookup "snapshot" obj
  _ <- Argonaut.toObject snapshot
  pure { name, snapshot }

-- | A bare array is a 'references' payload when EVERY entry
-- | decodes via 'decodeReferenceEntry' (i.e. carries
-- | @name@, @label@, @uri@, @type@ — all strings).  All-or-
-- | nothing per the FR-011 spirit.
asReferenceEntries
  :: Array Json -> Maybe (Array ReferenceEntry)
asReferenceEntries arr = case traverse decodeReferenceEntry arr of
  Just xs | not (Array.null xs) -> Just xs
  _ -> Nothing

decodeReferenceEntry :: Json -> Maybe ReferenceEntry
decodeReferenceEntry j = do
  obj <- Argonaut.toObject j
  name <- FO.lookup "name" obj >>= Argonaut.toString
  label <- FO.lookup "label" obj >>= Argonaut.toString
  uri <- FO.lookup "uri" obj >>= Argonaut.toString
  refType <- FO.lookup "type" obj >>= Argonaut.toString
  pure { name, label, uri, refType }

asStrings :: Array Json -> Maybe (Array String)
asStrings arr = case decodeJson (Argonaut.fromArray arr) of
  Right (xs :: Array String) -> Just xs
  _ -> Nothing

parseBundle
  :: FO.Object Json -> Either ImportError ImportPayload
parseBundle obj = case FO.lookup "kind" obj of
  Nothing ->
    Left
      ( WrongKind
          "missing 'kind' — expected \
          \\"amaru.book.bundle.v1\""
      )
  Just kindJ -> case Argonaut.toString kindJ of
    Nothing -> Left (WrongKind "'kind' is not a string")
    Just k
      | k /= "amaru.book.bundle.v1" ->
          Left
            ( WrongKind
                ( "unsupported kind '" <> k <>
                    "'; expected 'amaru.book.bundle.v1'"
                )
            )
      | otherwise -> case FO.lookup "books" obj of
          Nothing ->
            Left (WrongKind "missing 'books' field")
          Just booksJ -> case Argonaut.toObject booksJ of
            Nothing ->
              Left (WrongKind "'books' is not an object")
            Just booksObj ->
              Right (BundlePayload (decodeBundleBooks booksObj))

decodeBundleBooks :: FO.Object Json -> BundleData
decodeBundleBooks obj =
  let
    actualKeys = FO.keys obj
    unknownKeys =
      Array.filter (\k -> not (Array.elem k knownKeys)) actualKeys
    warnings =
      if Array.null unknownKeys then []
      else
        [ "ignoring unknown book key(s): "
            <> joinWith ", " unknownKeys
        ]
  in
    { wallets: namedAt "wallets" obj
    , references: referencesAt "references" obj
    , descriptions: stringsAt "descriptions" obj
    , justifications: stringsAt "justifications" obj
    , destinationLabels: stringsAt "destination_labels" obj
    , validityHours: stringsAt "validity_hours" obj
    , slippageBps: stringsAt "slippage_bps" obj
    , splitCounts: stringsAt "split_counts" obj
    , operateDrafts: snapshotsAt "operate_drafts" obj
    , operateHistory: snapshotsAt "operate_history" obj
    , warnings
    }

knownKeys :: Array String
knownKeys =
  [ "wallets"
  , "references"
  , "descriptions"
  , "justifications"
  , "destination_labels"
  , "validity_hours"
  , "slippage_bps"
  , "split_counts"
  , "operate_drafts"
  , "operate_history"
  ]

namedAt :: String -> FO.Object Json -> Array WalletEntry
namedAt k obj = case FO.lookup k obj of
  Just j -> case decodeJson j of
    Right (xs :: Array WalletEntry) -> xs
    Left _ -> []
  Nothing -> []

referencesAt :: String -> FO.Object Json -> Array ReferenceEntry
referencesAt k obj = case FO.lookup k obj of
  Just j -> case Argonaut.toArray j of
    Nothing -> []
    Just arr -> case traverse decodeReferenceEntry arr of
      Just rs -> rs
      Nothing -> []
  Nothing -> []

stringsAt :: String -> FO.Object Json -> Array String
stringsAt k obj = case FO.lookup k obj of
  Just j -> case decodeJson j of
    Right (xs :: Array String) -> xs
    Left _ -> []
  Nothing -> []

-- | Per-bundle-key decoder for snapshot books.  Defensive
-- | per-entry: a single malformed entry is skipped, the
-- | rest accepted (FR-006 spirit — robust against partial
-- | migrations between snapshot schemas).
snapshotsAt
  :: String -> FO.Object Json -> Array OperateSnapshotEntry
snapshotsAt k obj = case FO.lookup k obj of
  Just j -> case Argonaut.toArray j of
    Just arr -> Array.mapMaybe decodeSnapshotEntry arr
    Nothing -> []
  Nothing -> []

-- ---------------------------------------------------------------------------
-- Merge

-- | Apply an 'ImportPayload' on top of the existing
-- | 'Books'.  Returns 'Left DestinationRequired' if the
-- | payload is 'BareFreeText' but no destination key was
-- | supplied.  Imported entries always land at the front;
-- | dedup-on-typed-value rules per FR-016 mean the
-- | imported `name` wins on conflict.
merge
  :: ImportPayload
  -> Maybe ImportDestination
  -> Books
  -> Either ImportError Books
merge payload mDest books = case payload of
  BundlePayload bd ->
    Right
      ( books
          { wallets =
              mergeNamedWallets bd.wallets books.wallets
          , references =
              mergeNamedReferences
                bd.references
                books.references
          , descriptions =
              mergeStrings bd.descriptions books.descriptions
          , justifications =
              mergeStrings
                bd.justifications
                books.justifications
          , destinationLabels =
              mergeStrings
                bd.destinationLabels
                books.destinationLabels
          , validityHours =
              mergeStrings
                bd.validityHours
                books.validityHours
          , slippageBps =
              mergeStrings bd.slippageBps books.slippageBps
          , splitCounts =
              mergeStrings bd.splitCounts books.splitCounts
          , operateDrafts =
              mergeSnapshots
                OperateDraftsBook
                bd.operateDrafts
                books.operateDrafts
          , operateHistory =
              mergeSnapshots
                OperateHistoryBook
                bd.operateHistory
                books.operateHistory
          }
      )

  BareNamedWallets xs ->
    Right
      ( books
          { wallets = mergeNamedWallets xs books.wallets }
      )

  BareNamedReferences xs ->
    Right
      ( books
          { references =
              mergeNamedReferences xs books.references
          }
      )

  BareNamedSnapshots xs -> case mDest of
    Just (DestSnapshot OperateDraftsBook) ->
      Right
        ( books
            { operateDrafts =
                mergeSnapshots
                  OperateDraftsBook
                  xs
                  books.operateDrafts
            }
        )
    Just (DestSnapshot OperateHistoryBook) ->
      Right
        ( books
            { operateHistory =
                mergeSnapshots
                  OperateHistoryBook
                  xs
                  books.operateHistory
            }
        )
    _ -> Left SnapshotDestinationRequired

  BareFreeText xs -> case mDest of
    Just (DestFreeText k) ->
      Right (mergeFreeTextAt k xs books)
    _ -> Left DestinationRequired

mergeFreeTextAt
  :: FreeTextBookKey -> Array String -> Books -> Books
mergeFreeTextAt key xs b = case key of
  DescriptionsBook ->
    b { descriptions = mergeStrings xs b.descriptions }
  JustificationsBook ->
    b { justifications = mergeStrings xs b.justifications }
  DestinationLabelsBook ->
    b
      { destinationLabels =
          mergeStrings xs b.destinationLabels
      }
  ValidityHoursBook ->
    b { validityHours = mergeStrings xs b.validityHours }
  SlippageBpsBook ->
    b { slippageBps = mergeStrings xs b.slippageBps }
  SplitCountsBook ->
    b { splitCounts = mergeStrings xs b.splitCounts }

-- | Default cap for every book that doesn't override
-- | 'bookCap'.  Snapshot books (`operate_history`) carry
-- | their own 100-entry window via 'bookCap'; everything
-- | else stays at the historical 25.
mergeStrings :: Array String -> Array String -> Array String
mergeStrings imported local =
  let
    cleaned =
      Array.filter (\s -> String.trim s /= "") imported
    deduped = dedupBy (==) cleaned
    importedSet = deduped
    kept =
      Array.filter
        (\s -> not (Array.elem s importedSet))
        local
  in
    -- Free-text books all return 25 from `bookCap` (any
    -- 'F' key currently); pick one to read it from.
    Array.take (bookCap (F DescriptionsBook)) (deduped <> kept)

mergeNamedWallets
  :: Array WalletEntry
  -> Array NamedEntry
  -> Array NamedEntry
mergeNamedWallets imported local =
  let
    cleaned =
      Array.filter
        (\e -> String.trim e.address /= "")
        imported
    deduped =
      dedupBy (\a b -> a.address == b.address) cleaned
    addrs = map _.address deduped
    keptLocal =
      Array.filter
        ( \e ->
            not (Array.elem (namedTypedValue e) addrs)
        )
        local
    asNamed = map WalletE deduped
  in
    Array.take (bookCap (N WalletsBook)) (asNamed <> keptLocal)

mergeNamedReferences
  :: Array ReferenceEntry
  -> Array NamedEntry
  -> Array NamedEntry
mergeNamedReferences imported local =
  let
    cleaned =
      Array.filter
        (\e -> String.trim e.uri /= "")
        imported
    deduped =
      dedupBy (\a b -> a.uri == b.uri) cleaned
    uris = map _.uri deduped
    keptLocal =
      Array.filter
        ( \e -> not (Array.elem (namedTypedValue e) uris)
        )
        local
    asNamed = map ReferenceE deduped
  in
    Array.take (bookCap (N ReferencesBook))
      (asNamed <> keptLocal)

-- | #288 — merge imported snapshot entries into a snapshot
-- | book.  Dedup-on-name (snapshot books have no typed
-- | primitive); imported entry wins on collision; the
-- | reserved `__autosave__` slot is silently dropped from
-- | imports so a bundle from another browser can't
-- | overwrite the local in-progress draft (FR-002).
-- | Capped via 'bookCap' (drafts=25, history=100).
mergeSnapshots
  :: NamedBookKey
  -> Array OperateSnapshotEntry
  -> Array NamedEntry
  -> Array NamedEntry
mergeSnapshots key imported local =
  let
    cleaned =
      Array.filter
        ( \e ->
            String.trim e.name /= ""
              && e.name /= autoSaveName
        )
        imported
    deduped = dedupBy (\a b -> a.name == b.name) cleaned
    names = map _.name deduped
    keptLocal =
      Array.filter
        ( \e ->
            not (Array.elem (namedTypedValue e) names)
        )
        local
    asNamed = map OperateSnapshotE deduped
  in
    Array.take (bookCap (N key)) (asNamed <> keptLocal)

namedTypedValue :: NamedEntry -> String
namedTypedValue = case _ of
  WalletE w -> w.address
  ReferenceE r -> r.uri
  -- #288 slice A: snapshot books dedup on entry `name`.
  -- The Import.purs merge paths for operate_drafts /
  -- operate_history are wired in slice C; this branch
  -- keeps the local helper total against the widened
  -- 'NamedEntry' variant so the build stays green.
  OperateSnapshotE s -> s.name

dedupBy
  :: forall a
   . (a -> a -> Boolean)
  -> Array a
  -> Array a
dedupBy eq xs =
  Array.foldl
    ( \acc x ->
        if Array.any (eq x) acc then acc
        else Array.snoc acc x
    )
    []
    xs

-- ---------------------------------------------------------------------------
-- Diff

type DiffRow =
  { book :: BookKey
  , beforeCount :: Int
  , afterCount :: Int
  }

-- | Produce a before/after count table across every
-- | booked key.  Rows render in the spec's mapping table
-- | order; rows where before == after still render so the
-- | operator can confirm nothing was overlooked.
diff :: Books -> Books -> Array DiffRow
diff before after =
  [ { book: N OperateDraftsBook
    , beforeCount: visibleSnapshotCount before.operateDrafts
    , afterCount: visibleSnapshotCount after.operateDrafts
    }
  , { book: N OperateHistoryBook
    , beforeCount: visibleSnapshotCount before.operateHistory
    , afterCount: visibleSnapshotCount after.operateHistory
    }
  , { book: N WalletsBook
    , beforeCount: Array.length before.wallets
    , afterCount: Array.length after.wallets
    }
  , { book: N ReferencesBook
    , beforeCount: Array.length before.references
    , afterCount: Array.length after.references
    }
  , { book: F DescriptionsBook
    , beforeCount: Array.length before.descriptions
    , afterCount: Array.length after.descriptions
    }
  , { book: F JustificationsBook
    , beforeCount: Array.length before.justifications
    , afterCount: Array.length after.justifications
    }
  , { book: F DestinationLabelsBook
    , beforeCount: Array.length before.destinationLabels
    , afterCount: Array.length after.destinationLabels
    }
  , { book: F ValidityHoursBook
    , beforeCount: Array.length before.validityHours
    , afterCount: Array.length after.validityHours
    }
  , { book: F SlippageBpsBook
    , beforeCount: Array.length before.slippageBps
    , afterCount: Array.length after.slippageBps
    }
  , { book: F SplitCountsBook
    , beforeCount: Array.length before.splitCounts
    , afterCount: Array.length after.splitCounts
    }
  ]

-- | Snapshot count excluding the reserved auto-save slot.
-- | The diff row reports user-visible entries so a one-only
-- | `__autosave__` book reads as `0`, matching the
-- | `Drafts ▾` / `History ▾` picker visibility.
visibleSnapshotCount :: Array NamedEntry -> Int
visibleSnapshotCount =
  Array.length
    <<< Array.filter
      (\e -> namedTypedValue e /= autoSaveName)

-- ---------------------------------------------------------------------------
-- Encode (export wire shapes)

-- | Encode the all-books bundle JSON.  Matches FR-015's
-- | bundle shape exactly: top-level @kind@ + @books@ map
-- | with snake_case keys.
encodeBundleJson :: Books -> Json
encodeBundleJson b =
  Argonaut.fromObject
    ( FO.fromFoldable
        [ Tuple "kind"
            (Argonaut.fromString "amaru.book.bundle.v1")
        , Tuple "books"
            ( Argonaut.fromObject
                ( FO.fromFoldable
                    [ Tuple "wallets"
                        (encodeNamedBookJson b.wallets)
                    , Tuple "references"
                        (encodeNamedBookJson b.references)
                    , Tuple "descriptions"
                        ( encodeFreeTextBookJson
                            b.descriptions
                        )
                    , Tuple "justifications"
                        ( encodeFreeTextBookJson
                            b.justifications
                        )
                    , Tuple "destination_labels"
                        ( encodeFreeTextBookJson
                            b.destinationLabels
                        )
                    , Tuple "validity_hours"
                        ( encodeFreeTextBookJson
                            b.validityHours
                        )
                    , Tuple "slippage_bps"
                        ( encodeFreeTextBookJson
                            b.slippageBps
                        )
                    , Tuple "split_counts"
                        ( encodeFreeTextBookJson
                            b.splitCounts
                        )
                    -- #288 — snapshot books are emitted
                    -- with the auto-save slot filtered out
                    -- (FR-002): the bundle exists to share
                    -- curated state across browsers, and
                    -- the local in-progress draft is
                    -- per-browser working state, not
                    -- shareable.
                    , Tuple "operate_drafts"
                        ( encodeNamedBookJson
                            (dropAutoSave b.operateDrafts)
                        )
                    , Tuple "operate_history"
                        ( encodeNamedBookJson
                            (dropAutoSave b.operateHistory)
                        )
                    ]
                )
            )
        ]
    )

-- | Strip the reserved auto-save slot from a snapshot
-- | book.  Used at export time so bundles never carry the
-- | per-browser in-progress draft.
dropAutoSave :: Array NamedEntry -> Array NamedEntry
dropAutoSave =
  Array.filter (\e -> namedTypedValue e /= autoSaveName)

-- | Per-card export: a bare array of named-book entries.
-- | Wallets encode via the auto-derived `encodeJson` (field
-- | names match the wire keys); references encode through a
-- | hand-rolled object so the PS-side `refType` field
-- | becomes the wire-side @"type"@ key.
encodeNamedBookJson :: Array NamedEntry -> Json
encodeNamedBookJson =
  Argonaut.fromArray <<< map oneNamed
  where
  oneNamed = case _ of
    WalletE w -> encodeJson w
    ReferenceE r ->
      Argonaut.fromObject $ FO.fromFoldable
        [ Tuple "name" (Argonaut.fromString r.name)
        , Tuple "label" (Argonaut.fromString r.label)
        , Tuple "uri" (Argonaut.fromString r.uri)
        , Tuple "type" (Argonaut.fromString r.refType)
        ]
    -- #288 slice A: bundle export for the new books is
    -- wired in slice C; keep this local encoder total so
    -- the build stays green.  The shape matches
    -- Shell.Book.encodeSnapshotEntry exactly.
    OperateSnapshotE s ->
      Argonaut.fromObject $ FO.fromFoldable
        [ Tuple "name" (Argonaut.fromString s.name)
        , Tuple "snapshot" s.snapshot
        ]

-- | Per-card free-text export: a bare 'Array String'.
encodeFreeTextBookJson :: Array String -> Json
encodeFreeTextBookJson = encodeJson

-- ---------------------------------------------------------------------------
-- Key taxonomy helpers (re-exported so 'BooksPage' can
-- iterate without re-listing all ten keys).

allFreeTextKeys :: Array FreeTextBookKey
allFreeTextKeys =
  [ DescriptionsBook
  , JustificationsBook
  , DestinationLabelsBook
  , ValidityHoursBook
  , SlippageBpsBook
  , SplitCountsBook
  ]

allNamedKeys :: Array NamedBookKey
allNamedKeys =
  [ WalletsBook
  , ReferencesBook
  , OperateDraftsBook
  , OperateHistoryBook
  ]

-- | Subset of 'allNamedKeys' covering the snapshot books
-- | only.  Used by the import dialog to populate the
-- | snapshot-destination dropdown for `BareNamedSnapshots`
-- | payloads.
allSnapshotKeys :: Array NamedBookKey
allSnapshotKeys = [ OperateDraftsBook, OperateHistoryBook ]

namedSuffix :: NamedBookKey -> String
namedSuffix = case _ of
  WalletsBook -> "wallets"
  ReferencesBook -> "references"
  -- #288 slice A: bundle handling for the new books is wired
  -- in slice C; keep the local helper total so the build
  -- stays green and `allNamedKeys` continues to enumerate
  -- only the in-flight bundle keys for this slice.
  OperateDraftsBook -> "operate_drafts"
  OperateHistoryBook -> "operate_history"

freeTextSuffix :: FreeTextBookKey -> String
freeTextSuffix = case _ of
  DescriptionsBook -> "descriptions"
  JustificationsBook -> "justifications"
  DestinationLabelsBook -> "destination_labels"
  ValidityHoursBook -> "validity_hours"
  SlippageBpsBook -> "slippage_bps"
  SplitCountsBook -> "split_counts"

freeTextSuffixToKey :: String -> Maybe FreeTextBookKey
freeTextSuffixToKey = case _ of
  "descriptions" -> Just DescriptionsBook
  "justifications" -> Just JustificationsBook
  "destination_labels" -> Just DestinationLabelsBook
  "validity_hours" -> Just ValidityHoursBook
  "slippage_bps" -> Just SlippageBpsBook
  "split_counts" -> Just SplitCountsBook
  _ -> Nothing

-- | Resolve the snapshot-book wire suffix
-- | (`operate_drafts` / `operate_history`) into the typed
-- | 'NamedBookKey'.  Returns 'Nothing' for any non-snapshot
-- | suffix.
snapshotSuffixToKey :: String -> Maybe NamedBookKey
snapshotSuffixToKey = case _ of
  "operate_drafts" -> Just OperateDraftsBook
  "operate_history" -> Just OperateHistoryBook
  _ -> Nothing

-- | Wire suffix for an 'ImportDestination'.  Mirrors the
-- | snake-case keys used by the bundle on disk so the
-- | dialog's destination dropdown serialises uniformly
-- | across both kinds of destination.
destinationSuffix :: ImportDestination -> String
destinationSuffix = case _ of
  DestFreeText k -> freeTextSuffix k
  DestSnapshot k -> namedSuffix k

-- | Inverse of 'destinationSuffix': resolve a wire suffix
-- | back to its typed destination.  Returns 'Nothing' for
-- | unknown / unsupported (identity-book) suffixes.
destinationFromSuffix :: String -> Maybe ImportDestination
destinationFromSuffix s =
  (DestFreeText <$> freeTextSuffixToKey s)
    <|> (DestSnapshot <$> snapshotSuffixToKey s)
