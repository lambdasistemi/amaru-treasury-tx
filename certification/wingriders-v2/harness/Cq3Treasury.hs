{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- | CQ3 — the decisive seam, against the DEPLOYED Amaru treasury bytes.

The deployed @network_compliance@ treasury validator is
@32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d@, **PlutusV3**,
pinned from chain (its hash under the V3 tag reproduces the node-decoded
address credential; V1/V2 do not).

Order of business, same discipline as the pool replay:

1. replay a REAL treasury spend
   (@efff271aa02e9032aba0e5e9020c5840b2aa1b219c59f9f16e1d6e51071bea1e@)
   whose spent treasury input carries NO datum, and require GREEN;
2. only then mutate that input to CARRY a datum — the shape a WingRiders
   settlement to a script beneficiary necessarily produces — and see
   whether the unchanged validator still accepts it.

Until step 1 is green, step 2 means nothing.
-}
module Main (main) where

import Codec.Serialise (deserialise)
import Codec.Serialise qualified
import Control.Monad.Except (runExceptT)
import Control.Monad.Writer (runWriterT)
import Data.Aeson qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Int (Int64)
import Data.List (groupBy, sortOn)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import PlutusLedgerApi.Common
    ( EvaluationContext
    , ExBudget (..)
    , MajorProtocolVersion (..)
    , PlutusLedgerLanguage (..)
    , VerboseMode (..)
    , deserialiseScript
    , evaluateScriptRestricting
    )
import PlutusLedgerApi.V1.Interval
    ( Extended (..)
    , Interval (..)
    , LowerBound (..)
    , UpperBound (..)
    )
import PlutusLedgerApi.V1.Value (CurrencySymbol (..), TokenName (..), Value (..))
import PlutusLedgerApi.V3
    ( Address (..)
    , Credential (..)
    , Data (..)
    , Datum (..)
    , Lovelace (..)
    , OutputDatum (..)
    , POSIXTime (..)
    , PubKeyHash (..)
    , Redeemer (..)
    , ScriptContext (..)
    , ScriptHash (..)
    , ScriptInfo (..)
    , StakingCredential (..)
    , TxId (..)
    , TxInInfo (..)
    , TxInfo (..)
    , TxOut (..)
    , TxOutRef (..)
    , emptyMintValue
    , mkEvaluationContext
    , toData
    )
import PlutusTx.AssocMap qualified as AMap
import PlutusTx.Builtins qualified as B
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)

conwayPV :: MajorProtocolVersion
conwayPV = MajorProtocolVersion 10

ceilingBudget :: ExBudget
ceilingBudget = ExBudget 10_000_000_000 16_500_000

treasuryHash :: T.Text
treasuryHash = "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"

wdrlScriptHash :: T.Text
wdrlScriptHash = "a64d1b9e1aeffe54056034d84977061b45a92691efc282fbee3fc094"

unhex :: BS.ByteString -> BS.ByteString
unhex h = either (\e -> error ("bad hex: " <> e)) id (B16.decode h)

hx :: T.Text -> B.BuiltinByteString
hx = B.toBuiltin . unhex . TE.encodeUtf8

-- Reuse the pool harness's context JSON shape ------------------------------

data JUtxo = JUtxo
    { jTxHash :: T.Text
    , jIndex :: Integer
    , jPaymentKind :: T.Text
    , jPaymentHash :: T.Text
    , jStakeKind :: Maybe T.Text
    , jStakeHash :: Maybe T.Text
    , jLovelace :: Integer
    , jAssets :: [(T.Text, T.Text, Integer)]
    , jDatumHex :: Maybe T.Text
    , jRefScriptHash :: Maybe T.Text
    }

instance A.FromJSON JUtxo where
    parseJSON = A.withObject "JUtxo" $ \o ->
        JUtxo
            <$> o A..: "txHash"
            <*> o A..: "index"
            <*> o A..: "paymentKind"
            <*> o A..: "paymentHash"
            <*> o A..:? "stakeKind"
            <*> o A..:? "stakeHash"
            <*> o A..: "lovelace"
            <*> o A..: "assets"
            <*> o A..:? "datumHex"
            <*> o A..:? "refScriptHash"

data JCtx = JCtx
    { jValidFrom :: Integer
    , jValidTo :: Integer
    , jFee :: Integer
    , jInputs :: [JUtxo]
    , jRefInputs :: [JUtxo]
    , jOutputs :: [JUtxo]
    }

instance A.FromJSON JCtx where
    parseJSON = A.withObject "JCtx" $ \o ->
        JCtx
            <$> o A..: "validFrom"
            <*> o A..: "validTo"
            <*> o A..: "fee"
            <*> o A..: "inputs"
            <*> o A..: "refInputs"
            <*> o A..: "outputs"

utxoValue :: JUtxo -> Value
utxoValue JUtxo{..} =
    Value . AMap.unsafeFromList $
        (CurrencySymbol "", AMap.unsafeFromList [(TokenName "", jLovelace)])
            : [ (CurrencySymbol (hx p), AMap.unsafeFromList [(TokenName (hx n), q) | (_, n, q) <- grp])
              | grp@((p, _, _) : _) <- groupBy (\(a, _, _) (b, _, _) -> a == b) (sortOn (\(p, n, _) -> (p, n)) jAssets)
              ]

utxoAddress :: JUtxo -> Address
utxoAddress JUtxo{..} = Address payCred stakeCred
  where
    payCred
        | jPaymentKind == "script" = ScriptCredential (ScriptHash (hx jPaymentHash))
        | otherwise = PubKeyCredential (PubKeyHash (hx jPaymentHash))
    stakeCred = case (jStakeKind, jStakeHash) of
        (Just "key", Just h) -> Just (StakingHash (PubKeyCredential (PubKeyHash (hx h))))
        (Just "script", Just h) -> Just (StakingHash (ScriptCredential (ScriptHash (hx h))))
        _ -> Nothing

