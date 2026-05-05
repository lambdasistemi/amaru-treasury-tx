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
    , rationaleMetadatum
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)

import Cardano.Ledger.Metadata (Metadatum (..))

-- | CIP-1694 rationale label.
label1694 :: Word64
label1694 = 1694

{- | Variable fields of the rationale @body@ object.

The static fields (@references@) and the closing
@hashAlgorithm@ + @\@context@ are pinned to the
SundaeSwap rationale spec; only the user-facing copy
varies between events.
-}
data RationaleBody = RationaleBody
    { rbEvent :: !Text
    -- ^ e.g. @"disburse"@, @"reorganize"@
    , rbLabel :: !Text
    -- ^ short human-readable label
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
            , (S "references", List [])
            ,
                ( S "description"
                , List (map S (rbDescription body))
                )
            ,
                ( S "destination"
                , Map [(S "label", S (rbDestinationLabel body))]
                )
            ,
                ( S "justification"
                , List (map S (rbJustification body))
                )
            ]

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
            , rbDescription = [description]
            , rbDestinationLabel = destination
            , rbJustification = [justification]
            }

hexText :: ByteString -> Text
hexText = TE.decodeUtf8 . B16.encode
