{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- | CQ2/CQ3 positive control — replay a REAL mainnet WingRiders V2 batch.

Reconstructs the @ScriptContext@ of the known-good Evolve transaction
@db95d31ae9b7df39f0dfe46a2016351e3695b813361f8ae9253c99bde32050f0@ and
evaluates the DEPLOYED pool validator
@af97793b8702f381976cec83e303e9ce17781458c73c4bb16fe02b83@ on it.

Why this must come first: until a known-good context evaluates GREEN,
a synthetic RED is indistinguishable from a malformed context, and a
synthetic GREEN proves nothing about faithfulness. The oracle is not
"did it return OK" but "did it reproduce the ledger's own execution
units" — mem 982475 / steps 314582082, taken from the on-chain
redeemer. Fields the script never reads cannot affect that number, so
exact equality is a strong faithfulness proof for every field it does.
-}
module Main (main) where

import Codec.Serialise (deserialise, serialise)
import Codec.Serialise qualified
import Data.Aeson qualified as A
import Data.Aeson.Types qualified as A
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
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
    , ScriptForEvaluation
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
import PlutusLedgerApi.V1.Value (CurrencySymbol (..), TokenName (..), Value (..), singleton)
import PlutusLedgerApi.V2
    ( Address (..)
    , Credential (..)
    , Data (..)
    , Datum (..)
    , OutputDatum (..)
    , POSIXTime (..)
    , PubKeyHash (..)
    , ScriptContext (..)
    , ScriptHash (..)
    , ScriptPurpose (..)
    , StakingCredential (..)
    , TxId (..)
    , TxInInfo (..)
    , TxInfo (..)
    , TxOut (..)
    , TxOutRef (..)
    , Value
    , mkEvaluationContext
    , toData
    )
import PlutusTx.AssocMap qualified as AMap
import PlutusTx.Builtins qualified as B
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)

import Control.Monad.Except (runExceptT)
import Control.Monad.Writer (runWriterT)

conwayPV :: MajorProtocolVersion
conwayPV = MajorProtocolVersion 10

ceilingBudget :: ExBudget
ceilingBudget = ExBudget 10_000_000_000 16_500_000

-- | The ledger's own numbers for this transaction, read from the
-- on-chain redeemer. This is the oracle.
onChainPoolBudget :: (Integer, Integer)
onChainPoolBudget = (982475, 314582082) -- (mem, steps)

unhex :: BS.ByteString -> BS.ByteString
unhex h = case B16.decode h of
    Left e -> error ("bad hex: " <> e)
    Right b -> b

bbs :: BS.ByteString -> B.BuiltinByteString
bbs = B.toBuiltin

hx :: T.Text -> B.BuiltinByteString
hx = bbs . unhex . TE.encodeUtf8

-- Parsed context description ------------------------------------------------

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
    , jPoolLocation :: Integer
    , jAgentLocation :: Integer
    , jRequestLocations :: [(Integer, Integer)]
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
            <*> o A..: "poolLocation"
            <*> o A..: "agentLocation"
            <*> o A..: "requestLocations"
            <*> o A..: "inputs"
            <*> o A..: "refInputs"
            <*> o A..: "outputs"

-- Conversion ---------------------------------------------------------------

{- | Build the Value in the ledger's CANONICAL shape: ADA first, then
policies in ascending order, token names ascending within each policy,
and all tokens of one policy sharing a single inner map.

This is not cosmetic. The pool validator walks these maps, so a Value
that is numerically equal but differently ordered or differently grouped
costs a different number of execution units — which is exactly what the
budget oracle is there to detect.
-}
utxoValue :: JUtxo -> Value
utxoValue JUtxo{..} =
    Value . AMap.unsafeFromList $
        (CurrencySymbol "", AMap.unsafeFromList [(TokenName "", jLovelace)])
            : [ ( CurrencySymbol (hx p)
                , AMap.unsafeFromList
                    [(TokenName (hx n), q) | (_, n, q) <- grp]
                )
              | grp@((p, _, _) : _) <- grouped
              ]
  where
    sorted = sortOn (\(p, n, _) -> (p, n)) jAssets
    grouped = groupBy (\(a, _, _) (b, _, _) -> a == b) sorted

