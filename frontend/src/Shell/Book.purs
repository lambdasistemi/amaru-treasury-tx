-- | #267 — Per-field history "books" persisted in
-- | `window.localStorage`.  Two shapes:
-- |
-- |   * **Named** books for cryptographic / identity
-- |     material — `wallets` holds `{name, address}` rows
-- |     (Lace contact-book convention), `references` holds
-- |     `{name, label, uri, type}` rows (one indivisible
-- |     CIP-1694 `body.references[]` triple per entry —
-- |     slice G replaced the original three split books
-- |     after operator feedback that mismatching label /
-- |     type / uri across rows was too easy).
-- |   * **Free-text** books for prose — plain `Array
-- |     String`.
-- |
-- | The on-disk shape per book is the **wire shape** — no
-- | internal envelope, no per-book version field.  Whatever
-- | a `/books` export downloads is byte-identical to what
-- | lives in `localStorage`, so an operator can move
-- | booked material between Amaru and Lace / an IPFS pin
-- | dashboard without writing `jq` (FR-015).
-- |
-- | Atomic reset on invalid shape (FR-011): if the on-disk
-- | JSON fails to parse OR fails to decode as the expected
-- | per-book wire shape, the whole book is treated as
-- | empty.  No per-entry partial recovery, no migration —
-- | the schema evolution path is "rename the storage key".
module Shell.Book
  ( NamedBookKey(..)
  , FreeTextBookKey(..)
  , BookKey(..)
  , WalletEntry
  , ReferenceEntry
  , NamedEntry(..)
  , namedTypedValue
  , deriveDefaultName
  , storageKey
  , maxEntries
  , loadNamed
  , loadFreeText
  , recordNamed
  , recordFreeText
  , renameNamed
  , addNamed
  , removeNamed
  , removeFreeText
  , replaceNamed
  , replaceFreeText
  , clear
  ) where

import Prelude

import Data.Argonaut.Core (Json, fromArray, stringify)
import Data.Argonaut.Core as Argonaut
import Data.Argonaut.Decode (decodeJson)
import Data.Argonaut.Encode (encodeJson)
import Data.Argonaut.Parser (jsonParser)
import Data.Array as Array
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.String as String
import Data.Traversable (traverse)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Foreign.Object as FO

-- ---------------------------------------------------------------------------
-- Book taxonomy

-- | Books holding cryptographic / identity material.
-- | Each entry carries a `name` plus typed payload
-- | field(s): `address` for wallets; the compound
-- | `{label, uri, type}` triple for references (one
-- | indivisible on-chain CIP-1694 `body.references[]`
-- | entry, slice G).
data NamedBookKey
  = WalletsBook
  | ReferencesBook

derive instance eqNamedBookKey :: Eq NamedBookKey

-- | Books holding free-text prose.  No structure — each
-- | entry is a plain string the operator has previously
-- | submitted.
data FreeTextBookKey
  = DescriptionsBook
  | JustificationsBook
  | DestinationLabelsBook
  | ValidityHoursBook
  | SlippageBpsBook
  | SplitCountsBook

derive instance eqFreeTextBookKey :: Eq FreeTextBookKey

-- | Existential book handle used by 'clear', which works
-- | identically on either shape.  Operations that depend
-- | on the entry shape (`loadNamed`, `recordFreeText`,
-- | etc.) take the per-shape key directly so a wrong-shape
-- | call is a type error rather than a runtime branch.
data BookKey
  = N NamedBookKey
  | F FreeTextBookKey

-- ---------------------------------------------------------------------------
-- Entry types

-- | One row in the `wallets` book.  Matches the Lace
-- | contact-book import shape one-to-one.
type WalletEntry =
  { name :: String
  , address :: String
  }

-- | One row in the `references` book.  Carries the whole
-- | indivisible CIP-1694 `body.references[]` triple plus
-- | a friendly `name`.  The PS-side field `refType` maps
-- | to the wire JSON key @"type"@ (encoded / decoded
-- | explicitly because @type@ is a PS keyword).
type ReferenceEntry =
  { name :: String
  , label :: String
  , uri :: String
  , refType :: String
  }

-- | A row from any named book.  The constructor selects
-- | the per-book entry shape so callers can pattern-match
-- | without re-checking the originating key.
data NamedEntry
  = WalletE WalletEntry
  | ReferenceE ReferenceEntry

-- | Project the typed-value field from a named entry —
-- | `address` for wallets, `uri` for references.  Used by
-- | every dedup / lookup / remove path so the "what does
-- | identity mean for this book" rule lives in exactly
-- | one place.
namedTypedValue :: NamedEntry -> String
namedTypedValue = case _ of
  WalletE w -> w.address
  ReferenceE r -> r.uri

-- ---------------------------------------------------------------------------
-- Constants + key helpers

-- | Maximum entries kept per book.  Older values are
-- | dropped (tail-pruned) once a `record*` / `addNamed`
-- | call pushes the count past this cap.
maxEntries :: Int
maxEntries = 25