utxoDatum :: JUtxo -> OutputDatum
utxoDatum JUtxo{..} = case jDatumHex of
    Nothing -> NoOutputDatum
    Just h -> OutputDatum (Datum (B.dataToBuiltinData (deserialise (BSL.fromStrict (unhex (TE.encodeUtf8 h))) :: Data)))

utxoTxOut :: JUtxo -> TxOut
utxoTxOut u = TxOut (utxoAddress u) (utxoValue u) (utxoDatum u) (ScriptHash . hx <$> jRefScriptHash u)

utxoRef :: JUtxo -> TxOutRef
utxoRef u = TxOutRef (TxId (hx (jTxHash u))) (jIndex u)

buildTxInfo :: JCtx -> T.Text -> TxInfo
buildTxInfo JCtx{..} txid =
    TxInfo
        { txInfoInputs = map (\u -> TxInInfo (utxoRef u) (utxoTxOut u)) jInputs
        , txInfoReferenceInputs = map (\u -> TxInInfo (utxoRef u) (utxoTxOut u)) jRefInputs
        , txInfoOutputs = map utxoTxOut jOutputs
        , txInfoFee = Lovelace jFee
        , txInfoMint = emptyMintValue
        , txInfoTxCerts = []
        , -- The real transaction withdraws 0 from the treasury's own stake script.
          txInfoWdrl = AMap.unsafeFromList [(ScriptCredential (ScriptHash (hx wdrlScriptHash)), Lovelace 0)]
        , txInfoValidRange =
            Interval
                (LowerBound NegInf True)
                (UpperBound (Finite (POSIXTime jValidTo)) False)
        , txInfoSignatories = []
        , txInfoRedeemers = AMap.empty
        , txInfoData = AMap.empty
        , txInfoId = TxId (hx txid)
        , txInfoVotes = AMap.empty
        , txInfoProposalProcedures = []
        , txInfoCurrentTreasuryAmount = Nothing
        , txInfoTreasuryDonation = Nothing
        }

main :: IO ()
main = do
    (costFile : scriptFile : ctxFile : redeemerFile : txid : _) <- getArgs
    params <- (read <$> readFile costFile) :: IO [Int64]
    ctxE <- runExceptT (runWriterT (mkEvaluationContext params))
    evalCtx <- either (error . show) (pure . fst) ctxE

    raw <- unhex . BS.filter (/= 10) <$> BS.readFile scriptFile
    script <- either (error . show) pure (deserialiseScript PlutusV3 conwayPV (SBS.toShort raw))

    jctx@JCtx{..} <- either (error . ("context parse: " <>)) pure =<< A.eitherDecodeFileStrict ctxFile
    rhex <- BS.filter (/= 10) <$> BS.readFile redeemerFile
    let redeemerData = deserialise (BSL.fromStrict (unhex rhex)) :: Data

    mut <- lookupEnv "WR_MUTATE"
    -- The datum a WingRiders settlement to a script beneficiary would
    -- necessarily place on the compensation output.
    let settlementDatum = Constr 0 [B (BS.pack [0xa1]), I 491]
        spentIdx = case [i | (i, u) <- zip [0 :: Int ..] jInputs, jPaymentKind u == "script", jPaymentHash u == treasuryHash] of
            (i : _) -> i
            [] -> error "no treasury input"
        applyMut u
            | jPaymentKind u == "script" && jPaymentHash u == treasuryHash =
                case mut of
                    Just "cq3-datum-carrying-input" ->
                        u{jDatumHex = Just (TE.decodeUtf8 (B16.encode (BSL.toStrict (Codec.Serialise.serialise settlementDatum))))}
                    _ -> u
            | otherwise = u
        stealOut u
            | jPaymentKind u == "script" && jPaymentHash u == treasuryHash && mut == Just "cq3-invalid-diverted-change" =
                u{jLovelace = jLovelace u - 10_000_000_000}
            | otherwise = u
        jctx' = jctx{jInputs = map applyMut jInputs, jOutputs = map stealOut jOutputs}
        spentU = jInputs !! spentIdx
        spentDatum = case mut of
            Just "cq3-datum-carrying-input" -> Just (Datum (B.dataToBuiltinData settlementDatum))
            _ -> Nothing
        ctx =
            ScriptContext
                { scriptContextTxInfo = buildTxInfo jctx' (T.pack txid)
                , scriptContextRedeemer = Redeemer (B.dataToBuiltinData redeemerData)
                , scriptContextScriptInfo = SpendingScript (utxoRef spentU) spentDatum
                }

    putStrLn ("MUTATION=" <> maybe "none" id mut)
    putStrLn ("SPENT-TREASURY-INPUT " <> T.unpack (jTxHash spentU) <> "#" <> show (jIndex spentU) <> " datum=" <> maybe "none" (const "carried") spentDatum)

    let (logs, res) = evaluateScriptRestricting PlutusV3 conwayPV Verbose evalCtx ceilingBudget script [toData ctx]
    mapM_ (\l -> putStrLn ("    trace: " <> T.unpack l)) (take 6 logs)
    case res of
        Left e -> do
            putStrLn "CQ3-RESULT=ERROR"
            putStrLn ("    " <> take 300 (map (\c -> if c == '\n' then ' ' else c) (show e)))
            exitFailure
        Right got -> putStrLn ("CQ3-RESULT=OK  " <> show got)
