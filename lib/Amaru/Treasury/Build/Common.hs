{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TupleSections #-}

{- |
Module      : Amaru.Treasury.Build.Common
Description : Shared helpers for treasury transaction build runners
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Build.Common
    ( alignCardanoCliBuildFee
    , collateralInputFrom
    , indexedOutputAt
    , indexedOutputs
    , strictMaybe
    , txIdText
    ) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Data.ByteString.Base16 qualified as B16
import Data.Foldable (toList)
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as Text

import Cardano.Ledger.Alonzo.PParams (ppCollateralPercentageL)
import Cardano.Ledger.Api.Tx (estimateMinFeeTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( Withdrawals (..)
    , collateralInputsTxBodyL
    , collateralReturnTxBodyL
    , feeTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    , referenceInputsTxBodyL
    , reqSignerHashesTxBodyL
    , totalCollateralTxBodyL
    , withdrawalsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL)
import Cardano.Ledger.BaseTypes (StrictMaybe (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (PParams, TopTx, TxBody, bodyTxL)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn)
import Cardano.Node.Client.Balance (refScriptsSize)
import Cardano.Node.Client.Ledger (ConwayTx)
import Lens.Micro ((&), (.~), (^.))

txIdText :: ConwayTx -> Text
txIdText tx =
    case txIdTx tx of
        TxId h ->
            Text.decodeUtf8 $
                B16.encode $
                    hashToBytes $
                        extractHash h

indexedOutputAt
    :: Int
    -> TxBody TopTx ConwayEra
    -> Maybe (Int, TxOut ConwayEra)
indexedOutputAt index body =
    (index,) <$> listToMaybe (drop index outputs)
  where
    outputs = toList (body ^. outputsTxBodyL)

indexedOutputs
    :: Int
    -> Int
    -> TxBody TopTx ConwayEra
    -> [(Int, TxOut ConwayEra)]
indexedOutputs start count body =
    take count . drop start . zip [0 ..] $
        toList (body ^. outputsTxBodyL)

collateralInputFrom
    :: TxBody TopTx ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> Maybe (TxIn, TxOut ConwayEra)
collateralInputFrom body =
    find
        ( \(txIn, _) ->
            Set.member txIn (body ^. collateralInputsTxBodyL)
        )

strictMaybe :: StrictMaybe a -> Maybe a
strictMaybe = \case
    SNothing -> Nothing
    SJust value -> Just value

{- | Match @cardano-cli transaction build@'s conservative
key-witness fee estimate for bash-derived golden oracles.

The upstream bash recipes do not pass
@--witness-override@, so @cardano-cli@ prices the unsigned
body with its default key-witness estimate. For the
current swap/disburse oracles this is seven witnesses,
not the single dummy witness used by
@cardano-node-clients@' generic balancer. Without this
adjustment the body shape and ex-units match the bash
artifact, but the fee, collateral total, collateral
return, and change output are all under the
cardano-cli output.
-}
alignCardanoCliBuildFee
    :: PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ resolved reference inputs, for Conway reference-script fee
    -> Int
    -- ^ change output index appended by the balancer
    -> ConwayTx
    -> Either String ConwayTx
alignCardanoCliBuildFee pp refUtxos changeIx =
    go (5 :: Int)
  where
    go 0 _ =
        Left "fee did not converge"
    go n tx =
        let body = tx ^. bodyTxL
            Withdrawals withdrawals =
                body ^. withdrawalsTxBodyL
            refBytes =
                refScriptsSize
                    (body ^. referenceInputsTxBodyL)
                    refUtxos
            witnessCount =
                1
                    + Set.size (body ^. inputsTxBodyL)
                    + Set.size (body ^. collateralInputsTxBodyL)
                    + Set.size
                        (body ^. reqSignerHashesTxBodyL)
                    + Map.size withdrawals
            target =
                estimateMinFeeTx pp tx witnessCount 0 refBytes
            current = body ^. feeTxBodyL
        in  if target <= current
                then Right tx
                else do
                    bumped <-
                        bumpBuildFee
                            pp
                            changeIx
                            current
                            target
                            tx
                    go (n - 1) bumped

bumpBuildFee
    :: PParams ConwayEra
    -> Int
    -> Coin
    -> Coin
    -> ConwayTx
    -> Either String ConwayTx
bumpBuildFee pp changeIx oldFee newFee tx = do
    let feeDelta = unCoin newFee - unCoin oldFee
    outputs' <-
        adjustOutputCoin
            changeIx
            feeDelta
            (tx ^. bodyTxL . outputsTxBodyL)
    bodyWithFee <-
        adjustCollateralFields
            pp
            newFee
            ( tx
                ^. bodyTxL
            )
    Right $
        tx
            & bodyTxL .~ bodyWithFee
            & bodyTxL . feeTxBodyL .~ newFee
            & bodyTxL . outputsTxBodyL .~ outputs'

adjustOutputCoin
    :: Int
    -> Integer
    -> StrictSeq.StrictSeq (TxOut ConwayEra)
    -> Either String (StrictSeq.StrictSeq (TxOut ConwayEra))
adjustOutputCoin ix delta outs =
    case splitAt ix (toList outs) of
        (_, []) ->
            Left "change output index out of range"
        (before, changeOut : after) ->
            let Coin current = changeOut ^. coinTxOutL
            in  if current < delta
                    then Left "change output cannot cover fee bump"
                    else
                        Right $
                            StrictSeq.fromList $
                                before
                                    ++ [ changeOut
                                            & coinTxOutL
                                                .~ Coin
                                                    ( current
                                                        - delta
                                                    )
                                       ]
                                    ++ after

adjustCollateralFields
    :: PParams ConwayEra
    -> Coin
    -> TxBody TopTx ConwayEra
    -> Either String (TxBody TopTx ConwayEra)
adjustCollateralFields pp newFee body =
    case body ^. totalCollateralTxBodyL of
        SNothing -> Right body
        SJust oldTotal ->
            let newTotal = collateralFor newFee
                delta =
                    unCoin newTotal
                        - unCoin oldTotal
            in  case body ^. collateralReturnTxBodyL of
                    SNothing ->
                        Right $
                            body
                                & totalCollateralTxBodyL
                                    .~ SJust newTotal
                    SJust retOut -> do
                        let Coin retCoin =
                                retOut ^. coinTxOutL
                        if retCoin < delta
                            then
                                Left
                                    "collateral return cannot cover fee bump"
                            else
                                Right $
                                    body
                                        & totalCollateralTxBodyL
                                            .~ SJust newTotal
                                        & collateralReturnTxBodyL
                                            .~ SJust
                                                ( retOut
                                                    & coinTxOutL
                                                        .~ Coin
                                                            ( retCoin
                                                                - delta
                                                            )
                                                )
  where
    collateralFor (Coin f) =
        let pct =
                fromIntegral
                    (pp ^. ppCollateralPercentageL)
            ceilDiv a b = (a + b - 1) `div` b
        in  Coin (ceilDiv (f * pct) 100)