storagePrefix :: String
storagePrefix = "amaru-treasury.book."

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

bookKeySuffix :: BookKey -> String
bookKeySuffix = case _ of
  N k -> namedSuffix k
  F k -> freeTextSuffix k

-- | Full `window.localStorage` key for a book.  Exposed so
-- | operators can inspect / wipe a specific book from the
-- | browser devtools without guessing the prefix.
storageKey :: BookKey -> String
storageKey k = storagePrefix <> bookKeySuffix k

namedStorageKey :: NamedBookKey -> String
namedStorageKey = storageKey <<< N

freeTextStorageKey :: FreeTextBookKey -> String
freeTextStorageKey = storageKey <<< F

-- ---------------------------------------------------------------------------
-- Default-name derivation

-- | Auto-name for a named entry recorded via the
-- | `recordNamed` (auto-name-on-build) path.  The brief
-- | contract: first 8 chars + @…@ + last 6 chars when the
-- | input is longer than 18 chars; short inputs pass
-- | through unchanged.  Operators rename via the `/books`
-- | page (slice C) — this only generates the placeholder.
deriveDefaultName :: String -> String
deriveDefaultName s
  | String.length s > 18 =
      String.take 8 s
        <> "…"
        <> String.drop (String.length s - 6) s
  | otherwise = s

-- ---------------------------------------------------------------------------
-- Load

-- | Read a named book from `localStorage`.  Returns the
-- | empty array if the value is absent, the JSON fails to
-- | parse, or the decoded shape doesn't match the per-book
-- | wire shape — atomic reset per FR-011.
loadNamed :: NamedBookKey -> Effect (Array NamedEntry)
loadNamed key = do
  raw <- _get (namedStorageKey key)
  pure case jsonParser raw of
    Left _ -> []
    Right json -> case key of
      WalletsBook -> decodeWallets json
      ReferencesBook -> decodeReferences json

-- | Read a free-text book.  Same atomic-reset semantics
-- | on invalid on-disk shape as 'loadNamed'.
loadFreeText :: FreeTextBookKey -> Effect (Array String)
loadFreeText key = do
  raw <- _get (freeTextStorageKey key)
  pure case jsonParser raw of
    Left _ -> []
    Right json -> case decodeJson json of
      Left _ -> []
      Right (xs :: Array String) -> xs

decodeWallets :: Json -> Array NamedEntry
decodeWallets j = case decodeJson j of
  Left _ -> []
  Right (xs :: Array WalletEntry) -> map WalletE xs

-- | Decode the bare `[{name, label, uri, type}, …]`
-- | references wire shape.  Atomic-reset (FR-011): a
-- | single malformed entry discards the whole book.
decodeReferences :: Json -> Array NamedEntry
decodeReferences j = case Argonaut.toArray j of
  Nothing -> []
  Just arr -> case traverse decodeReferenceEntry arr of
    Nothing -> []
    Just rs -> map ReferenceE rs

-- | Per-entry decoder for the references wire shape.
-- | Returns 'Nothing' on any missing field or non-string
-- | value — the caller (`decodeReferences`) atomic-resets
-- | the book if ANY entry returns 'Nothing'.
decodeReferenceEntry :: Json -> Maybe ReferenceEntry
decodeReferenceEntry j = do
  obj <- Argonaut.toObject j
  name <- FO.lookup "name" obj >>= Argonaut.toString
  label <- FO.lookup "label" obj >>= Argonaut.toString
  uri <- FO.lookup "uri" obj >>= Argonaut.toString
  refType <- FO.lookup "type" obj >>= Argonaut.toString
  pure { name, label, uri, refType }

-- ---------------------------------------------------------------------------
-- Record (auto-name on build)

-- | Record the operator-supplied typed value into a named
-- | book.  Dedup-on-typed-value: if an existing entry has
-- | the same `address` (resp. `cid`), the existing entry's
-- | **name** is preserved and it's moved to position 0 —
-- | the operator's hand-chosen name doesn't get clobbered
-- | by the derived default (FR-004).  Empty / whitespace
-- | values are silently skipped.
recordNamed :: NamedBookKey -> String -> Effect Unit
recordNamed key value
  | String.trim value == "" = pure unit
  | otherwise = do
      existing <- loadNamed key
      let
        match =
          Array.find
            (\e -> namedTypedValue e == value)
            existing
        without =
          Array.filter
            (\e -> namedTypedValue e /= value)
            existing
        entry = case match of
          Just e -> e
          Nothing -> defaultEntry key value
        merged =
          Array.take maxEntries (Array.cons entry without)
      writeNamed key merged

-- | Record the operator-supplied string into a free-text
-- | book.  Dedup-on-string with move-to-front; empty /
-- | whitespace values are silently skipped.
recordFreeText :: FreeTextBookKey -> String -> Effect Unit
recordFreeText key value
  | String.trim value == "" = pure unit
  | otherwise = do
      existing <- loadFreeText key
      let
        deduped = Array.filter (_ /= value) existing
        merged =
          Array.take maxEntries (Array.cons value deduped)
      writeFreeText key merged