utxoAddress :: JUtxo -> Address
utxoAddress JUtxo{..} = Address payCred stakeCred
  where
    payCred = case jPaymentKind of
        "script" -> ScriptCredential (ScriptHash (hx jPaymentHash))
        _ -> PubKeyCredential (PubKeyHash (hx jPaymentHash))
    stakeCred = case (jStakeKind, jStakeHash) of
        (Just "key", Just h) ->
            Just (StakingHash (PubKeyCredential (PubKeyHash (hx h))))
        (Just "script", Just h) ->
            Just (StakingHash (ScriptCredential (ScriptHash (hx h))))
        _ -> Nothing

utxoDatum :: JUtxo -> OutputDatum
utxoDatum JUtxo{..} = case jDatumHex of
    Nothing -> NoOutputDatum
    Just h ->
        let d = deserialise (BSL.fromStrict (unhex (TE.encodeUtf8 h))) :: Data
         in OutputDatum (Datum (B.dataToBuiltinData d))

utxoTxOut :: JUtxo -> TxOut
utxoTxOut u =
    TxOut
        { txOutAddress = utxoAddress u
        , txOutValue = utxoValue u
        , txOutDatum = utxoDatum u
        , txOutReferenceScript = ScriptHash . hx <$> jRefScriptHash u
        }

utxoRef :: JUtxo -> TxOutRef
utxoRef u = TxOutRef (TxId (hx (jTxHash u))) (jIndex u)

utxoIn :: JUtxo -> TxInInfo
utxoIn u = TxInInfo (utxoRef u) (utxoTxOut u)

buildTxInfo :: JCtx -> [PubKeyHash] -> TxInfo
buildTxInfo JCtx{..} signatories =
    TxInfo
        { txInfoInputs = map utxoIn jInputs
        , txInfoReferenceInputs = map utxoIn jRefInputs
        , txInfoOutputs = map utxoTxOut jOutputs
        , txInfoFee = singleton (CurrencySymbol "") (TokenName "") jFee
        , txInfoMint = singleton (CurrencySymbol "") (TokenName "") 0
        , txInfoDCert = []
        , txInfoWdrl = AMap.empty
        , txInfoValidRange =
            Interval
                (LowerBound (Finite (POSIXTime jValidFrom)) True)
                (UpperBound (Finite (POSIXTime jValidTo)) False)
        , txInfoSignatories = signatories
        , txInfoRedeemers = AMap.empty
        , txInfoData = AMap.empty
        , txInfoId = TxId (hx "db95d31ae9b7df39f0dfe46a2016351e3695b813361f8ae9253c99bde32050f0")
        }

-- CQ2 mutations ------------------------------------------------------------

-- | Deployed Amaru network_compliance treasury validator (PlutusV3),
-- pinned from chain: this hash is the payment AND stake credential of
-- addr1xyezq8wp… and is reproduced by hashing the fetched script bytes.
amaruTreasuryHash :: T.Text
amaruTreasuryHash = "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"

requestValidatorHashT :: T.Text
requestValidatorHashT = "c134d839a64a5dfb9b155869ef3f34280751a622f69958baa8ffd29c"

dataToHex :: Data -> T.Text
dataToHex = TE.decodeUtf8 . B16.encode . BSL.toStrict . serialise

hexToData :: T.Text -> Data
hexToData h = deserialise (BSL.fromStrict (unhex (TE.encodeUtf8 h)))

setF :: Int -> Data -> Data -> Data
setF i new (Constr n fs) | i < length fs = Constr n (take i fs <> [new] <> drop (i + 1) fs)
setF _ _ d = error ("setF: bad shape " <> take 80 (show d))

getF :: Int -> Data -> Data
getF i (Constr _ fs) | i < length fs = fs !! i
getF _ d = error ("getF: bad shape " <> take 80 (show d))

{- | The Amaru treasury address as request-datum beneficiary: script
payment credential plus script staking credential, matching the real
on-chain treasury address exactly.
-}
treasuryBeneficiary :: Data
treasuryBeneficiary =
    toData
        ( Address
            (ScriptCredential (ScriptHash (hx amaruTreasuryHash)))
            (Just (StakingHash (ScriptCredential (ScriptHash (hx amaruTreasuryHash)))))
        )

-- | The datum a settlement would request. Deliberately distinguishable.
requestedCompensationDatum :: Data
requestedCompensationDatum = Constr 0 [B (BS.pack [0xa1]), I 491]

-- | A different datum, used only for the wrong-datum red.
wrongCompensationDatum :: Data
wrongCompensationDatum = Constr 0 [B (BS.pack [0xa2]), I 492]

