{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.Attach
Description : Stateless witness attachment endpoint helper
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pure helper behind @POST \/v1\/attach@. It accepts an unsigned Conway
transaction and one or more detached vkey witnesses as CBOR hex,
reuses the CLI's witness decoder/merger, and returns signed
transaction CBOR hex without consulting any server-side state.
-}
module Amaru.Treasury.Api.Attach
    ( attachTx
    ) where

import Data.Bifunctor (first)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as TE

import Cardano.Ledger.Keys (KeyRole (Witness), WitVKey)

import Amaru.Treasury.Api.Types
    ( ApiError (..)
    , AttachRequest (..)
    , AttachResponse (..)
    )
import Amaru.Treasury.Tx.AttachWitness
    ( AttachError (..)
    , attachWitnesses
    , decodeUnsignedTxHex
    , decodeVKeyWitnessHex
    , encodeSignedTxHex
    , renderAttachError
    )

-- | Decode an unsigned transaction, merge witnesses, and re-encode it.
attachTx :: AttachRequest -> Either ApiError AttachResponse
attachTx req
    | null (arWitnesses req) =
        Left
            ApiError
                { aeMessage = "at least one witness is required"
                , aeField = Just "witnesses"
                }
    | otherwise = do
        tx <-
            mapAttachError $
                decodeUnsignedTxHex (TE.encodeUtf8 (arUnsignedTx req))
        witnesses <-
            traverse
                decodeWitness
                (zip [1 :: Int ..] (arWitnesses req))
        let signedTx = attachWitnesses (Set.fromList witnesses) tx
        pure
            AttachResponse
                { arCborHex =
                    TE.decodeUtf8 (encodeSignedTxHex signedTx)
                }

decodeWitness :: (Int, Text) -> Either ApiError (WitVKey Witness)
decodeWitness (ix, witnessHex) =
    mapAttachError $
        decodeVKeyWitnessHex ix (TE.encodeUtf8 witnessHex)

mapAttachError :: Either AttachError a -> Either ApiError a
mapAttachError = first attachError

attachError :: AttachError -> ApiError
attachError err =
    ApiError
        { aeMessage = renderAttachError err
        , aeField = Just (attachErrorField err)
        }

attachErrorField :: AttachError -> Text
attachErrorField = \case
    AttachDecodeTxFailed{} -> "unsignedTx"
    AttachInvalidHex "unsigned transaction" _ -> "unsignedTx"
    AttachInvalidHex{} -> "witnesses"
    AttachDecodeWitnessFailed{} -> "witnesses"
