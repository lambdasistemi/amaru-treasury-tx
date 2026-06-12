{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Api.VerifyWitness
Description : Stateless detached witness verification endpoint
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pure helper behind @POST \/v1\/verify-witness@. It verifies a
detached Conway vkey witness against an unsigned transaction body hash
and checks that the witness key hash is one of the transaction's
required signer hashes.
-}
module Amaru.Treasury.Api.VerifyWitness
    ( verifyWitness
    ) where

import Cardano.Crypto.DSIGN.Class (verifySignedDSIGN)
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , extractHash
    , hashAnnotated
    )
import Cardano.Ledger.Keys
    ( KeyRole (..)
    , VKey (..)
    , WitVKey (..)
    , hashKey
    )
import Cardano.Tx.Ledger (ConwayTx)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))

import Amaru.Treasury.Api.Types
    ( VerifyWitnessRequest (..)
    , VerifyWitnessResponse (..)
    )
import Amaru.Treasury.Tx.AttachWitness
    ( decodeVKeyWitnessHex
    , renderAttachError
    )
import Amaru.Treasury.Tx.Witness
    ( TransactionSigningFacts (..)
    , decodeWitnessTransaction
    , renderGuardKeyHash
    , renderTxWitnessError
    , witnessTransactionFacts
    )

-- | Verify a detached witness against an unsigned Conway transaction.
verifyWitness :: VerifyWitnessRequest -> VerifyWitnessResponse
verifyWitness (VerifyWitnessRequest unsignedTx witnessHex) =
    case decodeWitnessTransaction (TE.encodeUtf8 unsignedTx) of
        Left err ->
            notOk $
                "malformed unsigned transaction: "
                    <> renderTxWitnessError err
        Right tx ->
            case decodeVKeyWitnessHex 1 (TE.encodeUtf8 witnessHex) of
                Left err ->
                    notOk $
                        "malformed witness: "
                            <> renderAttachError err
                Right witness ->
                    verifyDecodedWitness tx witness

verifyDecodedWitness
    :: ConwayTx
    -> WitVKey Witness
    -> VerifyWitnessResponse
verifyDecodedWitness tx (WitVKey vkey signature) =
    case verifySignedDSIGN () (unVKey vkey) bodyHash signature of
        Left _ -> notOk "signature does not verify for transaction body hash"
        Right () ->
            if Set.member signerKeyHash requiredSigners
                then
                    VerifyWitnessResponse
                        { vwrOk = True
                        , vwrSignerKeyHash =
                            Just (renderGuardKeyHash signerKeyHash)
                        , vwrReason = Nothing
                        }
                else
                    notOk $
                        "signer key hash "
                            <> renderGuardKeyHash signerKeyHash
                            <> " is not in transaction required signer hashes "
                            <> renderKeyHashSet requiredSigners
  where
    bodyHash = extractHash (hashAnnotated (tx ^. bodyTxL))
    facts = witnessTransactionFacts tx
    requiredSigners = tsfRequiredSigners facts
    signerKeyHash = witnessKeyHashToGuard (hashKey vkey)

witnessKeyHashToGuard :: KeyHash Witness -> KeyHash Guard
witnessKeyHashToGuard (KeyHash h) = KeyHash h

renderKeyHashSet :: Set.Set (KeyHash Guard) -> Text
renderKeyHashSet keys =
    "["
        <> T.intercalate
            ","
            (renderGuardKeyHash <$> Set.toAscList keys)
        <> "]"

notOk :: Text -> VerifyWitnessResponse
notOk reason =
    VerifyWitnessResponse
        { vwrOk = False
        , vwrSignerKeyHash = Nothing
        , vwrReason = Just reason
        }
