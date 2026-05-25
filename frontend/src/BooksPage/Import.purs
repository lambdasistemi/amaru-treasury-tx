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
  , freeTextSuffix
  , namedSuffix
  , freeTextSuffixToKey
  ) where

import Prelude

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
  , ReferenceEntry
  , WalletEntry
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
  }

-- ---------------------------------------------------------------------------
-- Payload + error types

data ImportPayload
  = BundlePayload BundleData
  | BareNamedWallets (Array WalletEntry)
  | BareNamedReferences (Array ReferenceEntry)
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
  , warnings :: Array String
  }

data ImportError
  = ParseError String
  | WrongKind String
  | UnknownShape
  | DestinationRequired
  | EmptyImport

describeError :: ImportError -> String
describeError = case _ of
  ParseError msg -> "could not parse JSON: " <> msg
  WrongKind msg -> "unrecognised bundle: " <> msg
  UnknownShape ->
    "unsupported shape: expected a bundle object or a bare \
    \array of strings, wallets, or reference URIs"
  DestinationRequired ->
    "bare string array — pick a destination free-text book \
    \from the dropdown"
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
      -- References go FIRST: a ReferenceEntry has all the
      -- WalletEntry fields except 'address' is replaced by
      -- 'uri', and references additionally has 'label' +
      -- 'type'.  Checking references before wallets means
      -- a `{name, address, uri, label, type}` blob would
      -- route to references (correct).  Wallets vs free
      -- text are mutually exclusive by shape so order
      -- doesn't matter for them.
      case asReferenceEntries arr of
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
  -> Maybe FreeTextBookKey
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

  BareFreeText xs -> case mDest of
    Nothing -> Left DestinationRequired
    Just k ->
      Right (mergeFreeTextAt k xs books)

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

cap :: Int
cap = 25

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
    Array.take cap (deduped <> kept)

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
    Array.take cap (asNamed <> keptLocal)

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
    Array.take cap (asNamed <> keptLocal)

namedTypedValue :: NamedEntry -> String
namedTypedValue = case _ of
  WalletE w -> w.address
  ReferenceE r -> r.uri

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
  [ { book: N WalletsBook
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
                    ]
                )
            )
        ]
    )

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
allNamedKeys = [ WalletsBook, ReferencesBook ]

namedSuffix :: NamedBookKey -> String
namedSuffix = case _ of
  WalletsBook -> "wallets"
  ReferencesBook -> "references"

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