{- | Rewrite the validated real batch into a CQ2 case.

Only the beneficiary/datum axis is touched: amounts, fees, validity range,
pool state and every other UTxO are the untouched real transaction, so a
red differs from the green in exactly the field under test.
-}
mutateCq2 :: String -> JCtx -> JCtx
mutateCq2 name c@JCtx{..} =
    c{jInputs = map fixIn jInputs, jOutputs = map fixOut jOutputs}
  where
    reqIdx = case [i | (i, u) <- zip [0 :: Int ..] jInputs, jPaymentKind u == "script", jPaymentHash u == requestValidatorHashT] of
        (i : _) -> i
        [] -> error "no request input found"
    reqU = jInputs !! reqIdx
    reqDatum = maybe (error "request has no datum") hexToData (jDatumHex reqU)
    origBenef = getF 1 reqDatum
    -- Beneficiary becomes the Amaru treasury script; datum type becomes
    -- Inline (2) carrying the requested datum.
    newReqDatum =
        setF 4 (Constr 2 []) (setF 3 requestedCompensationDatum (setF 1 treasuryBeneficiary reqDatum))
    fixIn u
        | jPaymentKind u == "script" && jPaymentHash u == requestValidatorHashT =
            u{jDatumHex = Just (dataToHex newReqDatum)}
        | otherwise = u
    -- The compensation output is the one paying the ORIGINAL beneficiary.
    isCompOut u = addressDataOf u == origBenef
    addressDataOf u = toData (utxoAddress u)
    toTreasury u =
        u
            { jPaymentKind = "script"
            , jPaymentHash = amaruTreasuryHash
            , jStakeKind = Just "script"
            , jStakeHash = Just amaruTreasuryHash
            }
    fixOut u
        | not (isCompOut u) = u
        | otherwise = case name of
            -- Settlement lands at the treasury script with the datum we asked for.
            "cq2-green" -> (toTreasury u){jDatumHex = Just (dataToHex requestedCompensationDatum)}
            -- Address left as the original pubkey beneficiary: must fail raO.
            "cq2-red-wrong-beneficiary" -> u{jDatumHex = Just (dataToHex requestedCompensationDatum)}
            -- Correct address, but not the datum that was requested: must fail rCD.
            "cq2-red-wrong-datum" -> (toTreasury u){jDatumHex = Just (dataToHex wrongCompensationDatum)}
            -- Correct address and datum type No would force EnforcedScriptOutDatum.
            "cq2-red-no-datum" -> (toTreasury u){jDatumHex = Nothing}
            _ -> error ("unknown mutation " <> name)

evolveRedeemer :: JCtx -> Data
evolveRedeemer JCtx{..} =
    Constr
        0
        [ I jPoolLocation
        , I jAgentLocation
        , List [Constr 0 [I r, I d] | (r, d) <- jRequestLocations]
        ]