defaultEntry :: NamedBookKey -> String -> NamedEntry
defaultEntry key value = case key of
  WalletsBook ->
    WalletE { name: deriveDefaultName value, address: value }
  ReferencesBook ->
    -- 'recordNamed' for references takes the URI only;
    -- label + type are left empty.  Callers that have
    -- the full triple should use 'addNamed' so the whole
    -- entry lands at once.
    ReferenceE
      { name: deriveDefaultName value
      , label: ""
      , uri: value
      , refType: ""
      }

-- ---------------------------------------------------------------------------
-- Rename / add / remove

-- | Set the `name` of the named entry whose typed value
-- | equals the given value.  No-op if no entry matches.
renameNamed
  :: NamedBookKey -> String -> String -> Effect Unit
renameNamed key value newName = do
  existing <- loadNamed key
  let renamed = map (renameIfMatch value newName) existing
  writeNamed key renamed
  where
  renameIfMatch v n e
    | namedTypedValue e == v = withName n e
    | otherwise = e

  withName n = case _ of
    WalletE w -> WalletE (w { name = n })
    ReferenceE r -> ReferenceE (r { name = n })

-- | Insert a fully-formed named entry at position 0.
-- | Dedup-on-typed-value: if an existing entry has the
-- | same typed value, the **inserted** entry wins (its
-- | name replaces the existing name) — the operator who
-- | clicked `Add new` is committing to that name.
addNamed :: NamedBookKey -> NamedEntry -> Effect Unit
addNamed key entry = do
  existing <- loadNamed key
  let
    v = namedTypedValue entry
    without =
      Array.filter
        (\e -> namedTypedValue e /= v)
        existing
    merged =
      Array.take maxEntries (Array.cons entry without)
  writeNamed key merged

-- | Delete the named entry whose typed value equals the
-- | given value.  No-op if no entry matches.
removeNamed :: NamedBookKey -> String -> Effect Unit
removeNamed key value = do
  existing <- loadNamed key
  let
    kept =
      Array.filter
        (\e -> namedTypedValue e /= value)
        existing
  writeNamed key kept

-- | Delete every free-text entry equal to the given
-- | string.  No-op if no entry matches.
removeFreeText :: FreeTextBookKey -> String -> Effect Unit
removeFreeText key value = do
  existing <- loadFreeText key
  let kept = Array.filter (_ /= value) existing
  writeFreeText key kept

-- | Drop the persisted book entirely.  After this, the
-- | next `load*` for the same key returns `[]`.
clear :: BookKey -> Effect Unit
clear = _remove <<< storageKey

-- | Overwrite a named book's contents wholesale.  Used by
-- | the `/books` import path (slice D) — the import's
-- | merge logic produces the final array; this writes it
-- | directly without per-entry `addNamed` round-trips.
-- | Cap defensively at `maxEntries` in case the caller's
-- | merge mis-counted.
replaceNamed
  :: NamedBookKey -> Array NamedEntry -> Effect Unit
replaceNamed key xs =
  writeNamed key (Array.take maxEntries xs)

-- | Overwrite a free-text book wholesale.  Same use-case
-- | + defensive cap as 'replaceNamed'.
replaceFreeText
  :: FreeTextBookKey -> Array String -> Effect Unit
replaceFreeText key xs =
  writeFreeText key (Array.take maxEntries xs)

-- ---------------------------------------------------------------------------
-- Write helpers (per-shape encoders)

writeNamed :: NamedBookKey -> Array NamedEntry -> Effect Unit
writeNamed key xs =
  _set (namedStorageKey key) (encodeNamedArray xs)

writeFreeText :: FreeTextBookKey -> Array String -> Effect Unit
writeFreeText key xs =
  _set (freeTextStorageKey key) (stringify (encodeJson xs))

encodeNamedArray :: Array NamedEntry -> String
encodeNamedArray =
  stringify <<< fromArray <<< map encodeNamedJson

encodeNamedJson :: NamedEntry -> Json
encodeNamedJson = case _ of
  WalletE w -> encodeJson w
  ReferenceE r -> encodeReferenceEntry r

-- | Custom encoder for 'ReferenceEntry'.  Renames the PS
-- | field `refType` to the on-disk / wire key @"type"@.
encodeReferenceEntry :: ReferenceEntry -> Json
encodeReferenceEntry r =
  Argonaut.fromObject $ FO.fromFoldable
    [ Tuple "name" (Argonaut.fromString r.name)
    , Tuple "label" (Argonaut.fromString r.label)
    , Tuple "uri" (Argonaut.fromString r.uri)
    , Tuple "type" (Argonaut.fromString r.refType)
    ]

-- ---------------------------------------------------------------------------
-- FFI

foreign import _get :: String -> Effect String
foreign import _set :: String -> String -> Effect Unit
foreign import _remove :: String -> Effect Unit
