{- |
Module      : Amaru.Treasury.AuxData
Description : CIP-1694 rationale metadatum (label 1694)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Mirrors
[`journal/2026/lib/treasury_instance_metadata.sh`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/lib/treasury_instance_metadata.sh)
+
[`journal/2026/rationale.json`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/rationale.json):
the CLI's @--metadata-json-file@ payload at label 1694
is the static rationale tree with the @instance@ string
patched in from the registry NFT's policy id.

The fields are emitted in JSON-source order
(@body@, @\@context@, @instance@, @hashAlgorithm@), matching
@cardano-cli@'s @MetadataJsonNoSchema@ encoder so the
resulting @aux_data_hash@ is byte-identical.
-}
module Amaru.Treasury.AuxData
    ( -- * Label
      label1694

      -- * Builders
    , swapRationaleMetadatum
    , disburseRationaleMetadatum

      -- * Field-level helpers
    , RationaleBody (..)
    , RationaleReference (..)
    , rationaleMetadatum
    , splitUri
    , splitLabel
    , chunkRationale
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)

import Cardano.Ledger.Metadata (Metadatum (..))

-- | CIP-1694 rationale label.
label1694 :: Word64
label1694 = 1694

{- | One entry of @body.references[]@.

Each reference is a typed link to an external document
(contract, invoice, signed email, …) and is emitted on
chain as
@{ "uri": [chunk, …], "@type": "Other", "label": [chunk, …] }@.

The 'rrUri' and 'rrLabel' fields hold the full,
unchunked source strings — the metadatum encoder splits
them via 'splitUri' \/ 'splitLabel' to respect the
ledger's 64-byte metadatum-string cap.
-}
data RationaleReference = RationaleReference
    { rrUri :: !Text
    -- ^ full URI (e.g. @"ipfs://bafy…"@, @"https://…"@).
    , rrType :: !Text
    -- ^ reference @\@type@ tag (defaults to @"Other"@
    --   per the d6c14625 precedent).
    , rrLabel :: !Text
    -- ^ human-readable label (split on first @" - "@).
    }
    deriving (Eq, Show)

{- | Variable fields of the rationale @body@ object.

The closing @hashAlgorithm@ + @\@context@ are pinned to
the SundaeSwap rationale spec; only the user-facing
copy and the optional 'rbReferences' list vary between
events.
-}
data RationaleBody = RationaleBody
    { rbEvent :: !Text
    -- ^ e.g. @"disburse"@, @"reorganize"@
    , rbLabel :: !Text
    -- ^ short human-readable label
    , rbReferences :: ![RationaleReference]
    -- ^ optional list of typed external references;
    --   defaults to @[]@ which serialises to @List []@
    --   (the shape every prior fixture pins).
    , rbDescription :: ![Text]
    -- ^ rationale paragraphs
    , rbDestinationLabel :: !Text
    -- ^ short label of the funds' destination
    , rbJustification :: ![Text]
    -- ^ justification paragraphs
    }

{- | Build the full rationale metadatum at label 1694.

@registryPolicyId@ is the raw 28-byte registry NFT
policy id; it is hex-encoded and embedded as the
@instance@ string (matching @ccli query utxo | jq
'keys[0]'@ in the bash recipe).
-}
rationaleMetadatum
    :: RationaleBody
    -- ^ free-text rationale fields
    -> ByteString
    -- ^ registry policy id (raw 28 bytes)
    -> Metadatum
rationaleMetadatum body registryPolicyId =
    Map
        [ (S "body", bodyM)
        ,
            ( S "@context"
            , List
                [ S
                    "https://github.com/SundaeSwap-finance/treasury-contracts/blob/"
                , S "ad4316d0d36cdef780f85fc2ec8b307e645ddc2a"
                , S "/offchain/src/metadata/spec.md"
                ]
            )
        , (S "instance", S (hexText registryPolicyId))
        , (S "hashAlgorithm", S "blake2b-256")
        ]
  where
    bodyM =
        Map
            [ (S "event", S (rbEvent body))
            , (S "label", S (rbLabel body))
            ,
                ( S "references"
                , List
                    (map referenceM (rbReferences body))
                )
            ,
                ( S "description"
                , List
                    ( map
                        S
                        (concatMap chunkRationale (rbDescription body))
                    )
                )
            ,
                ( S "destination"
                , Map [(S "label", S (rbDestinationLabel body))]
                )
            ,
                ( S "justification"
                , List
                    ( map
                        S
                        (concatMap chunkRationale (rbJustification body))
                    )
                )
            ]

{- | Render one 'RationaleReference' as the per-reference
map @{ "uri": [...], "@type": ..., "label": [...] }@.

The split functions raise via 'error' on chunk overflow
— validation is expected to have happened at the
parser layer (JSON FromJSON \/ optparse-applicative).
-}
referenceM :: RationaleReference -> Metadatum
referenceM r =
    Map
        [ (S "uri", List (map S (mustSplit "uri" (splitUri (rrUri r)))))
        , (S "@type", S (rrType r))
        ,
            ( S "label"
            , List (map S (mustSplit "label" (splitLabel (rrLabel r))))
            )
        ]
  where
    mustSplit :: String -> Either String [Text] -> [Text]
    mustSplit field = either (\e -> error (field <> ": " <> e)) id

