{- |
Module      : Amaru.Treasury.IntentJSON.Common
Description : Shared parser helpers for the unified intent
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Bech32 + hex parsers shared by the unified intent JSON
parser and by every per-action wizard. Bodies are lifted
verbatim from
[`Amaru.Treasury.Tx.SwapIntentJSON`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapIntentJSON.hs)
in this commit; the originals there are deleted in T011
(this commit).
-}
module Amaru.Treasury.IntentJSON.Common
    ( parseAddr
    , parseTxIn
    , parseRewardAccount
    , parseGuardKeyHash
    , decodeHexBytes
    , decodeHexBytesAny
    , mkHash28
    , mkHash32
    , readEither
    ) where

import Cardano.Crypto.Hash.Class
    ( Hash
    , HashAlgorithm
    , hashFromBytes
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
import Data.Maybe (fromJust)
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
        Right
            ( TxIn
                (TxId (unsafeMakeSafeHash (mkHash32 bs)))
                (mkTxIxPartial (ix :: Integer))
            )
    _ ->
        Left
            ( "txIn must be \"<hex>#<ix>\", got "
                <> T.unpack t
            )

{- | Parse a reward-account credential as the 28-byte hex
of the stake-script hash. (Bech32 stake addresses are not
accepted at the JSON layer; the user supplies one hash,
not a full address.)
-}
parseRewardAccount :: Text -> Either String AccountAddress
parseRewardAccount t = do
    bs <- decodeHexBytes 28 t
    Right
        ( AccountAddress
            Mainnet
            ( AccountId
                ( ScriptHashObj
                    (ScriptHash (mkHash28 bs))
                )
            )
        )

{- | Parse a 28-byte hex into a 'KeyHash' under the
'Guard' role used for required signers.
-}
parseGuardKeyHash
    :: Text -> Either String (KeyHash Guard)
parseGuardKeyHash t = do
    bs <- decodeHexBytes 28 t
    Right (KeyHash (mkHash28 bs))

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

mkHash28 :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash28 = fromJust . hashFromBytes

mkHash32 :: (HashAlgorithm h) => ByteString -> Hash h a
mkHash32 = fromJust . hashFromBytes

-- | 'reads'-based parse with a typed error message.
readEither
    :: (Read a) => String -> String -> Either String a
readEither what s = case reads s of
    [(v, "")] -> Right v
    _ -> Left ("could not parse " <> what <> ": " <> s)