main :: IO ()
main = do
    (costFile : scriptFile : ctxFile : rest) <- getArgs

    params <- (read <$> readFile costFile) :: IO [Int64]
    ctxE <- runExceptT (runWriterT (mkEvaluationContext params))
    evalCtx <- case ctxE of
        Left e -> error ("cost model rejected: " <> show e)
        Right (c, _) -> pure c

    rawScript <- unhex . BS.filter (/= 10) <$> BS.readFile scriptFile
    script <- case deserialiseScript PlutusV2 conwayPV (SBS.toShort rawScript) of
        Left e -> error ("deserialiseScript: " <> show e)
        Right s -> pure s

    jctxE <- A.eitherDecodeFileStrict ctxFile
    jctx0 <- either (error . ("context parse: " <>)) pure jctxE
    mut <- lookupEnv "WR_MUTATE"
    let jctx@JCtx{..} = maybe jctx0 (`mutateCq2` jctx0) mut
    putStrLn ("MUTATION=" <> maybe "none" id mut)

    -- Locate the pool input by its SCRIPT HASH, not by a hardcoded index.
    -- Real batches place the pool at varying input positions; trusting a
    -- fixed index silently evaluates the wrong UTxO as the pool.
    let poolHashHex = "af97793b8702f381976cec83e303e9ce17781458c73c4bb16fe02b83"
        poolIdx = case [i | (i, u) <- zip [0 :: Int ..] jInputs, jPaymentKind u == "script", jPaymentHash u == poolHashHex] of
            (i : _) -> i
            [] -> error "no pool input found by script hash"
        poolUtxo = jInputs !! poolIdx
        agentUtxo = head ([u | u <- jInputs, jPaymentKind u == "key"] <> [poolUtxo])
        agentPkh = PubKeyHash (hx (jPaymentHash agentUtxo))
        poolDatum = case utxoDatum poolUtxo of
            OutputDatum (Datum bd) -> B.builtinDataToData bd
            _ -> error "pool input has no inline datum"
        txInfo = buildTxInfo jctx [agentPkh]
        ctx =
            ScriptContext
                { scriptContextTxInfo = txInfo
                , scriptContextPurpose = Spending (utxoRef poolUtxo)
                }
        redeemerData = case rest of
            (rh : _) -> deserialise (BSL.fromStrict (unhex (BC.pack rh))) :: Data
            [] -> evolveRedeemer jctx
        args = [poolDatum, redeemerData, toData ctx]

    -- Fidelity check on every datum we reconstruct: re-serialise the
    -- decoded Data and require the exact original bytes back. A Data that
    -- does not round-trip is not the on-chain datum, and would silently
    -- shift execution cost.
    let roundTrip lbl u = case jDatumHex u of
            Nothing -> pure True
            Just h ->
                let orig = unhex (TE.encodeUtf8 h)
                    d = deserialise (BSL.fromStrict orig) :: Data
                    re = BSL.toStrict (Codec.Serialise.serialise d)
                    ok = re == orig
                 in do
                        putStrLn
                            ( "DATUM-ROUNDTRIP "
                                <> lbl
                                <> " ok="
                                <> show ok
                                <> " origBytes="
                                <> show (BS.length orig)
                                <> " reBytes="
                                <> show (BS.length re)
                            )
                        pure ok
    rts <-
        sequence $
            [roundTrip ("input" <> show i) u | (i, u) <- zip [0 :: Int ..] jInputs]
                <> [roundTrip ("output" <> show i) u | (i, u) <- zip [0 :: Int ..] jOutputs]
                <> [roundTrip ("ref" <> show i) u | (i, u) <- zip [0 :: Int ..] jRefInputs]
    putStrLn ("DATUM-ROUNDTRIP-ALL=" <> show (and rts))

    putStrLn ("REPLAY inputs=" <> show (length jInputs) <> " refInputs=" <> show (length jRefInputs) <> " outputs=" <> show (length jOutputs))
    putStrLn ("REPLAY poolLocation=" <> show jPoolLocation <> " agentLocation=" <> show jAgentLocation <> " requests=" <> show jRequestLocations)

    let (logs, res) = evaluateScriptRestricting PlutusV2 conwayPV Verbose evalCtx ceilingBudget script args
    mapM_ (\l -> putStrLn ("    trace: " <> T.unpack l)) (take 6 logs)
    case res of
        Left e -> do
            putStrLn ("REPLAY-RESULT=ERROR")
            putStrLn ("    " <> take 400 (map (\c -> if c == '\n' then ' ' else c) (show e)))
            putStrLn "REPLAY-POSITIVE-CONTROL-FAILED"
            exitFailure
        Right got@(ExBudget gotCpu gotMem) -> do
            -- Expected units come from THIS transaction's on-chain redeemer.
            ecpu <- maybe 314582082 read <$> lookupEnv "WR_EXPECT_CPU"
            emem <- maybe 982475 read <$> lookupEnv "WR_EXPECT_MEM"
            let want = ExBudget (fromInteger ecpu) (fromInteger emem)
            putStrLn ("REPLAY-RESULT=OK  " <> show got)
            putStrLn ("ON-CHAIN-REDEEMER " <> show want)
            putStrLn
                ( "RATIO cpu="
                    <> show (fromIntegral (round (100000 * toRational (read (drop 6 (show gotCpu)) :: Integer) / toRational ecpu) :: Integer) / 1000 :: Double)
                    <> "% mem="
                    <> show (fromIntegral (round (100000 * toRational (read (drop 9 (show gotMem)) :: Integer) / toRational emem) :: Integer) / 1000 :: Double)
                    <> "%"
                )
            if got == want
                then putStrLn "REPLAY-BUDGET-EXACT-MATCH; REPLAY-POSITIVE-CONTROL-PASS"
                else do
                    putStrLn "REPLAY-BUDGET-MISMATCH: context is NOT byte-faithful; downstream reds would be unsound"
                    exitFailure
