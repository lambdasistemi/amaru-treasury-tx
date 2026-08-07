{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- | CQ4 — reclaim against the DEPLOYED WingRiders V2 request validator.

Exercises script hash @c134d839a64a5dfb9b155869ef3f34280751a622f69958baa8ffd29c@
(PlutusV2, 417 B, mainnet reference UTxO
@5ec56338104fcbfe32288c649d9633f0d9060abce8b8608b156294f0a81d29e2#1@)
under the LIVE PlutusV2 cost model.

The datum is a REAL deployed ADA/USDM request datum read from mainnet
(@12b9b604...#0@), not a fixture. Only the field under test is varied,
so a green and its paired red differ in exactly one place.

Every case applies the validator at its true spending arity
(datum, redeemer, context). Under-application reduces to a lambda value
and the evaluator would report success — see CONTROL-UNDERAPPLY, which is
kept in the suite precisely so that trap stays visible.
-}
module Main (main) where

import Codec.Serialise (deserialise)
import Control.Monad (forM, unless)
import Control.Monad.Except (runExceptT)
import Control.Monad.Writer (runWriterT)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Int (Int64)
import Data.Text qualified as T
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
import PlutusLedgerApi.V2
    ( Address (..)
    , Credential (..)
    , Data (..)
    , Datum (..)
    , OutputDatum (..)
    , PubKeyHash (..)
    , Redeemer (..)
    , ScriptContext (..)
    , ScriptHash (..)
    , ScriptPurpose (..)
    , StakingCredential (..)
    , TxId (..)
    , TxInInfo (..)
    , TxInfo (..)
    , TxOut (..)
    , TxOutRef (..)
    , always
    , mkEvaluationContext
    , toData
    )
import PlutusLedgerApi.V1.Value (assetClass, assetClassValue, lovelaceValue)
import PlutusTx.AssocMap qualified as AMap
import PlutusTx.Builtins qualified as B
import System.Environment (getArgs)
import System.Exit (exitFailure)

conwayPV :: MajorProtocolVersion
conwayPV = MajorProtocolVersion 10

-- | Ceiling only. Real consumption is reported per case and is itself
-- part of the anti-vacuity evidence.
ceilingBudget :: ExBudget
ceilingBudget = ExBudget 10_000_000_000 16_500_000

-- Ground truth read from mainnet ------------------------------------------

ownerPkhHex :: BS.ByteString
ownerPkhHex = "dcc4994437830ea2a24f1f0f8c352d138a11b8f1f7799fbdcfab9bf9"

-- | A different, structurally valid pubkey hash: the owner of another
-- real pending request. Used for the wrong-signatory red so the red
-- differs from the green only in WHOSE signature is present.
otherPkhHex :: BS.ByteString
otherPkhHex = "652f6b1c262773dbe60806269d73b7823be93346ba544ea225f70b1b"

-- | The deployed pool validator hash, from the pool reference script.
poolHashHex :: BS.ByteString
poolHashHex = "af97793b8702f381976cec83e303e9ce17781458c73c4bb16fe02b83"

requestHashHex :: BS.ByteString
requestHashHex = "c134d839a64a5dfb9b155869ef3f34280751a622f69958baa8ffd29c"

unhex :: BS.ByteString -> BS.ByteString
unhex h = case B16.decode h of
    Left e -> error ("bad hex: " <> e)
    Right b -> b

bbs :: BS.ByteString -> B.BuiltinByteString
bbs = B.toBuiltin

-- Datum surgery ------------------------------------------------------------

-- | Replace one positional field of a @Constr 0@ datum. Everything else
-- is the untouched mainnet datum, so a paired green/red differ in
-- exactly one field.
setField :: Int -> Data -> Data -> Data
setField i new = \case
    Constr n fs
        | n == 0
        , i < length fs ->
            Constr 0 (take i fs <> [new] <> drop (i + 1) fs)
    d -> error ("setField: unexpected datum shape: " <> take 120 (show d))

getField :: Int -> Data -> Data
getField i = \case
    Constr _ fs | i < length fs -> fs !! i
    d -> error ("getField: unexpected datum shape: " <> take 120 (show d))

-- | An Address as Plutus Data: Constr 0 [credential, maybe staking].
addressData :: Credential -> Data
addressData c = toData (Address c Nothing)

-- Context construction -----------------------------------------------------

requestOutRef :: TxOutRef
requestOutRef =
    TxOutRef
        (TxId (bbs (unhex "12b9b604ddb8f8a8b8ce37ba274c15af426d8a5426868ff1dc102fb6744983cd")))
        0

-- | Build a spending ScriptContext whose only varied ingredient is the
-- signatory set and the first input's address.
mkContext :: [PubKeyHash] -> Address -> Data -> ScriptContext
mkContext signatories firstInputAddr datum =
    mkContextWithOutputs signatories firstInputAddr datum []

-- | Same, but with attacker-chosen outputs, to test whether the deployed
-- reclaim path constrains where the reclaimed value goes.
mkContextWithOutputs
    :: [PubKeyHash] -> Address -> Data -> [TxOut] -> ScriptContext
mkContextWithOutputs signatories firstInputAddr datum outs =
    ScriptContext
        { scriptContextTxInfo =
            TxInfo
                { txInfoInputs =
                    [ TxInInfo
                        requestOutRef
                        TxOut
                            { txOutAddress = firstInputAddr
                            , txOutValue = lovelaceValue 4_000_000
                            , txOutDatum = OutputDatum (Datum (B.dataToBuiltinData datum))
                            , txOutReferenceScript = Nothing
                            }
                    ]
                , txInfoReferenceInputs = []
                , txInfoOutputs = outs
                , txInfoFee = lovelaceValue 300_000
                , txInfoMint = mempty
                , txInfoDCert = []
                , txInfoWdrl = AMap.empty
                , txInfoValidRange = always
                , txInfoSignatories = signatories
                , txInfoRedeemers = AMap.empty
                , txInfoData = AMap.empty
                , txInfoId = TxId (bbs (unhex "00000000000000000000000000000000000000000000000000000000000000ab"))
                }
        , scriptContextPurpose = Spending requestOutRef
        }

pkh :: BS.ByteString -> PubKeyHash
pkh = PubKeyHash . bbs . unhex

reclaimRedeemer :: Data
reclaimRedeemer = Constr 1 []

applyRedeemer :: Integer -> Data
applyRedeemer i = Constr 0 [I i]

-- Case runner --------------------------------------------------------------

data Expect = ExpectOk | ExpectErr
    deriving (Eq, Show)

runCase
    :: EvaluationContext
    -> ScriptForEvaluation
    -> String
    -> Expect
    -> [Data]
    -> IO Bool
runCase ctx script name expect args = do
    let (logs, res) = evaluateScriptRestricting PlutusV2 conwayPV Verbose ctx ceilingBudget script args
    let got = either (const ExpectErr) (const ExpectOk) res
    let ok = got == expect
    let spent = case res of
            Right (ExBudget cpu mem) -> "cpu=" <> show cpu <> " mem=" <> show mem
            Left _ -> "n/a"
    putStrLn $
        "CASE "
            <> name
            <> " arity="
            <> show (length args)
            <> " expect="
            <> show expect
            <> " got="
            <> show got
            <> " verdict="
            <> (if ok then "PASS" else "FAIL")
            <> " budget="
            <> spent
    mapM_ (\l -> putStrLn ("    trace: " <> T.unpack l)) (take 4 logs)
    case res of
        Left e -> putStrLn ("    error: " <> takeLine (show e))
        Right _ -> pure ()
    pure ok
  where
    takeLine = take 150 . map (\c -> if c == '\n' then ' ' else c)

main :: IO ()
main = do
    [costFile, scriptFile, datumFile] <- getArgs

    params <- (read <$> readFile costFile) :: IO [Int64]
    ctxE <- runExceptT (runWriterT (mkEvaluationContext params))
    ctx <- case ctxE of
        Left e -> error ("cost model rejected: " <> show e)
        Right (c, _) -> pure c

    rawScript <- unhex . BS.filter (/= 10) <$> BS.readFile scriptFile
    script <- case deserialiseScript PlutusV2 conwayPV (SBS.toShort rawScript) of
        Left e -> error ("deserialiseScript: " <> show e)
        Right s -> pure s

    datumHex <- BS.filter (/= 10) <$> BS.readFile datumFile
    let realDatum = deserialise (BSL.fromStrict (unhex datumHex)) :: Data

    putStrLn ("DEPLOYED-SCRIPT bytes=" <> show (BS.length rawScript))
    putStrLn ("REAL-DATUM owner-field=" <> take 90 (show (getField 2 realDatum)))

    let ownerAddrPk = Address (PubKeyCredential (pkh ownerPkhHex)) Nothing
        scriptOwnerCred = ScriptCredential (ScriptHash (bbs (unhex ownerPkhHex)))
        datumScriptOwner = setField 2 (addressData scriptOwnerCred) realDatum
        reqAddr = Address (ScriptCredential (ScriptHash (bbs (unhex requestHashHex)))) Nothing
        poolAddr = Address (ScriptCredential (ScriptHash (bbs (unhex poolHashHex)))) Nothing

        ctxSignedByOwner = toData (mkContext [pkh ownerPkhHex] reqAddr realDatum)
        ctxNoSig = toData (mkContext [] reqAddr realDatum)
        ctxWrongSig = toData (mkContext [pkh otherPkhHex] reqAddr realDatum)
        ctxScriptOwnerSigned = toData (mkContext [pkh ownerPkhHex] reqAddr datumScriptOwner)
        ctxPoolFirstInput = toData (mkContext [] poolAddr realDatum)
        ctxNonPoolFirstInput = toData (mkContext [] reqAddr realDatum)

        -- An address that is neither the owner nor the beneficiary.
        exfilOut =
            TxOut
                { txOutAddress = Address (PubKeyCredential (pkh otherPkhHex)) Nothing
                , txOutValue = lovelaceValue 3_700_000
                , txOutDatum = NoOutputDatum
                , txOutReferenceScript = Nothing
                }
        ctxExfiltrate =
            toData (mkContextWithOutputs [pkh ownerPkhHex] reqAddr realDatum [exfilOut])

    results <-
        sequence
            [ -- The claim: deployed reclaim accepts its existing single-pubkey rule.
              runCase ctx script "CQ4-GREEN-pubkey-owner-signed" ExpectOk
                [realDatum, reclaimRedeemer, ctxSignedByOwner]
            , -- Paired red: identical except the owner's signature is absent.
              runCase ctx script "CQ4-RED-owner-signature-absent" ExpectErr
                [realDatum, reclaimRedeemer, ctxNoSig]
            , -- Paired red: a signature is present, but not the owner's.
              runCase ctx script "CQ4-RED-wrong-signatory" ExpectErr
                [realDatum, reclaimRedeemer, ctxWrongSig]
            , -- The certification-relevant red: a SCRIPT owner. Source
              -- claims paddressPubKeyCredential hits perror here.
              runCase ctx script "CQ4-RED-script-owner" ExpectErr
                [datumScriptOwner, reclaimRedeemer, ctxScriptOwnerSigned]
            , -- Apply path still runs: pool hash at the hinted index passes
              -- the delegation proxy check even with no signature.
              runCase ctx script "CQ4-CONTROL-apply-pool-input-present" ExpectOk
                [realDatum, applyRedeemer 0, ctxPoolFirstInput]
            , -- and is rejected when the hinted input is not the pool.
              runCase ctx script "CQ4-CONTROL-apply-pool-input-absent" ExpectErr
                [realDatum, applyRedeemer 0, ctxNonPoolFirstInput]
            , -- Custody: the deployed reclaim path constrains no output, so a
              -- signing key holder may route the entire reclaimed value to an
              -- address unrelated to owner OR beneficiary. Demonstrated, not
              -- cited from the upstream source comment.
              runCase ctx script "CQ4-CUSTODY-reclaim-routes-value-anywhere" ExpectOk
                [realDatum, reclaimRedeemer, ctxExfiltrate]
            , -- Kept deliberately: proves evaluator-OK != validator-accepted.
              runCase ctx script "CONTROL-UNDERAPPLY-must-not-be-read-as-accept" ExpectOk
                [realDatum]
            ]

    let failures = length (filter not results)
    putStrLn ("SUMMARY cases=" <> show (length results) <> " failures=" <> show failures)
    unless (failures == 0) exitFailure
    putStrLn "CQ4-CONTROLS-COMPLETE"
