{-# LANGUAGE OverloadedStrings #-}

-- | Instrument probe for issue #491.
--
-- Establishes that this host can load the DEPLOYED WingRiders PlutusV2
-- bytes (taken from mainnet reference UTxOs) and actually execute them
-- under the LIVE cost model, and that the evaluator can report both
-- success and failure. Until that is shown in both directions, no CQ2-CQ4
-- verdict from this evaluator would mean anything.
module Main (main) where

import Codec.Serialise (deserialise)
import Control.Monad (forM_)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Int (Int64)
import PlutusLedgerApi.Common
    ( EvaluationContext
    , ExBudget (..)
    , MajorProtocolVersion (..)
    , ScriptForEvaluation
    , VerboseMode (..)
    , PlutusLedgerLanguage (..)
    , deserialiseScript
    , evaluateScriptRestricting
    )
import PlutusLedgerApi.V2 (mkEvaluationContext)
import PlutusLedgerApi.V2 qualified as V2
import PlutusTx.Builtins.Internal qualified as BI
import System.Environment (getArgs)
import System.Exit (exitFailure)

import Control.Monad.Except (runExceptT)
import Control.Monad.Writer (runWriterT)

conwayPV :: MajorProtocolVersion
conwayPV = MajorProtocolVersion 10

-- | Generous ceiling: we are probing executability, not measuring cost.
budget :: ExBudget
budget = ExBudget 10_000_000_000 16_500_000

loadCostModel :: FilePath -> IO [Int64]
loadCostModel fp = do
    txt <- readFile fp
    pure (read txt)

mkCtx :: [Int64] -> IO EvaluationContext
mkCtx params = do
    r <- runExceptT (runWriterT (mkEvaluationContext params))
    case r of
        Left err -> error ("cost model rejected: " <> show err)
        Right (ctx, _warns) -> pure ctx

loadScript :: FilePath -> IO ScriptForEvaluation
loadScript fp = do
    hexTxt <- BS.readFile fp
    let hexClean = BS.filter (\w -> w /= 10 && w /= 13 && w /= 32) hexTxt
    raw <- case B16.decode hexClean of
        Left e -> error ("bad hex: " <> e)
        Right b -> pure b
    -- A cardano-cli text-envelope cborHex for PlutusScriptV2 is CBOR
    -- bytes wrapping the flat-encoded script. deserialiseScript expects
    -- exactly that wrapper, so pass it through unchanged.
    case deserialiseScript PlutusV2 conwayPV (SBS.toShort raw) of
        Left err -> error ("deserialiseScript failed: " <> show err)
        Right s -> pure s

main :: IO ()
main = do
    args <- getArgs
    case args of
        [costFile, scriptFile] -> do
            params <- loadCostModel costFile
            ctx <- mkCtx params
            script <- loadScript scriptFile
            putStrLn ("LOADED deployed script from " <> scriptFile)

            -- Control A: deliberately wrong arity/arguments. A validator
            -- that really runs must REJECT this. If this "succeeds", the
            -- evaluator is not executing the script and every later green
            -- would be vacuous.
            let junk = [V2.toData (42 :: Integer)]
            let (logsA, resA) = evaluateScriptRestricting PlutusV2 conwayPV Verbose ctx budget script junk
            putStrLn ("CONTROL-A-WRONG-ARGS result=" <> either (const "ERROR") (const "OK") resA)
            forM_ (take 5 logsA) (\l -> putStrLn ("  logA: " <> show l))
            case resA of
                Left e -> putStrLn ("  CONTROL-A-RED: " <> take 120 (show e))
                Right _ ->
                    -- NOT a failure of the evaluator: an under-applied
                    -- UPLC term reduces to a lambda value, which the
                    -- evaluator reports as "no error". Recorded so no
                    -- later green may rest on wrong-arity application.
                    putStrLn "  CONTROL-A-OK-BY-UNDERAPPLICATION (evaluator-OK != validator-accepted)"

            -- Control B: no arguments at all. Same underapplication caveat.
            let (_logsB, resB) = evaluateScriptRestricting PlutusV2 conwayPV Verbose ctx budget script []
            putStrLn ("CONTROL-B-NO-ARGS result=" <> either (const "ERROR") (const "OK") resB)

            -- Control C: CORRECT arity for a PlutusV2 spending validator
            -- (datum, redeemer, scriptContext) with structurally junk
            -- values. The deployed script must ERROR here: it cannot
            -- pattern-match a redeemer or read a context out of them.
            -- This is the control that decides whether the instrument can
            -- report a rejection at all.
            let junk3 =
                    [ V2.toData (0 :: Integer)
                    , V2.toData (0 :: Integer)
                    , V2.toData (0 :: Integer)
                    ]
            let (logsC, resC) = evaluateScriptRestricting PlutusV2 conwayPV Verbose ctx budget script junk3
            putStrLn ("CONTROL-C-CORRECT-ARITY-JUNK result=" <> either (const "ERROR") (const "OK") resC)
            forM_ (take 5 logsC) (\l -> putStrLn ("  logC: " <> show l))
            case resC of
                Left e -> putStrLn ("  CONTROL-C-RED-AS-REQUIRED: " <> take 160 (show e))
                Right _ -> do
                    putStrLn "  CONTROL-C-FAILED: deployed script accepted junk at correct arity"
                    exitFailure

            putStrLn "EVALUATOR-INSTRUMENT-CAN-REPORT-REJECTION"
        _ -> putStrLn "usage: EvalProbe <costmodel.txt> <script-cborhex.txt>" >> exitFailure
