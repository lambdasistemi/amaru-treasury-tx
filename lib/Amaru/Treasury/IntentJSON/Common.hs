{- |
Module      : Amaru.Treasury.IntentJSON.Common
Description : Shared parser helpers for the unified intent
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Bech32 + hex parsers shared by the unified intent JSON
parser and by every per-action wizard.
-}
module Amaru.Treasury.IntentJSON.Common
    ( parseAddr
    , parseTxIn
    , parseRewardAccountForNetwork
    , parseGuardKeyHash
    , parseNetwork
    , decodeHexBytes
    , decodeHexBytesAny
    , mkHash
    , readEither
    ) where

import Cardano.Crypto.Hash.Class
    ( Hash
    , HashAlgorithm
    , hashFromBytes
    , hashSize
    )
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , decodeAddrEither
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , mkTxIxPartial
    )
import Cardano.Ledger.Credential (Credential (..))
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , unsafeMakeSafeHash
    )
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Codec.Binary.Bech32 qualified as Bech32
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

-- | Bech32-decode a textual @addr…@ to a typed 'Addr'.
parseAddr :: Text -> Either String Addr
parseAddr t = do
    raw <-
        case Bech32.decodeLenient t of
            Right (_hrp, dp) ->
                case Bech32.dataPartToBytes dp of
                    Just bs -> Right bs
                    Nothing -> Left "bech32 data-part decode"
            Left e -> Left ("bech32: " <> show e)
    case decodeAddrEither raw of
        Right a -> Right a
        Left e -> Left ("address: " <> show e)

-- | Parse a @\<txid hex\>#\<ix\>@ string into a 'TxIn'.
parseTxIn :: Text -> Either String TxIn
parseTxIn t = case T.splitOn "#" t of
    [hHex, ixT] -> do
        ix <- readEither "txix" (T.unpack ixT)
        bs <- decodeHexBytes 32 hHex
        h <- mkHash bs
        Right
            ( TxIn
                (TxId (unsafeMakeSafeHash h))
                (mkTxIxPartial (ix :: Integer))
            )
    _ ->
        Left
            ( "txIn must be \"<hex>#<ix>\", got "
                <> T.unpack t
            )

{- | Parse a reward-account credential as a 28-byte hex
stake-script hash on the ledger network named by the
unified intent. @preprod@ and @preview@ both map to the
ledger's 'Testnet' constructor; @devnet@ does the same
for the local smoke network.
-}
parseRewardAccountForNetwork
    :: Text -> Text -> Either String AccountAddress
parseRewardAccountForNetwork networkText t = do
    network <- parseNetwork networkText
    bs <- decodeHexBytes 28 t
    h <- mkHash bs
    Right
        ( AccountAddress
            network
            (AccountId (ScriptHashObj (ScriptHash h)))
        )

parseNetwork :: Text -> Either String Network
parseNetwork t =
    case T.toLower t of
        "mainnet" -> Right Mainnet
        "preprod" -> Right Testnet
        "preview" -> Right Testnet
        "devnet" -> Right Testnet
        other ->
            Left
                ( "unknown network for reward account: "
                    <> T.unpack other
                )

{- | Parse a 28-byte hex into a 'KeyHash' under the
'Guard' role used for required signers.
-}
parseGuardKeyHash
    :: Text -> Either String (KeyHash Guard)
parseGuardKeyHash t = do
    bs <- decodeHexBytes 28 t
    KeyHash <$> mkHash bs

-- | Decode hex with an exact byte-length expectation.
decodeHexBytes
    :: Int -> Text -> Either String ByteString
decodeHexBytes expected t =
    case B16.decode (TE.encodeUtf8 t) of
        Right bs
            | BS.length bs == expected -> Right bs
            | otherwise ->
                Left
                    ( "expected "
                        <> show expected
                        <> " bytes, got "
                        <> show (BS.length bs)
                    )
        Left e -> Left ("hex decode: " <> e)

-- | Decode hex without a byte-length expectation.
decodeHexBytesAny :: Text -> Either String ByteString
decodeHexBytesAny t =
    case B16.decode (TE.encodeUtf8 t) of
        Right bs -> Right bs
        Left e -> Left ("hex decode: " <> e)

{- | Turn a byte string into a hash of algorithm @h@. A byte
string whose length differs from the digest size of @h@
yields a 'Left' naming the expected and the actual length.
-}
mkHash
    :: forall h a
     . (HashAlgorithm h)
    => ByteString
    -> Either String (Hash h a)
mkHash bs = maybe (Left mismatch) Right (hashFromBytes bs)
  where
    mismatch =
        "hash: expected "
            <> show (hashSize (Proxy @h))
            <> " bytes, got "
            <> show (BS.length bs)

-- | 'reads'-based parse with a typed error message.
readEither
    :: (Read a) => String -> String -> Either String a
readEither what s = case reads s of
    [(v, "")] -> Right v
    _ -> Left ("could not parse " <> what <> ": " <> s)
