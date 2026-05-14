{-# LANGUAGE StrictData #-}

{- |
Module      : Amaru.Treasury.Tx.SwapCancel.Datum
Description : Safe parser for Amaru SundaeSwap cancel datums
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Parses only the subset of SundaeSwap V3 order datums that Amaru swap
builders emit: legacy @AllOf@ owner policies over all treasury owners,
the current @AtLeast 2@ owner policy over all treasury owners, and a
fixed destination whose payment credential is the treasury script hash.
Unsupported owner forms fail closed.
-}
module Amaru.Treasury.Tx.SwapCancel.Datum
    ( ParsedSwapOrderDatum (..)
    , ParsedOwnerPolicy (..)
    , SwapOrderDatumError (..)
    , ownerPolicyCandidateSigners
    , ownerPolicyRequiredCount
    , parseSwapOrderDatum
    , renderSwapOrderDatumError
    , validateSwapOrderDatum
    ) where

import Cardano.Crypto.Hash.Class
    ( hashFromBytes
    , hashToBytes
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    )
import Cardano.Ledger.Keys (KeyRole (..))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import PlutusCore.Data (Data (..))

-- | Supported Amaru cancel-owner policies found in order datums.
data ParsedOwnerPolicy
    = OwnerAllOf ![KeyHash Guard]
    | OwnerAtLeast !Integer ![KeyHash Guard]
    deriving stock (Eq, Show)

-- | Parsed fields needed to cancel an Amaru-generated order safely.
data ParsedSwapOrderDatum = ParsedSwapOrderDatum
    { parsedOrderOwnerPolicy :: !ParsedOwnerPolicy
    -- ^ Parsed owner policy controlling cancel authority.
    , parsedOrderDestinationScript :: !ScriptHash
    -- ^ Payment script hash of the fixed destination.
    }
    deriving stock (Eq, Show)

-- | Validation failures for the supported order-datum subset.
data SwapOrderDatumError
    = MalformedOrderDatum
    | UnsupportedOwnerPolicy
    | MalformedOwnerKeyHash
    | MalformedDestination
    | OrderOwnerMismatch ![KeyHash Guard] ![KeyHash Guard]
    | OrderDestinationMismatch !ScriptHash !ScriptHash
    deriving stock (Eq, Show)

-- | Parse the supported Amaru subset of SundaeSwap V3 order datums.
parseSwapOrderDatum
    :: Data
    -> Either SwapOrderDatumError ParsedSwapOrderDatum
parseSwapOrderDatum = \case
    Constr 0 [_poolIdent, owner, _fee, destination, _details, _extension] ->
        ParsedSwapOrderDatum
            <$> parseOwner owner
            <*> parseDestination destination
    _ -> Left MalformedOrderDatum

{- | Parse and compare the owner and destination against values derived
from the selected treasury metadata.
-}
validateSwapOrderDatum
    :: [KeyHash Guard]
    -- ^ Expected owner signer hashes.
    -> ScriptHash
    -- ^ Expected treasury script hash.
    -> Data
    -> Either SwapOrderDatumError ParsedSwapOrderDatum
validateSwapOrderDatum expectedOwners expectedDestination datum = do
    parsed <- parseSwapOrderDatum datum
    validateOwnerPolicy expectedOwners (parsedOrderOwnerPolicy parsed)
    if parsedOrderDestinationScript parsed == expectedDestination
        then pure parsed
        else
            Left $
                OrderDestinationMismatch
                    expectedDestination
                    (parsedOrderDestinationScript parsed)

-- | Render an operator-facing datum validation failure.
renderSwapOrderDatumError :: SwapOrderDatumError -> Text
renderSwapOrderDatumError = \case
    MalformedOrderDatum ->
        "malformed order datum; expected SundaeSwap V3 order datum"
    UnsupportedOwnerPolicy ->
        "unsupported owner policy; expected Amaru AllOf signatures or AtLeast 2 of all owner signatures"
    MalformedOwnerKeyHash ->
        "malformed owner key hash; expected 28-byte verification key hash"
    MalformedDestination ->
        "malformed order destination; expected fixed script destination"
    OrderOwnerMismatch expected actual ->
        "order owner mismatch; expected "
            <> renderKeyHashList expected
            <> "; actual "
            <> renderKeyHashList actual
    OrderDestinationMismatch expected actual ->
        "order destination mismatch; expected "
            <> renderScriptHash expected
            <> "; actual "
            <> renderScriptHash actual

-- | Candidate signer key hashes encoded by a supported owner policy.
ownerPolicyCandidateSigners :: ParsedOwnerPolicy -> [KeyHash Guard]
ownerPolicyCandidateSigners = \case
    OwnerAllOf signers -> signers
    OwnerAtLeast _ signers -> signers

-- | Minimum number of candidate signers needed to satisfy the policy.
ownerPolicyRequiredCount :: ParsedOwnerPolicy -> Int
ownerPolicyRequiredCount = \case
    OwnerAllOf signers -> length signers
    OwnerAtLeast required _ -> fromInteger required

validateOwnerPolicy
    :: [KeyHash Guard]
    -> ParsedOwnerPolicy
    -> Either SwapOrderDatumError ()
validateOwnerPolicy expectedOwners = \case
    OwnerAllOf actualOwners
        | actualOwners == expectedOwners -> Right ()
        | otherwise ->
            Left $
                OrderOwnerMismatch expectedOwners actualOwners
    OwnerAtLeast required actualOwners
        | required /= 2 -> Left UnsupportedOwnerPolicy
        | actualOwners == expectedOwners -> Right ()
        | otherwise ->
            Left $
                OrderOwnerMismatch expectedOwners actualOwners

parseOwner :: Data -> Either SwapOrderDatumError ParsedOwnerPolicy
parseOwner = \case
    Constr 1 [List signers]
        | null signers -> Left UnsupportedOwnerPolicy
        | otherwise -> OwnerAllOf <$> traverse parseSignature signers
    Constr 3 [I required, List signers]
        | null signers -> Left UnsupportedOwnerPolicy
        | required <= 0 -> Left UnsupportedOwnerPolicy
        | required > toInteger (length signers) ->
            Left UnsupportedOwnerPolicy
        | otherwise ->
            OwnerAtLeast required <$> traverse parseSignature signers
    _ -> Left UnsupportedOwnerPolicy

parseSignature :: Data -> Either SwapOrderDatumError (KeyHash Guard)
parseSignature = \case
    Constr 0 [B bs] ->
        maybe
            (Left MalformedOwnerKeyHash)
            Right
            (keyHashFromBytes bs)
    _ -> Left UnsupportedOwnerPolicy

parseDestination :: Data -> Either SwapOrderDatumError ScriptHash
parseDestination = \case
    Constr 0 [address, _datum] -> parseAddress address
    _ -> Left MalformedDestination

parseAddress :: Data -> Either SwapOrderDatumError ScriptHash
parseAddress = \case
    Constr 0 [paymentCredential, _stakeCredential] ->
        parsePaymentCredential paymentCredential
    _ -> Left MalformedDestination

parsePaymentCredential
    :: Data
    -> Either SwapOrderDatumError ScriptHash
parsePaymentCredential = \case
    Constr 1 [B bs] ->
        maybe
            (Left MalformedDestination)
            Right
            (scriptHashFromBytes bs)
    _ -> Left MalformedDestination

keyHashFromBytes :: ByteString -> Maybe (KeyHash Guard)
keyHashFromBytes bs
    | BS.length bs == 28 = KeyHash <$> hashFromBytes bs
    | otherwise = Nothing

scriptHashFromBytes :: ByteString -> Maybe ScriptHash
scriptHashFromBytes bs
    | BS.length bs == 28 = ScriptHash <$> hashFromBytes bs
    | otherwise = Nothing

renderKeyHashList :: [KeyHash Guard] -> Text
renderKeyHashList keys =
    "[" <> T.intercalate "," (renderKeyHash <$> keys) <> "]"

renderKeyHash :: KeyHash Guard -> Text
renderKeyHash (KeyHash h) =
    TE.decodeUtf8 (B16.encode (hashToBytes h))

renderScriptHash :: ScriptHash -> Text
renderScriptHash (ScriptHash h) =
    TE.decodeUtf8 (B16.encode (hashToBytes h))