{- | Split a URI into chunks compatible with the ledger's
64-byte metadatum-string cap.

* @ipfs://…@ URIs split into @["ipfs://", "<rest>"]@
  (the d6c14625 mainnet precedent).
* All other URIs emit a single-element list.

Returns @Left@ when any chunk exceeds 64 UTF-8 bytes.
-}
splitUri :: Text -> Either String [Text]
splitUri uri
    | ipfsPrefix `T.isPrefixOf` uri =
        checkChunks
            [ipfsPrefix, T.drop (T.length ipfsPrefix) uri]
    | otherwise = checkChunks [uri]
  where
    ipfsPrefix :: Text
    ipfsPrefix = "ipfs://"

{- | Split a label on the first @\" - \"@ (space-dash-
space) separator.

* @\"<lhs> - <rhs>\"@ splits to @[lhs, " - ", rhs]@.
* Labels without the separator emit a single-element
  list.

Returns @Left@ when any chunk exceeds 64 UTF-8 bytes.
-}
splitLabel :: Text -> Either String [Text]
splitLabel lbl =
    case T.breakOn sep lbl of
        (_, "") -> checkChunks [lbl]
        (lhs, rest) ->
            checkChunks
                [lhs, sep, T.drop (T.length sep) rest]
  where
    sep :: Text
    sep = " - "

{- | Reject any chunk whose UTF-8 encoding is over the
ledger's 64-byte metadatum-string cap.
-}
checkChunks :: [Text] -> Either String [Text]
checkChunks chunks =
    case filter overCap chunks of
        [] -> Right chunks
        (bad : _) ->
            Left
                ( "chunk exceeds 64 bytes: "
                    <> show bad
                )
  where
    overCap :: Text -> Bool
    overCap = (> 64) . BS.length . TE.encodeUtf8

{- | Split a free-text rationale string into chunks each at
most 64 UTF-8 bytes — the ledger's per-metadatum-string cap.

Splitting is on UTF-8 byte length, never across a Unicode
code point, so multi-byte characters (e.g. @\"₳\"@) stay
intact. A string already within the cap is returned
unchanged as a single-element list, so existing
short-rationale transactions are byte-identical. Used for
@body.description@ and @body.justification@, which the
metadatum schema already models as chunk lists.
-}
chunkRationale :: Text -> [Text]
chunkRationale t
    | utf8Len t <= 64 = [t]
    | otherwise =
        let prefix = greedyPrefix t
        in  prefix : chunkRationale (T.drop (T.length prefix) t)
  where
    utf8Len :: Text -> Int
    utf8Len = BS.length . TE.encodeUtf8

    -- Longest leading substring whose UTF-8 encoding is
    -- <= 64 bytes. A single code point is at most 4 bytes,
    -- so the loop always makes progress.
    greedyPrefix :: Text -> Text
    greedyPrefix s = go (T.length s)
      where
        go k
            | k <= 1 = T.take 1 s
            | utf8Len (T.take k s) <= 64 = T.take k s
            | otherwise = go (k - 1)

{- | The rationale used by @swap.sh@: a "disburse" event
labelled @"Swap ADA\<-\>USDM"@ targeting Network
Compliance's treasury, with the description and
justification copy preserved verbatim from the on-chain
fixture.
-}
swapRationaleMetadatum
    :: Text
    -- ^ description (e.g. @"Swapping ADA for $100k at a rate of $0.245 per ADA"@)
    -> Text
    -- ^ destination label (e.g. @"Network Compliance's treasury"@)
    -> Text
    -- ^ justification copy
    -> ByteString
    -- ^ registry policy id (raw 28 bytes)
    -> Metadatum
swapRationaleMetadatum description destination justification =
    rationaleMetadatum
        RationaleBody
            { rbEvent = "disburse"
            , rbLabel = "Swap ADA<->USDM"
            , rbReferences = []
            , rbDescription = [description]
            , rbDestinationLabel = destination
            , rbJustification = [justification]
            }

{- | Generic ADA disburse rationale: a "disburse" event
with caller-supplied label and copy.
-}
disburseRationaleMetadatum
    :: Text
    -- ^ short event label
    -> Text
    -- ^ description copy
    -> Text
    -- ^ destination label
    -> Text
    -- ^ justification copy
    -> ByteString
    -- ^ registry policy id (raw 28 bytes)
    -> Metadatum
disburseRationaleMetadatum lbl description destination justification =
    rationaleMetadatum
        RationaleBody
            { rbEvent = "disburse"
            , rbLabel = lbl
            , rbReferences = []
            , rbDescription = [description]
            , rbDestinationLabel = destination
            , rbJustification = [justification]
            }

hexText :: ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode
