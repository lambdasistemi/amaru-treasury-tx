{- |
Module      : Amaru.Treasury.LedgerParse
Description : Lift metadata.json strings to ledger types
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The 'Amaru.Treasury.Metadata' parser keeps every
hex/bech32/@txid#ix@ reference as 'Text'. This module
turns those into the ledger types the per-action
builders need:

* 'TxIn' from a @\"txid#ix\"@ string,
* 'KeyHash' \''Witness' from 28-byte hex,
* 'ScriptHash' from 28-byte hex.

Bech32 address decoding is deliberately left to the
consumer module that needs it (will land alongside the
first builder in Phase 3 US1 — adding @bech32@ as a dep
prematurely would gate this PR on a feature it doesn't
need).
-}
module Amaru.Treasury.LedgerParse
    ( txInFromText
    , keyHashFromHex
    , scriptHashFromHex
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as T
import Text.Read (readMaybe)

import Cardano.Crypto.Hash.Class
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    )
import Cardano.Ledger.BaseTypes (mkTxIxPartial)
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

-- | Parse a @"txid#ix"@ reference (matches @journal\/2026\/metadata.json@).
txInFromText :: Text -> Either String TxIn
txInFromText t = case T.splitOn "#" t of
    [txidT, ixT] -> do
        h <- hashFromHex 32 txidT
        ix <-
            maybe
                (Left $ "invalid index: " <> T.unpack ixT)
                Right
                (readMaybe (T.unpack ixT))
        Right $ TxIn (TxId (unsafeMakeSafeHash h)) (mkTxIxPartial ix)
    _ -> Left $ "expected 'txid#ix', got: " <> T.unpack t

{- | Parse a 28-byte verification-key hash (hex).

Returned in the 'Witness' 'KeyRole', matching the role
the @cardano-node-clients@ TxBuild DSL expects for
@requireSignature@.
-}
keyHashFromHex :: Text -> Either String (KeyHash Witness)
keyHashFromHex t = KeyHash <$> hashFromHex 28 t

-- | Parse a 28-byte script hash (hex).
scriptHashFromHex :: Text -> Either String ScriptHash
scriptHashFromHex t = ScriptHash <$> hashFromHex 28 t

-- ------------------------------------------------------------
-- Helpers
-- ------------------------------------------------------------

-- | Decode @hex@ into exactly @n@ bytes, then build the 'Hash'.
hashFromHex
    :: forall h a
     . (HashAlgorithm h)
    => Int
    -> Text
    -> Either String (Hash h a)
hashFromHex expected t = do
    bs <- decodeHex t
    if BS.length bs == expected
        then case hashFromBytes bs of
            Just h -> Right h
            Nothing ->
                Left $
                    "hash bytes do not match the expected size ("
                        <> show expected
                        <> ")"
        else
            Left $
                "expected "
                    <> show expected
                    <> " hex bytes, got "
                    <> show (BS.length bs)

-- | Strict hex → bytes via 'Data.ByteString.Base16.decode'.
decodeHex :: Text -> Either String ByteString
decodeHex = B16.decode . T.encodeUtf8
