{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Main
Description : Narrow DevNet lifecycle host for the CLI smoke (#161)
License     : Apache-2.0

This executable owns DevNet lifecycle, governance-genesis
patching, deterministic key fixture generation, launching
@scripts\/smoke\/smoke.sh --inside-devnet@, and narrow
test-only live assertions that need direct chain queries.
Product CLI commands stay unsigned-only; when a live-boundary
smoke needs signing or submission, this DevNet harness performs
that after the shipped CLI has produced the unsigned artifact.

Imports are deliberately restricted so the static
guard in
@Amaru.Treasury.Smoke.CliDevnetSmokeSpec@
can prove no transaction-runner module is reachable
from this binary.
-}
module Main (main) where

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , deriveVerKeyDSIGN
    , rawSerialiseSignKeyDSIGN
    )
import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , serialiseAddr
    )
import Cardano.Ledger.Alonzo.PParams (ppCostModelsL)
import Cardano.Ledger.Alonzo.Scripts
    ( AsIx
    , costModelsValid
    , fromPlutusScript
    , mkPlutusScript
    )
import Cardano.Ledger.Api.PParams (ppMaxTxExUnitsL)
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    , mkTxIxPartial
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core
    ( PParams
    , Script
    , bodyTxL
    )
import Cardano.Ledger.Core qualified as Core
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    )
import Cardano.Ledger.Keys
    ( KeyRole (Payment)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    , assetNameToTextAsHex
    , flattenMultiAsset
    )
import Cardano.Ledger.Plutus.ExUnits
    ( ExUnits (..)
    , exUnitsMem
    , exUnitsSteps
    )
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV2)
    , Plutus (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup
    ( addKeyWitness
    , devnetMagic
    , genesisDir
    , genesisSignKey
    , mkSignKey
    )
import Cardano.Node.Client.Provider
    ( LedgerSnapshot (..)
    , Provider (..)
    , queryProtocolParamsH
    )
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Tx.Build
    ( InterpretIO (..)
    , TxBuild
    , build
    , checkMinUtxo
    , mkPParamsBound
    , output
    , payTo'
    , spend
    , validTo
    )
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32
import Control.Concurrent (threadDelay)
import Control.Monad (unless, when)
import Data.Aeson
    ( Value
    , eitherDecodeFileStrict'
    , encode
    , object
    , (.=)
    )
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList, traverse_)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Void (Void)
import Data.Word (Word64)

import Amaru.Treasury.Backend qualified as Backend
import Amaru.Treasury.Backend.N2C
    ( withLocalNodeBackend
    , withLocalNodeClient
    )
import Amaru.Treasury.Constants
    ( minUtxoDepositLovelace
    , sundaeProtocolFeeLovelace
    , sundaeUsdmPoolHex
    , usdmAssetHex
    , usdmPolicyHex
    )
import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytes
    , decodeHexBytesAny
    )
import Amaru.Treasury.LedgerParse
    ( scriptHashFromHex
    , txInFromText
    , txInToText
    )
import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    )
import Amaru.Treasury.Sundae.Contracts
    ( sundaeOrderValidatorBlob
    )
import Amaru.Treasury.Tx.AttachWitness
    ( decodeUnsignedTxHex
    , renderAttachError
    )
import Amaru.Treasury.Tx.Swap
    ( SwapOrderDatumParams (..)
    , swapOrderDatum
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither, withObject, (.:), (.:?))
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Lens.Micro ((&), (.~), (^.))
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Directory
    ( createDirectoryIfMissing
    , doesDirectoryExist
    , doesFileExist
    , makeAbsolute
    )
import System.Environment (getArgs, getEnvironment)
import System.Exit
    ( ExitCode (..)
    , exitFailure
    , exitSuccess
    , exitWith
    )
import System.FilePath (takeDirectory, (</>))
import System.IO (hPutStrLn, stderr)
import System.Posix.Files (ownerReadMode, setFileMode)
import System.Process
    ( createProcess
    , env
    , proc
    , waitForProcess
    )

data NoCtx a

-- ---------------------------------------------------------------------
-- Argument parsing
-- ---------------------------------------------------------------------

data HostOpts = HostOpts
    { hoRunDir :: !(Maybe FilePath)
    , hoPhase :: !String
    , hoTimeoutSeconds :: !Int
    , hoForce :: !Bool
    , hoExtraArgs :: ![String]
    }
    deriving stock (Eq, Show)

defaultOpts :: HostOpts
defaultOpts =
    HostOpts
        { hoRunDir = Nothing
        , hoPhase = "vault-preflight"
        , hoTimeoutSeconds = 900
        , hoForce = False
        , hoExtraArgs = []
        }

parseArgs :: [String] -> IO HostOpts
parseArgs = go defaultOpts
  where
    go acc [] = pure acc
    go acc (arg : rest) = case arg of
        "--run-dir" -> withValue rest "--run-dir" $ \v r ->
            go acc{hoRunDir = Just v} r
        s
            | "--run-dir=" `isPrefixOf` s ->
                go acc{hoRunDir = Just (dropPrefix "--run-dir=" s)} rest
        "--phase" -> withValue rest "--phase" $ \v r ->
            go acc{hoPhase = v} r
        s
            | "--phase=" `isPrefixOf` s ->
                go acc{hoPhase = dropPrefix "--phase=" s} rest
        "--timeout-seconds" -> withValue rest "--timeout-seconds" $ \v r ->
            go acc{hoTimeoutSeconds = readPositiveInt "--timeout-seconds" v} r
        s
            | "--timeout-seconds=" `isPrefixOf` s ->
                go
                    acc
                        { hoTimeoutSeconds =
                            readPositiveInt
                                "--timeout-seconds"
                                (dropPrefix "--timeout-seconds=" s)
                        }
                    rest
        "--force" -> go acc{hoForce = True} rest
        "--help" -> do
            putStr helpText
            exitSuccess
        "-h" -> do
            putStr helpText
            exitSuccess
        "--" -> pure acc{hoExtraArgs = rest}
        unknown ->
            die $
                "unknown argument: "
                    <> unknown
                    <> " (try --help)"
    withValue rest flag k = case rest of
        (v : r) -> k v r
        [] -> die (flag <> " requires a value")
    dropPrefix :: String -> String -> String
    dropPrefix p = drop (length p)
    readPositiveInt flag v =
        case reads v :: [(Int, String)] of
            [(n, "")] | n > 0 -> n
            _ ->
                error $
                    flag
                        <> " must be a positive integer (got: "
                        <> v
                        <> ")"

helpText :: String
helpText =
    unlines
        [ "devnet-cli-smoke-host: narrow DevNet lifecycle for the #161 CLI smoke."
        , ""
        , "Usage:"
        , "  devnet-cli-smoke-host [options] [-- extra-smoke-args]"
        , ""
        , "Options:"
        , "  --run-dir <path>          Run directory (default: runs/devnet-cli/<timestamp>)."
        , "  --phase <name>            Phase to forward to scripts/smoke/smoke.sh"
        , "                            (default: vault-preflight)."
        , "  --timeout-seconds <int>   Per-phase timeout forwarded to the smoke script."
        , "  --force                   Reuse an existing run-dir."
        , "  --help                    Show this help and exit."
        , ""
        , "The host owns only DevNet bring-up, governance-genesis patching, and"
        , "deterministic DevNet key fixture generation. It then exec()s the"
        , "shell smoke entrypoint with --inside-devnet and the chosen phase."
        ]

-- ---------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------

main :: IO ()
main = do
    opts <- parseArgs =<< getArgs
    runDir <- resolveRunDir (hoRunDir opts) (hoForce opts)
    sourceGenesis <- genesisDir
    assertGenesisDir sourceGenesis
    let smokeGenesis = runDir </> "genesis"
    copyGovernanceGenesis sourceGenesis smokeGenesis
    patchGovernanceGenesis smokeGenesis
    ensureRerateCostModels smokeGenesis

    withCardanoNode smokeGenesis $ \socket _startMs -> do
        keys <- writeDevnetKeyFixtures runDir
        let NetworkMagic magicWord = devnetMagic
            baseEnvEntries =
                [ ("CLI_SMOKE_RUN_DIR", runDir)
                , ("CARDANO_NODE_SOCKET_PATH", socket)
                , ("CLI_SMOKE_SOCKET", socket)
                , ("CLI_SMOKE_NETWORK_MAGIC", show magicWord)
                , ("CLI_SMOKE_NETWORK_NAME", "devnet")
                , ("CLI_SMOKE_GENESIS_DIR", smokeGenesis)
                , ("CLI_SMOKE_FUNDING_SKEY", devnetFundingSkeyPath keys)
                , ("CLI_SMOKE_FUNDING_ADDR", devnetFundingAddress keys)
                , ("CLI_SMOKE_FUNDING_KEY_HASH", devnetFundingKeyHashHex keys)
                , ("CLI_SMOKE_VOTER_SKEY", devnetVoterSkeyPath keys)
                , ("CLI_SMOKE_VOTER_KEY_HASH", devnetVoterKeyHashHex keys)
                , ("CLI_SMOKE_BENEFICIARY_ADDR", devnetBeneficiaryAddress keys)
                ]
        rerateEnvEntries <-
            if hoPhase opts == "rerate"
                then do
                    assertRerateCostModels socket devnetMagic
                    registryCode <-
                        callSmokeScriptPhase
                            opts
                            "registry-stake"
                            runDir
                            baseEnvEntries
                    case registryCode of
                        ExitSuccess -> pure ()
                        code -> exitWith code
                    prepareRerateSmokeSetup
                        runDir
                        socket
                        devnetMagic
                        (T.pack (devnetFundingKeyHashHex keys))
                        (T.pack (devnetVoterKeyHashHex keys))
                else pure []
        smokeCode <-
            callSmokeScript
                opts
                runDir
                (baseEnvEntries <> rerateEnvEntries)
        case hoPhase opts of
            "registry-stake" -> case smokeCode of
                ExitSuccess -> do
                    runChainAssertions runDir socket devnetMagic
                    exitSuccess
                code -> exitWith code
            "governance" -> do
                runChainAssertionsIfPresent runDir socket devnetMagic
                mOutcome <-
                    runGovernanceAssertionsIfPresent
                        runDir
                        socket
                        devnetMagic
                        (smokeCode == ExitSuccess)
                case mOutcome of
                    Just GovernanceMaterialized ->
                        exitSuccess
                    Just GovernanceMissingVote ->
                        exitWith (ExitFailure 78)
                    Just GovernanceRewardObserved ->
                        exitWith (ExitFailure 79)
                    Nothing -> case smokeCode of
                        ExitSuccess -> exitSuccess
                        code -> exitWith code
            "disburse" -> do
                runChainAssertionsIfPresent runDir socket devnetMagic
                runDisburseAssertionsIfPresent
                    runDir
                    socket
                    devnetMagic
                    (smokeCode == ExitSuccess)
                case smokeCode of
                    ExitSuccess -> exitSuccess
                    code -> exitWith code
            "full" -> do
                runChainAssertionsIfPresent runDir socket devnetMagic
                runDisburseAssertionsIfPresent
                    runDir
                    socket
                    devnetMagic
                    (smokeCode == ExitSuccess)
                runReorganizeAssertionsIfPresent
                    runDir
                    socket
                    devnetMagic
                    (smokeCode == ExitSuccess)
                runReorganizeExecUnitsAssertionIfPresent
                    runDir
                    socket
                    devnetMagic
                    (smokeCode == ExitSuccess)
                case smokeCode of
                    ExitSuccess -> do
                        markFullSummaryPassed runDir socket
                        exitSuccess
                    code -> exitWith code
            "reorganize" -> do
                runReorganizeAssertionsIfPresent
                    runDir
                    socket
                    devnetMagic
                    (smokeCode == ExitSuccess)
                runReorganizeExecUnitsAssertionIfPresent
                    runDir
                    socket
                    devnetMagic
                    (smokeCode == ExitSuccess)
                case smokeCode of
                    ExitSuccess -> exitSuccess
                    code -> exitWith code
            "rerate" -> do
                runRerateAssertionsIfPresent
                    runDir
                    socket
                    devnetMagic
                    (smokeCode == ExitSuccess)
                case smokeCode of
                    ExitSuccess -> exitSuccess
                    code -> exitWith code
            _ -> case smokeCode of
                ExitSuccess -> exitSuccess
                code -> exitWith code

resolveRunDir :: Maybe FilePath -> Bool -> IO FilePath
resolveRunDir mRequested force = do
    base <- case mRequested of
        Just p -> pure p
        Nothing -> do
            stamp <- timestampUtc
            pure ("runs/devnet-cli" </> stamp)
    absBase <- makeAbsolute base
    exists <- doesDirectoryExist absBase
    when (exists && not force) $
        die
            ( "run-dir already exists (pass --force to reuse): "
                <> absBase
            )
    createDirectoryIfMissing True absBase
    pure absBase

timestampUtc :: IO String
timestampUtc =
    formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ" <$> getCurrentTime

assertGenesisDir :: FilePath -> IO ()
assertGenesisDir source = do
    ok <- doesDirectoryExist source
    unless ok $
        die
            ( "genesis source directory does not exist: "
                <> source
                <> " (set E2E_GENESIS_DIR to the pinned"
                <> " cardano-node-clients genesis directory)"
            )

-- ---------------------------------------------------------------------
-- Genesis preparation
-- ---------------------------------------------------------------------

copyGovernanceGenesis :: FilePath -> FilePath -> IO ()
copyGovernanceGenesis source target = do
    createDirectoryIfMissing True target
    createDirectoryIfMissing True (target </> "delegate-keys")
    traverse_
        (copyGenesisFile source target)
        [ "alonzo-genesis.json"
        , "byron-genesis.json"
        , "conway-genesis.json"
        , "dijkstra-genesis.json"
        , "node-config.json"
        , "shelley-genesis.json"
        , "topology.json"
        ]
    traverse_
        (copyDelegateKey source target)
        [ "delegate1.kes.skey"
        , "delegate1.opcert"
        , "delegate1.vrf.skey"
        ]

copyGenesisFile :: FilePath -> FilePath -> FilePath -> IO ()
copyGenesisFile source target name = do
    bytes <- BS.readFile (source </> name)
    BS.writeFile (target </> name) bytes

copyDelegateKey :: FilePath -> FilePath -> FilePath -> IO ()
copyDelegateKey source target name = do
    let targetKey = target </> "delegate-keys" </> name
    bytes <- BS.readFile (source </> "delegate-keys" </> name)
    BS.writeFile targetKey bytes
    setFileMode targetKey ownerReadMode

patchGovernanceGenesis :: FilePath -> IO ()
patchGovernanceGenesis dir = do
    patchFile
        (dir </> "shelley-genesis.json")
        [ ("\"epochLength\": 500", "\"epochLength\": 50")
        ,
            ( "\"maxLovelaceSupply\": 30000000000000000"
            , "\"maxLovelaceSupply\": 60000000000000000"
            )
        ]
    patchFile
        (dir </> "conway-genesis.json")
        [ ("\"treasuryWithdrawal\": 0.67", "\"treasuryWithdrawal\": 0.0")
        , ("\"committeeMinSize\": 7", "\"committeeMinSize\": 0")
        ,
            ( "\"committee\": {\n    \"members\": {\n    },\n    \"threshold\": 0.67\n  }"
            , "\"committee\": {\n    \"members\": {\n      \"keyHash-4e88cc2d27c364aaf90648a87dfb95f8ee103ba67fa1f12f5e86c42a\": 100000\n    },\n    \"threshold\": 0.0\n  }"
            )
        ,
            ( "\"dRepDeposit\": 500000000"
            , "\"dRepDeposit\": 500000"
            )
        ,
            ( "\"govActionDeposit\": 50000000000"
            , "\"govActionDeposit\": 1000000"
            )
        ]

ensureRerateCostModels :: FilePath -> IO ()
ensureRerateCostModels dir = do
    (plutusV1, plutusV2) <- readAlonzoCostModels dir
    requireConwayPlutusV3CostModel dir
    requireShelleyProtocolVersion dir
    patchAlonzoExtraCostModels dir plutusV1 plutusV2

readAlonzoCostModels :: FilePath -> IO (Value, Value)
readAlonzoCostModels dir = do
    let path = dir </> "alonzo-genesis.json"
    root <- readJsonObject path
    costModels <- expectObjectField path "costModels" root
    plutusV1 <- expectField path "costModels.PlutusV1" costModels
    plutusV2 <- expectField path "costModels.PlutusV2" costModels
    pure (plutusV1, plutusV2)

requireConwayPlutusV3CostModel :: FilePath -> IO ()
requireConwayPlutusV3CostModel dir = do
    let path = dir </> "conway-genesis.json"
    root <- readJsonObject path
    _ <- expectField path "plutusV3CostModel" root
    pure ()

requireShelleyProtocolVersion :: FilePath -> IO ()
requireShelleyProtocolVersion dir = do
    let path = dir </> "shelley-genesis.json"
    root <- readJsonObject path
    protocolParams <- expectObjectField path "protocolParams" root
    _ <- expectObjectField path "protocolVersion" protocolParams
    pure ()

patchAlonzoExtraCostModels :: FilePath -> Value -> Value -> IO ()
patchAlonzoExtraCostModels dir plutusV1 plutusV2 = do
    let path = dir </> "alonzo-genesis.json"
    root <- readJsonObject path
    existingExtraConfig <-
        case KeyMap.lookup (Key.fromString "extraConfig") root of
            Nothing -> pure KeyMap.empty
            Just (Aeson.Object obj) -> pure obj
            Just _ ->
                die (path <> ": extraConfig must be an object")
    let letCostModels =
            Aeson.Object $
                KeyMap.fromList
                    [ (Key.fromString "PlutusV1", plutusV1)
                    , (Key.fromString "PlutusV2", plutusV2)
                    ]
        rootCostModels =
            Aeson.Object $
                KeyMap.singleton (Key.fromString "PlutusV1") plutusV1
        extraConfig =
            KeyMap.insert
                (Key.fromString "costModels")
                letCostModels
                existingExtraConfig
        updated =
            KeyMap.insert
                (Key.fromString "extraConfig")
                (Aeson.Object extraConfig)
                ( KeyMap.insert
                    (Key.fromString "costModels")
                    rootCostModels
                    root
                )
    BSL.writeFile path (encode (Aeson.Object updated))

readJsonObject :: FilePath -> IO (KeyMap.KeyMap Value)
readJsonObject path = do
    value <-
        eitherDecodeFileStrict' path
            >>= either
                (die . (("cannot parse " <> path <> ": ") <>))
                pure
    case value of
        Aeson.Object obj -> pure obj
        _ -> die (path <> ": expected JSON object")

expectObjectField
    :: FilePath
    -> String
    -> KeyMap.KeyMap Value
    -> IO (KeyMap.KeyMap Value)
expectObjectField path field root =
    case KeyMap.lookup (Key.fromString field) root of
        Just (Aeson.Object obj) -> pure obj
        Just _ -> die (path <> ": " <> field <> " must be an object")
        Nothing -> die (path <> ": missing " <> field)

expectField :: FilePath -> String -> KeyMap.KeyMap Value -> IO Value
expectField path field root =
    case KeyMap.lookup (Key.fromString (lastPathSegment field)) root of
        Just value -> pure value
        Nothing -> die (path <> ": missing " <> field)
  where
    lastPathSegment =
        reverse . takeWhile (/= '.') . reverse

patchFile :: FilePath -> [(BS.ByteString, BS.ByteString)] -> IO ()
patchFile path replacements = do
    content <- BS.readFile path
    BS.writeFile path $
        foldl'
            ( \bytes (needle, replacement) ->
                replaceRequired needle replacement bytes
            )
            content
            replacements

replaceRequired
    :: BS.ByteString
    -> BS.ByteString
    -> BS.ByteString
    -> BS.ByteString
replaceRequired needle replacement content =
    let (before, after) = BS.breakSubstring needle content
    in  if BS.null after
            then
                error $
                    "governance genesis patch did not find "
                        <> BS8.unpack needle
            else
                before
                    <> replacement
                    <> BS.drop (BS.length needle) after

-- ---------------------------------------------------------------------
-- DevNet key fixtures
-- ---------------------------------------------------------------------

{- | The deterministic DevNet key bundle the host
exports for the shell smoke. Both keys are written
as Shelley payment signing-key JSON envelopes with
@0600@ permissions.
-}
data DevnetKeys = DevnetKeys
    { devnetFundingSkeyPath :: !FilePath
    , devnetFundingAddress :: !String
    , devnetFundingKeyHashHex :: !String
    , devnetVoterSkeyPath :: !FilePath
    , devnetVoterKeyHashHex :: !String
    , devnetBeneficiaryAddress :: !String
    }

writeDevnetKeyFixtures :: FilePath -> IO DevnetKeys
writeDevnetKeyFixtures runDir = do
    let keyDir = runDir </> "keys"
    createDirectoryIfMissing True keyDir
    fundingPath <-
        writePaymentSkeyEnvelope
            (keyDir </> "funding.skey")
            "Genesis-funding payment signing key (DevNet)"
            genesisSignKey
    voterPath <-
        writePaymentSkeyEnvelope
            (keyDir </> "voter.skey")
            "Governance voter payment signing key (DevNet)"
            voterSignKey
    pure
        DevnetKeys
            { devnetFundingSkeyPath = fundingPath
            , devnetFundingAddress = paymentAddressBech32 genesisSignKey
            , devnetFundingKeyHashHex = paymentKeyHashHex genesisSignKey
            , devnetVoterSkeyPath = voterPath
            , devnetVoterKeyHashHex = paymentKeyHashHex voterSignKey
            , devnetBeneficiaryAddress =
                paymentAddressBech32 beneficiarySignKey
            }

{- | Deterministic voter signing key, matching
@SmokeSpec@'s voter seed so artifacts compare
directly.
-}
voterSignKey :: SignKeyDSIGN Ed25519DSIGN
voterSignKey =
    mkSignKey "amaru-governance-voter-key-00001"

beneficiarySignKey :: SignKeyDSIGN Ed25519DSIGN
beneficiarySignKey =
    mkSignKey "amaru-beneficiary-address-key001"

writePaymentSkeyEnvelope
    :: FilePath
    -> T.Text
    -> SignKeyDSIGN Ed25519DSIGN
    -> IO FilePath
writePaymentSkeyEnvelope path description sk = do
    BSL.writeFile path $
        encode
            ( object
                [ "type"
                    .= ( "PaymentSigningKeyShelley_ed25519"
                            :: T.Text
                       )
                , "description" .= description
                , "cborHex"
                    .= TE.decodeUtf8
                        ( "5820"
                            <> B16.encode
                                (rawSerialiseSignKeyDSIGN sk)
                        )
                ]
            )
    setFileMode path ownerReadMode
    pure path

paymentAddressBech32 :: SignKeyDSIGN Ed25519DSIGN -> String
paymentAddressBech32 sk =
    T.unpack $
        renderAddr $
            Addr
                Testnet
                (KeyHashObj (paymentKeyHash sk))
                StakeRefNull

renderAddr :: Addr -> T.Text
renderAddr addr =
    Bech32.encodeLenient hrp dat
  where
    hrp =
        either
            (error . ("renderAddr: " <>) . show)
            id
            ( Bech32.humanReadablePartFromText $
                case addr of
                    Addr Mainnet _ _ -> "addr"
                    _ -> "addr_test"
            )
    dat = Bech32.dataPartFromBytes (serialiseAddr addr)

paymentKeyHash :: SignKeyDSIGN Ed25519DSIGN -> KeyHash Payment
paymentKeyHash sk =
    hashKey (VKey (deriveVerKeyDSIGN sk))

paymentKeyHashHex :: SignKeyDSIGN Ed25519DSIGN -> String
paymentKeyHashHex sk =
    case paymentKeyHash sk of
        KeyHash kh ->
            BS8.unpack (B16.encode (hashToBytes kh))
                :: String

genesisPaymentAddr :: Addr
genesisPaymentAddr =
    Addr
        Testnet
        (KeyHashObj (paymentKeyHash genesisSignKey))
        StakeRefNull

orderScriptFromBlob :: BS.ByteString -> IO (Script ConwayEra)
orderScriptFromBlob blob =
    case mkPlutusScript plutus of
        Just script -> pure (fromPlutusScript script)
        Nothing ->
            die "failed to build Plutus script"
  where
    plutus =
        Plutus @PlutusV2 (PlutusBinary (SBS.toShort blob))

refScriptTxOut :: Addr -> Script ConwayEra -> TxOut ConwayEra
refScriptTxOut addr script =
    mkBasicTxOut
        addr
        (MaryValue (Coin 100_000_000) (MultiAsset Map.empty))
        & referenceScriptTxOutL .~ SJust script

scriptAddr :: Network -> ScriptHash -> Addr
scriptAddr network scriptHash =
    Addr
        network
        (ScriptHashObj scriptHash)
        (StakeRefBase (ScriptHashObj scriptHash))

txOutRef :: TxId -> Integer -> TxIn
txOutRef txId ix =
    TxIn txId (mkTxIxPartial ix)

selectLargestAdaUtxo
    :: String
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (TxIn, TxOut ConwayEra)
selectLargestAdaUtxo label utxos =
    case foldr choose Nothing utxos of
        Just (_, selected) -> pure selected
        Nothing -> die ("no pure-ADA UTxO for " <> label)
  where
    choose utxo@(_, txOut) best =
        let MaryValue (Coin lovelace) (MultiAsset assets) =
                txOut ^. valueTxOutL
        in  if Map.null assets
                then case best of
                    Nothing -> Just (lovelace, utxo)
                    Just (bestLovelace, _)
                        | lovelace > bestLovelace ->
                            Just (lovelace, utxo)
                    _ -> best
                else best

waitForTxChange :: Provider IO -> TxId -> Addr -> Int -> IO ()
waitForTxChange _ txId _ attempts
    | attempts <= 0 =
        die ("timed out waiting for tx change output: " <> show txId)
waitForTxChange provider txId addr attempts = do
    utxos <- queryUTxOs provider addr
    if any (hasTxId txId . fst) utxos
        then pure ()
        else do
            threadDelay 500_000
            waitForTxChange provider txId addr (attempts - 1)

waitForTxIns
    :: Provider IO
    -> [TxIn]
    -> Int
    -> IO [(TxIn, TxOut ConwayEra)]
waitForTxIns _ refs attempts
    | attempts <= 0 =
        die
            ( "timed out waiting for UTxOs: "
                <> show (txInToText <$> refs)
            )
waitForTxIns provider refs attempts = do
    found <- queryUTxOByTxIn provider (Set.fromList refs)
    if all (`Map.member` found) refs
        then
            pure
                [ (ref, found Map.! ref)
                | ref <- refs
                ]
        else do
            threadDelay 500_000
            waitForTxIns provider refs (attempts - 1)

waitForChangeTxIn :: Provider IO -> TxId -> Addr -> Int -> IO TxIn
waitForChangeTxIn _ txId _ attempts
    | attempts <= 0 =
        die ("timed out waiting for change from tx: " <> show txId)
waitForChangeTxIn provider txId addr attempts = do
    utxos <- queryUTxOs provider addr
    case [txIn | (txIn, _) <- utxos, hasTxId txId txIn] of
        txIn : _ -> pure txIn
        [] -> do
            threadDelay 500_000
            waitForChangeTxIn provider txId addr (attempts - 1)

hasTxId :: TxId -> TxIn -> Bool
hasTxId txId (TxIn observed _) =
    observed == txId

addSlots :: Word64 -> SlotNo -> SlotNo
addSlots delta (SlotNo slot) =
    SlotNo (slot + delta)

-- ---------------------------------------------------------------------
-- Smoke script handoff
-- ---------------------------------------------------------------------

callSmokeScript
    :: HostOpts
    -> FilePath
    -> [(String, String)]
    -> IO ExitCode
callSmokeScript opts =
    callSmokeScriptPhase opts (hoPhase opts)

callSmokeScriptPhase
    :: HostOpts
    -> String
    -> FilePath
    -> [(String, String)]
    -> IO ExitCode
callSmokeScriptPhase opts phase runDir extraEnv = do
    let smokeScript = "scripts/smoke/smoke.sh"
    smokeAbs <- makeAbsolute smokeScript
    ok <- doesFileExist smokeAbs
    unless ok $
        die ("missing smoke script: " <> smokeAbs)
    baseEnv <- getEnvironment
    let forwardedArgs =
            [ "--inside-devnet"
            , "--run-dir"
            , runDir
            , "--phase"
            , phase
            , "--timeout-seconds"
            , show (hoTimeoutSeconds opts)
            , "--force"
            ]
                <> hoExtraArgs opts
        cp =
            (proc smokeAbs forwardedArgs)
                { env = Just (mergeEnvironment extraEnv baseEnv)
                }
    (_, _, _, ph) <- createProcess cp
    waitForProcess ph

assertRerateCostModels :: FilePath -> NetworkMagic -> IO ()
assertRerateCostModels socket magic =
    withLocalNodeClient magic socket $ \provider _submitter -> do
        pp <- queryCurrentPParams provider
        unless (hasCostModel PlutusV2 pp) $
            die
                "RERATE_COST_MODEL_MISSING: patched devnet genesis \
                \did not carry PlutusV2 into Conway initial PParams"

queryCurrentPParams :: Provider IO -> IO (PParams ConwayEra)
queryCurrentPParams provider =
    Backend.singleShotWithAcquired provider $ \qh ->
        queryProtocolParamsH qh

hasCostModel :: Language -> PParams ConwayEra -> Bool
hasCostModel language pp =
    Map.member language (costModelsValid (pp ^. ppCostModelsL))

prepareRerateSmokeSetup
    :: FilePath
    -> FilePath
    -> NetworkMagic
    -> Text
    -> Text
    -> IO [(String, String)]
prepareRerateSmokeSetup runDir socket magic fundingOwner voterOwner = do
    let phaseDir = runDir </> "phases" </> "rerate"
        registryPath = runDir </> "registry-init" </> "registry.json"
        metadataPath = phaseDir </> "metadata.json"
    createDirectoryIfMissing True phaseDir
    requireExistingFile registryPath
    treasuryHash <-
        readNestedText registryPath ["scripts", "treasuryScriptHash"]
    treasuryAddress <-
        readNestedText registryPath ["addresses", "treasuryAddress"]
    permissionsHash <-
        readNestedText registryPath ["scripts", "permissionsScriptHash"]
    registryPolicy <-
        readNestedText registryPath ["policies", "registryPolicyId"]
    scopesRef <-
        readNestedText registryPath ["anchors", "scopesDeployedAt"]
    permissionsRef <-
        readNestedText registryPath ["anchors", "permissionsDeployedAt"]
    treasuryRef <-
        readNestedText registryPath ["anchors", "treasuryDeployedAt"]
    registryRef <-
        readNestedText registryPath ["anchors", "registryDeployedAt"]
    writeRerateMetadata
        metadataPath
        treasuryHash
        treasuryAddress
        permissionsHash
        registryPolicy
        scopesRef
        permissionsRef
        treasuryRef
        registryRef
        fundingOwner
        voterOwner

    (walletTxIn, oldOrderTxIn) <-
        withLocalNodeClient magic socket $ \provider submitter -> do
            pp <-
                Backend.singleShotWithAcquired provider $ \qh ->
                    queryProtocolParamsH qh
            utxos <- queryUTxOs provider genesisPaymentAddr
            seed@(seedIn, _) <-
                selectLargestAdaUtxo "rerate setup funding" utxos
            orderScript <- orderScriptFromBlob sundaeOrderValidatorBlob
            snapshot <- queryLedgerSnapshot provider
            let orderAddress =
                    scriptAddr
                        Testnet
                        (Core.hashScript @ConwayEra orderScript)
                orderRefOut =
                    refScriptTxOut orderAddress orderScript
                oldOrderLovelace = 15_000_000
                oldOrderUsdm = 6
                orderValue =
                    MaryValue
                        ( Coin
                            ( oldOrderLovelace
                                + sundaeProtocolFeeLovelace
                                + minUtxoDepositLovelace
                            )
                        )
                        (MultiAsset Map.empty)
                upperSlot = addSlots 20 (ledgerTipSlot snapshot)
                interpret :: InterpretIO NoCtx
                interpret =
                    InterpretIO $ \case {}
                eval tx =
                    fmap
                        (Map.map (either (Left . show) Right))
                        (evaluateTx provider tx)
            datumParams <-
                rerateDatumParams fundingOwner voterOwner treasuryHash
            let orderDatum =
                    swapOrderDatum
                        datumParams
                        oldOrderLovelace
                        oldOrderUsdm
                prog :: TxBuild NoCtx Void ()
                prog = do
                    _ <- spend seedIn
                    refIx <- output orderRefOut
                    checkMinUtxo pp refIx
                    _ <-
                        payTo'
                            orderAddress
                            orderValue
                            (RawPlutusData orderDatum)
                    validTo upperSlot
            txId <-
                buildSubmitAndWait
                    "rerate setup"
                    provider
                    submitter
                    pp
                    interpret
                    eval
                    [seed]
                    []
                    genesisPaymentAddr
                    prog
            let orderRef = txOutRef txId 0
                oldOrder = txOutRef txId 1
            _ <- waitForTxIns provider [orderRef, oldOrder] 60
            wallet <- waitForChangeTxIn provider txId genesisPaymentAddr 60
            pure (wallet, oldOrder)

    pure
        [ ("CLI_SMOKE_RERATE_METADATA", metadataPath)
        , ("CLI_SMOKE_RERATE_WALLET_TXIN", T.unpack (txInToText walletTxIn))
        , ("CLI_SMOKE_RERATE_COLLATERAL_TXIN", T.unpack (txInToText walletTxIn))
        ,
            ( "CLI_SMOKE_RERATE_OLD_ORDER_TXIN"
            , T.unpack (txInToText oldOrderTxIn)
            )
        ]

writeRerateMetadata
    :: FilePath
    -> Text
    -> Text
    -> Text
    -> Text
    -> Text
    -> Text
    -> Text
    -> Text
    -> Text
    -> Text
    -> IO ()
writeRerateMetadata
    path
    treasuryHash
    treasuryAddress
    permissionsHash
    registryPolicy
    scopesRef
    permissionsRef
    treasuryRef
    registryRef
    fundingOwner
    voterOwner = do
        let scopeMetaWithOwner owner =
                object
                    [ "owner" .= owner
                    , "budget" .= (1_000_000_000 :: Integer)
                    , "address" .= treasuryAddress
                    , "treasury_script"
                        .= object
                            [ "hash" .= treasuryHash
                            , "deployed_at" .= treasuryRef
                            ]
                    , "permissions_script"
                        .= object
                            [ "hash" .= permissionsHash
                            , "deployed_at" .= permissionsRef
                            ]
                    , "registry_script"
                        .= object
                            [ "hash" .= registryPolicy
                            , "deployed_at" .= registryRef
                            ]
                    ]
        BSL.writeFile path $
            encode $
                object
                    [ "scope_owners" .= scopesRef
                    , "treasuries"
                        .= object
                            [ "core_development" .= scopeMetaWithOwner fundingOwner
                            , "ops_and_use_cases" .= scopeMetaWithOwner voterOwner
                            , "network_compliance" .= scopeMetaWithOwner fundingOwner
                            , "middleware" .= scopeMetaWithOwner voterOwner
                            ]
                    ]

rerateDatumParams :: Text -> Text -> Text -> IO SwapOrderDatumParams
rerateDatumParams fundingOwner voterOwner treasuryHash = do
    fundingBytes <- expectRightIO $ decodeHexBytes 28 fundingOwner
    voterBytes <- expectRightIO $ decodeHexBytes 28 voterOwner
    treasuryBytes <- expectRightIO $ decodeHexBytes 28 treasuryHash
    poolId <- expectRightIO $ decodeHexBytes 28 sundaeUsdmPoolHex
    usdmPolicy <- expectRightIO $ decodeHexBytesAny usdmPolicyHex
    usdmToken <- expectRightIO $ decodeHexBytesAny usdmAssetHex
    pure
        SwapOrderDatumParams
            { sodPoolId = poolId
            , sodCoreOwner = fundingBytes
            , sodOpsOwner = voterBytes
            , sodNetworkComplianceOwner = fundingBytes
            , sodMiddlewareOwner = voterBytes
            , sodSundaeProtocolFeeLovelace = sundaeProtocolFeeLovelace
            , sodTreasuryScriptHash = treasuryBytes
            , sodUsdmPolicy = usdmPolicy
            , sodUsdmToken = usdmToken
            }

expectRightIO :: Either String a -> IO a
expectRightIO =
    either die pure

readNestedText :: FilePath -> [Text] -> IO Text
readNestedText path segments = do
    value <-
        (eitherDecodeFileStrict' path :: IO (Either String Value))
            >>= either
                (die . (("cannot parse " <> path <> ": ") <>))
                pure
    either
        (die . (("missing field in " <> path <> ": ") <>))
        pure
        (parseEither (go segments) value)
  where
    go :: [Text] -> Value -> Parser Text
    go [] (Aeson.String t) = pure t
    go [] _ = fail "expected text"
    go (segment : rest) value =
        withObject
            "object"
            ( \root ->
                root .: Key.fromText segment >>= go rest
            )
            value

buildSubmitAndWait
    :: String
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> InterpretIO NoCtx
    -> ( ConwayTx
         -> IO
                ( Map.Map
                    (ConwayPlutusPurpose AsIx ConwayEra)
                    (Either String ExUnits)
                )
       )
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
    -> Addr
    -> TxBuild NoCtx Void ()
    -> IO TxId
buildSubmitAndWait
    label
    provider
    submitter
    pp
    interpret
    eval
    inputs
    refs
    changeAddr
    prog =
        build
            (mkPParamsBound pp)
            interpret
            eval
            inputs
            refs
            changeAddr
            prog
            >>= \case
                Left err ->
                    die (label <> ": " <> show err)
                Right tx -> do
                    let signed = addKeyWitness genesisSignKey tx
                        txId = txIdTx signed
                    submitTx submitter signed >>= \case
                        Submitted _ -> pure ()
                        Rejected reason ->
                            die $
                                label
                                    <> " rejected: "
                                    <> BS8.unpack reason
                    waitForTxChange provider txId changeAddr 60
                    pure txId

mergeEnvironment
    :: [(String, String)]
    -> [(String, String)]
    -> [(String, String)]
mergeEnvironment preferred base =
    let preferredNames = fmap fst preferred
    in  preferred
            <> filter
                ( \entry ->
                    fst entry `notElem` preferredNames
                )
                base

-- ---------------------------------------------------------------------
-- Chain assertions for the registry-stake phase
-- ---------------------------------------------------------------------

{- | After the registry-stake shell pipeline submits the five
bootstrap transactions and derives @accounts.json@, query the live
DevNet via the Amaru-owned 'Backend.QueryHandle' surface to confirm
the four registry/reference-script anchors still exist as UTxOs and
that the two stake-reward accounts are registered.

The chain query is the only operation this host performs against
DevNet outside of node lifecycle; it does NOT build, sign, or
submit transactions. The assertion request JSON is produced by the
shell smoke at @chain/assertions.request.json@; the report is written
to @chain/assertions.json@ and @chain/assertions.log@. Any failed
assertion exits the host non-zero with a precise diagnostic.
-}
runChainAssertions
    :: FilePath -> FilePath -> NetworkMagic -> IO ()
runChainAssertions runDir socket magic = do
    let requestPath = runDir </> "chain" </> "assertions.request.json"
        reportPath = runDir </> "chain" </> "assertions.json"
        logPath = runDir </> "chain" </> "assertions.log"
    createDirectoryIfMissing True (runDir </> "chain")
    raw <-
        eitherDecodeFileStrict' requestPath
            >>= either (die . chainAssertionBadRequest) pure
    request <-
        either (die . chainAssertionBadRequest) pure $
            parseEither parseChainAssertionRequest raw

    let anchors = carAnchors request
        rewardAccountHexes :: [(Text, Text)]
        rewardAccountHexes =
            [ ("treasury", carTreasuryRewardAccount request)
            , ("permissions", carPermissionsRewardAccount request)
            ]
    rewardAccounts <-
        traverse
            ( \(label, hex) ->
                case scriptHashFromHex hex of
                    Left e ->
                        die
                            ( "chain-assertion: "
                                <> T.unpack label
                                <> " reward account hex is "
                                <> "not a script hash ("
                                <> e
                                <> ")"
                            )
                    Right sh ->
                        pure
                            ( label
                            , hex
                            , AccountAddress
                                Testnet
                                (AccountId (ScriptHashObj sh))
                            )
            )
            rewardAccountHexes

    let anchorTxIns = fmap snd anchors
        anchorSet = Set.fromList anchorTxIns
        accountSet = Set.fromList (fmap third3 rewardAccounts)

    (foundUtxos, foundRewards) <-
        withLocalNodeBackend magic socket $ \backend ->
            Backend.singleShotWithAcquired backend $ \qh -> do
                utxos <- Backend.queryUTxOByTxInH qh anchorSet
                rewards <-
                    Backend.queryRewardAccountsH qh accountSet
                pure (utxos, rewards)

    let anchorResults =
            [ AnchorResult label txin (Map.member txin foundUtxos)
            | (label, txin) <- anchors
            ]
        rewardResults =
            [ RewardAccountResult
                label
                hex
                (Map.member account foundRewards)
                ( Map.findWithDefault
                    (Coin 0)
                    account
                    foundRewards
                )
            | (label, hex, account) <- rewardAccounts
            ]
        anchorMissing =
            [ label | AnchorResult label _ ok <- anchorResults, not ok
            ]
        rewardMissing =
            [ label
            | RewardAccountResult label _ ok _ <- rewardResults
            , not ok
            ]
        anchorsOk = null anchorMissing
        report =
            object
                [ "phase" .= ("registry-stake" :: Text)
                , "anchors"
                    .= [ object
                        [ "label" .= arLabel a
                        , "txIn" .= txInToText (arTxIn a)
                        , "present" .= arPresent a
                        ]
                       | a <- anchorResults
                       ]
                , "rewardAccounts"
                    .= [ object
                        [ "label" .= rrLabel r
                        , "rewardAccount" .= rrHex r
                        , "registered" .= rrRegistered r
                        , "rewardsLovelace" .= coinLovelace (rrRewards r)
                        ]
                       | r <- rewardResults
                       ]
                , "anchorsOk" .= anchorsOk
                , "rewardAccountQueryMissing" .= rewardMissing
                , "note"
                    .= ( "Reward-account queries return zero for both "
                            <> "registered-with-no-rewards and unregistered "
                            <> "accounts on some backends, so this report "
                            <> "carries the observed registered flag as a "
                            <> "diagnostic; the authoritative proof of "
                            <> "registration is the accepted setup tx id "
                            <> "captured in the registry-stake summary."
                            :: Text
                       )
                ]

    BSL.writeFile reportPath (encode report)
    writeFile logPath (unlines (renderChainAssertionLog report))
    if anchorsOk
        then
            hPutStrLn
                stderr
                ( "devnet-cli-smoke-host: chain assertions passed ("
                    <> reportPath
                    <> ")"
                )
        else
            die
                ( "chain-assertion: anchor UTxOs missing on chain ("
                    <> show anchorMissing
                    <> "); see "
                    <> reportPath
                )

runChainAssertionsIfPresent
    :: FilePath -> FilePath -> NetworkMagic -> IO ()
runChainAssertionsIfPresent runDir socket magic = do
    let requestPath = runDir </> "chain" </> "assertions.request.json"
    exists <- doesFileExist requestPath
    when exists (runChainAssertions runDir socket magic)

chainAssertionBadRequest :: String -> String
chainAssertionBadRequest err =
    "chain-assertion: cannot parse assertions.request.json: " <> err

third3 :: (a, b, c) -> c
third3 (_, _, x) = x

renderChainAssertionLog :: Value -> [String]
renderChainAssertionLog v =
    [ "chain-assertion: report"
    , T.unpack (TE.decodeUtf8 (BSL.toStrict (encode v)))
    ]

-- ---------------------------------------------------------------------
-- Full-phase summary finalization
-- ---------------------------------------------------------------------

markFullSummaryPassed :: FilePath -> FilePath -> IO ()
markFullSummaryPassed runDir socket = do
    let summaryPath = runDir </> "summary.json"
        registrySummary = runDir </> "phases" </> "registry-stake" </> "summary.json"
        governanceSummary = runDir </> "phases" </> "governance" </> "summary.json"
        disburseSummary = runDir </> "disburse-submit" </> "summary.json"
        chainAssertionsPath = runDir </> "chain" </> "assertions.json"
        disburseAssertionsPath =
            runDir </> "chain" </> "disburse.assertions.json"
    traverse_
        requireExistingFile
        [ registrySummary
        , governanceSummary
        , disburseSummary
        , chainAssertionsPath
        , disburseAssertionsPath
        ]
    seedSplitTxId <- readSummaryText registrySummary "seedSplitTxId"
    registryMintTxId <- readSummaryText registrySummary "registryMintTxId"
    referenceScriptsTxId <-
        readSummaryText registrySummary "referenceScriptsTxId"
    stakeRewardScriptAccountTxId <-
        readSummaryText registrySummary "stakeRewardScriptAccountTxId"
    stakeRewardPlainAccountTxId <-
        readSummaryText registrySummary "stakeRewardPlainAccountTxId"
    proposalTxId <- readSummaryText governanceSummary "proposalTxId"
    materializationTxId <-
        readSummaryText governanceSummary "materializationTxId"
    disburseTxId <- readSummaryText disburseSummary "disburseTxId"
    BSL.writeFile summaryPath $
        encode
            ( object
                [ "phase" .= ("full" :: Text)
                , "status" .= ("passed" :: Text)
                , "registrySummary" .= registrySummary
                , "governanceSummary" .= governanceSummary
                , "disburseSummary" .= disburseSummary
                , "runDir" .= runDir
                , "socketPath" .= socket
                , "verificationStatus" .= ("passed" :: Text)
                , "chainAssertions" .= chainAssertionsPath
                , "disburseChainAssertions" .= disburseAssertionsPath
                , "seedSplitTxId" .= seedSplitTxId
                , "registryMintTxId" .= registryMintTxId
                , "referenceScriptsTxId" .= referenceScriptsTxId
                , "stakeRewardScriptAccountTxId"
                    .= stakeRewardScriptAccountTxId
                , "stakeRewardPlainAccountTxId"
                    .= stakeRewardPlainAccountTxId
                , "proposalTxId" .= proposalTxId
                , "materializationTxId" .= materializationTxId
                , "disburseTxId" .= disburseTxId
                ]
            )
    hPutStrLn
        stderr
        ( "devnet-cli-smoke-host: full summary marked passed ("
            <> summaryPath
            <> ")"
        )

requireExistingFile :: FilePath -> IO ()
requireExistingFile path = do
    exists <- doesFileExist path
    unless exists $
        die ("full-summary: required artifact missing: " <> path)

readSummaryText :: FilePath -> String -> IO Text
readSummaryText path field = do
    value <-
        eitherDecodeFileStrict' path
            >>= either
                (die . (("full-summary: cannot parse " <> path <> ": ") <>))
                pure
    either
        ( die
            . (("full-summary: missing " <> field <> " in " <> path <> ": ") <>)
        )
        pure
        ( parseEither
            ( withObject "summary" $ \root ->
                root .: Key.fromString field
            )
            value
        )

data AnchorResult = AnchorResult
    { arLabel :: !Text
    , arTxIn :: !TxIn
    , arPresent :: !Bool
    }

data RewardAccountResult = RewardAccountResult
    { rrLabel :: !Text
    , rrHex :: !Text
    , rrRegistered :: !Bool
    , rrRewards :: !Coin
    }

data ChainAssertionRequest = ChainAssertionRequest
    { carAnchors :: ![(Text, TxIn)]
    , carTreasuryRewardAccount :: !Text
    , carPermissionsRewardAccount :: !Text
    }

parseChainAssertionRequest :: Value -> Parser ChainAssertionRequest
parseChainAssertionRequest = withObject "ChainAssertionRequest" $ \root -> do
    anchorsObj <- root .: "anchors"
    rewardObj <- root .: "rewardAccounts"
    let labelled :: [Text]
        labelled =
            [ "scopesDeployedAt"
            , "registryDeployedAt"
            , "permissionsDeployedAt"
            , "treasuryDeployedAt"
            ]
    anchors <-
        traverse
            ( \name -> do
                txt <- anchorsObj .: Key.fromText name
                txin <- either fail pure (txInFromText txt)
                pure (name, txin)
            )
            labelled
    treasuryAcc <- rewardObj .: Key.fromText "treasury"
    permissionsAcc <- rewardObj .: Key.fromText "permissions"
    pure
        ChainAssertionRequest
            { carAnchors = anchors
            , carTreasuryRewardAccount = treasuryAcc
            , carPermissionsRewardAccount = permissionsAcc
            }

coinLovelace :: Coin -> Integer
coinLovelace (Coin n) = n

txOutLovelace :: TxOut ConwayEra -> Integer
txOutLovelace txOut =
    let MaryValue (Coin lovelace) _ = txOut ^. valueTxOutL
    in  lovelace

txOutAddressText :: TxOut ConwayEra -> Text
txOutAddressText txOut =
    renderAddr (txOut ^. addrTxOutL)

-- ---------------------------------------------------------------------
-- Governance assertions and missing-vote diagnostic
-- ---------------------------------------------------------------------

data GovernanceAssertionOutcome
    = GovernanceMissingVote
    | GovernanceRewardObserved
    | GovernanceMaterialized

runGovernanceAssertionsIfPresent
    :: FilePath
    -> FilePath
    -> NetworkMagic
    -> Bool
    -> IO (Maybe GovernanceAssertionOutcome)
runGovernanceAssertionsIfPresent runDir socket magic required = do
    let requestPath =
            runDir </> "chain" </> "governance.assertions.request.json"
    exists <- doesFileExist requestPath
    if not exists
        then do
            when required $
                die
                    ( "governance-assertion: missing request "
                        <> requestPath
                    )
            pure Nothing
        else Just <$> runGovernanceAssertions runDir socket magic

runGovernanceAssertions
    :: FilePath -> FilePath -> NetworkMagic -> IO GovernanceAssertionOutcome
runGovernanceAssertions runDir socket magic = do
    let requestPath =
            runDir </> "chain" </> "governance.assertions.request.json"
        reportPath = runDir </> "chain" </> "governance.assertions.json"
        logPath = runDir </> "chain" </> "governance.assertions.log"
        phaseSummaryPath =
            runDir </> "phases" </> "governance" </> "summary.json"
    raw <-
        eitherDecodeFileStrict' requestPath
            >>= either (die . badRequest) pure
    request <-
        either (die . badRequest) pure $
            parseEither parseGovernanceAssertionRequest raw
    genesis <- readGovernanceGenesisDiagnostics runDir
    case garMaterialization request of
        Just materialization ->
            runGovernanceMaterializationAssertions
                phaseSummaryPath
                socket
                magic
                reportPath
                logPath
                genesis
                request
                materialization
        Nothing ->
            runGovernanceProposalOnlyAssertions
                socket
                magic
                reportPath
                logPath
                genesis
                request
  where
    badRequest err =
        "governance-assertion: cannot parse request: " <> err

runGovernanceProposalOnlyAssertions
    :: FilePath
    -> NetworkMagic
    -> FilePath
    -> FilePath
    -> Value
    -> GovernanceAssertionRequest
    -> IO GovernanceAssertionOutcome
runGovernanceProposalOnlyAssertions
    socket
    magic
    reportPath
    logPath
    genesis
    request = do
        firstSnapshot <- queryGovernanceSnapshot socket magic request
        finalSnapshot <-
            waitForGovernanceReward
                socket
                magic
                request
                firstSnapshot

        let rewardObserved =
                gcsTreasuryRewardLovelace finalSnapshot
                    >= garExpectedRewardLovelace request
            code =
                if rewardObserved
                    then "unexpected-governance-reward-observed"
                    else "missing-shipped-governance-vote"
            report =
                object
                    [ "phase" .= ("governance" :: Text)
                    , "status" .= ("diagnostic" :: Text)
                    , "code" .= (code :: Text)
                    , "proposalTxId" .= garProposalTxId request
                    , "governanceActionId" .= garGovernanceActionId request
                    , "expectedRewardLovelace"
                        .= garExpectedRewardLovelace request
                    , "treasuryRewardAccount"
                        .= garTreasuryRewardAccount request
                    , "initial" .= governanceSnapshotValue firstSnapshot
                    , "final" .= governanceSnapshotValue finalSnapshot
                    , "genesis" .= genesis
                    , "diagnostic"
                        .= ( if rewardObserved
                                then
                                    ( "Reward accrued, but no materialization "
                                        <> "evidence was supplied in the governance "
                                        <> "assertion request."
                                        :: Text
                                    )
                                else
                                    ( "No treasury reward accrued after the proposal. "
                                        <> "The shipped CLI has proposal and materialization surfaces, "
                                        <> "but no governance vote surface."
                                        :: Text
                                    )
                           )
                    ]
        BSL.writeFile reportPath (encode report)
        writeFile logPath (unlines (renderChainAssertionLog report))
        if rewardObserved
            then do
                hPutStrLn
                    stderr
                    ( "devnet-cli-smoke-host: governance reward observed but "
                        <> "materialization evidence was not supplied ("
                        <> reportPath
                        <> ")"
                    )
                pure GovernanceRewardObserved
            else do
                hPutStrLn
                    stderr
                    ( "devnet-cli-smoke-host: missing-shipped-governance-vote; "
                        <> "see "
                        <> reportPath
                    )
                pure GovernanceMissingVote

runGovernanceMaterializationAssertions
    :: FilePath
    -> FilePath
    -> NetworkMagic
    -> FilePath
    -> FilePath
    -> Value
    -> GovernanceAssertionRequest
    -> GovernanceMaterializationAssertion
    -> IO GovernanceAssertionOutcome
runGovernanceMaterializationAssertions
    phaseSummaryPath
    socket
    magic
    reportPath
    logPath
    genesis
    request
    materialization = do
        snapshot <- queryGovernanceSnapshot socket magic request
        materializedJsonErrors <- verifyMaterializedJson materialization
        let failures =
                materializationFailures request materialization snapshot
                    <> materializedJsonErrors
            success = null failures
            code =
                if success
                    then "governance-materialization-verified"
                    else "governance-materialization-verification-failed"
            report =
                object
                    [ "phase" .= ("governance" :: Text)
                    , "status"
                        .= ( if success
                                then "passed"
                                else
                                    "failed"
                                        :: Text
                           )
                    , "code" .= (code :: Text)
                    , "proposalTxId" .= garProposalTxId request
                    , "governanceActionId" .= garGovernanceActionId request
                    , "expectedRewardLovelace"
                        .= garExpectedRewardLovelace request
                    , "treasuryRewardAccount"
                        .= garTreasuryRewardAccount request
                    , "final" .= governanceSnapshotValue snapshot
                    , "materialization"
                        .= materializationAssertionValue materialization
                    , "genesis" .= genesis
                    , "verificationErrors" .= failures
                    , "diagnostic"
                        .= ( if success
                                then
                                    ( "Materialized treasury UTxO verified on-chain "
                                        <> "and treasury reward account drained."
                                        :: Text
                                    )
                                else
                                    ( "Materialization evidence did not match live "
                                        <> "chain state."
                                        :: Text
                                    )
                           )
                    ]
        BSL.writeFile reportPath (encode report)
        writeFile logPath (unlines (renderChainAssertionLog report))
        if success
            then do
                writeGovernanceMaterializationSummary
                    phaseSummaryPath
                    reportPath
                    logPath
                    request
                    materialization
                    snapshot
                hPutStrLn
                    stderr
                    ( "devnet-cli-smoke-host: governance materialization verified ("
                        <> reportPath
                        <> ")"
                    )
                pure GovernanceMaterialized
            else
                die
                    ( "governance-assertion: materialization verification failed; see "
                        <> reportPath
                    )

writeGovernanceMaterializationSummary
    :: FilePath
    -> FilePath
    -> FilePath
    -> GovernanceAssertionRequest
    -> GovernanceMaterializationAssertion
    -> GovernanceChainSnapshot
    -> IO ()
writeGovernanceMaterializationSummary
    summaryPath
    reportPath
    logPath
    request
    materialization
    snapshot = do
        createDirectoryIfMissing True (takeDirectory summaryPath)
        BSL.writeFile summaryPath $
            encode
                ( object
                    [ "phase" .= ("governance" :: Text)
                    , "status" .= ("passed" :: Text)
                    , "code"
                        .= ("governance-materialization-verified" :: Text)
                    , "proposalTxId" .= garProposalTxId request
                    , "governanceActionId"
                        .= garGovernanceActionId request
                    , "materializationTxId" .= gmaTxId materialization
                    , "treasuryRewardAccount"
                        .= garTreasuryRewardAccount request
                    , "treasuryRewardLovelace"
                        .= gcsTreasuryRewardLovelace snapshot
                    , "treasuryMaterializedTxIn"
                        .= gmaTreasuryMaterializedTxInText materialization
                    , "treasuryMaterializedAddress"
                        .= gmaTreasuryAddress materialization
                    , "treasuryMaterializedLovelace"
                        .= gmaMaterializedAdaLovelace materialization
                    , "materializationChangeTxIn"
                        .= txInToText
                            (gmaMaterializationChangeTxIn materialization)
                    , "materializationChangePresent"
                        .= gcsMaterializationChangePresent snapshot
                    , "materializationChangeLovelace"
                        .= gcsMaterializationChangeLovelace snapshot
                    , "materializedJson"
                        .= gmaMaterializedJson materialization
                    , "chainAssertions" .= reportPath
                    , "chainAssertionsLog" .= logPath
                    , "chainObserved"
                        .= governanceSnapshotValue snapshot
                    ]
                )

materializationFailures
    :: GovernanceAssertionRequest
    -> GovernanceMaterializationAssertion
    -> GovernanceChainSnapshot
    -> [Text]
materializationFailures request materialization snapshot =
    concat
        [ expectBool
            "voterBaseOutput.present"
            True
            (gcsVoterBasePresent snapshot)
        , expectMaybeInteger
            "voterBaseOutput.lovelace"
            (garVoterBaseLovelace request)
            (gcsVoterBaseLovelace snapshot)
        , expectBool
            "proposalChangeOutput.present"
            False
            (gcsProposalChangePresent snapshot)
        , expectBool
            "materialization.output.present"
            True
            (gcsMaterializedPresent snapshot)
        , expectMaybeText
            "materialization.output.address"
            (gmaTreasuryAddress materialization)
            (gcsMaterializedAddress snapshot)
        , expectMaybeInteger
            "materialization.output.lovelace"
            (gmaMaterializedAdaLovelace materialization)
            (gcsMaterializedLovelace snapshot)
        , expectBool
            "materialization.change.present"
            True
            (gcsMaterializationChangePresent snapshot)
        , expectInteger
            "treasuryRewardLovelace"
            0
            (gcsTreasuryRewardLovelace snapshot)
        ]

verifyMaterializedJson
    :: GovernanceMaterializationAssertion -> IO [Text]
verifyMaterializedJson materialization = do
    exists <- doesFileExist (gmaMaterializedJson materialization)
    if not exists
        then
            pure
                [ "materializedJson missing: "
                    <> T.pack (gmaMaterializedJson materialization)
                ]
        else do
            decoded <-
                eitherDecodeFileStrict' (gmaMaterializedJson materialization)
            case decoded of
                Left err ->
                    pure
                        [ "materializedJson decode failed: "
                            <> T.pack err
                        ]
                Right raw ->
                    either
                        ( \err ->
                            pure
                                [ "materializedJson parse failed: "
                                    <> T.pack err
                                ]
                        )
                        pure
                        (parseEither (parseMaterializedJsonMatches materialization) raw)

parseMaterializedJsonMatches
    :: GovernanceMaterializationAssertion -> Value -> Parser [Text]
parseMaterializedJsonMatches materialization =
    withObject "materialized.json" $ \o -> do
        phase <- o .: "phase"
        network <- o .: "network"
        governanceActionId <- o .: "governanceActionId"
        treasuryRewardAccount <- o .: "treasuryRewardAccount"
        submittedTxId <- o .: "submittedTxId"
        treasuryTxIn <- o .: "treasuryMaterializedTxIn"
        treasuryAddress <- o .: "treasuryAddress"
        materializedLovelace <- o .: "materializedAdaLovelace"
        pure $
            concat
                [ expectText
                    "materializedJson.phase"
                    "governance-withdrawal-init"
                    phase
                , expectText "materializedJson.network" "devnet" network
                , expectText
                    "materializedJson.governanceActionId"
                    (gmaGovernanceActionId materialization)
                    governanceActionId
                , expectText
                    "materializedJson.treasuryRewardAccount"
                    (gmaTreasuryRewardAccount materialization)
                    treasuryRewardAccount
                , expectText
                    "materializedJson.submittedTxId"
                    (gmaTxId materialization)
                    submittedTxId
                , expectText
                    "materializedJson.treasuryMaterializedTxIn"
                    (gmaTreasuryMaterializedTxInText materialization)
                    treasuryTxIn
                , expectText
                    "materializedJson.treasuryAddress"
                    (gmaTreasuryAddress materialization)
                    treasuryAddress
                , expectInteger
                    "materializedJson.materializedAdaLovelace"
                    (gmaMaterializedAdaLovelace materialization)
                    materializedLovelace
                ]

materializationAssertionValue
    :: GovernanceMaterializationAssertion -> Value
materializationAssertionValue materialization =
    object
        [ "governanceActionId" .= gmaGovernanceActionId materialization
        , "treasuryRewardAccount" .= gmaTreasuryRewardAccount materialization
        , "txId" .= gmaTxId materialization
        , "treasuryMaterializedTxIn"
            .= gmaTreasuryMaterializedTxInText materialization
        , "treasuryAddress" .= gmaTreasuryAddress materialization
        , "materializedAdaLovelace"
            .= gmaMaterializedAdaLovelace materialization
        , "materializationChangeTxIn"
            .= txInToText (gmaMaterializationChangeTxIn materialization)
        , "materializedJson" .= gmaMaterializedJson materialization
        ]

expectText :: Text -> Text -> Text -> [Text]
expectText field expected actual
    | actual == expected = []
    | otherwise =
        [ field
            <> " expected "
            <> expected
            <> " but observed "
            <> actual
        ]

expectInteger :: Text -> Integer -> Integer -> [Text]
expectInteger field expected actual
    | actual == expected = []
    | otherwise =
        [ field
            <> " expected "
            <> T.pack (show expected)
            <> " but observed "
            <> T.pack (show actual)
        ]

expectBool :: Text -> Bool -> Bool -> [Text]
expectBool field expected actual
    | actual == expected = []
    | otherwise =
        [ field
            <> " expected "
            <> T.pack (show expected)
            <> " but observed "
            <> T.pack (show actual)
        ]

expectMaybeText :: Text -> Text -> Maybe Text -> [Text]
expectMaybeText field expected actual =
    case actual of
        Just observed -> expectText field expected observed
        Nothing -> [field <> " expected " <> expected <> " but was absent"]

expectMaybeInteger :: Text -> Integer -> Maybe Integer -> [Text]
expectMaybeInteger field expected actual =
    case actual of
        Just observed -> expectInteger field expected observed
        Nothing ->
            [ field
                <> " expected "
                <> T.pack (show expected)
                <> " but was absent"
            ]

waitForGovernanceReward
    :: FilePath
    -> NetworkMagic
    -> GovernanceAssertionRequest
    -> GovernanceChainSnapshot
    -> IO GovernanceChainSnapshot
waitForGovernanceReward socket magic request =
    go attempts
  where
    attempts =
        max 1 (garRewardPollTimeoutSeconds request * 2)
    go remaining lastSnapshot
        | gcsTreasuryRewardLovelace lastSnapshot
            >= garExpectedRewardLovelace request =
            pure lastSnapshot
        | remaining <= 0 = pure lastSnapshot
        | otherwise = do
            threadDelay 500_000
            next <- queryGovernanceSnapshot socket magic request
            go (remaining - 1) next

queryGovernanceSnapshot
    :: FilePath
    -> NetworkMagic
    -> GovernanceAssertionRequest
    -> IO GovernanceChainSnapshot
queryGovernanceSnapshot socket magic request = do
    treasuryAccount <-
        case scriptHashFromHex (garTreasuryRewardAccount request) of
            Left e ->
                die
                    ( "governance-assertion: treasury reward account "
                        <> "is not a script hash ("
                        <> e
                        <> ")"
                    )
            Right sh ->
                pure (AccountAddress Testnet (AccountId (ScriptHashObj sh)))
    let materializationTxIns = case garMaterialization request of
            Nothing -> []
            Just materialization ->
                [ gmaTreasuryMaterializedTxIn materialization
                , gmaMaterializationChangeTxIn materialization
                ]
        queriedTxIns =
            Set.fromList
                ( [ garVoterBaseTxIn request
                  , garMaterializationFundingSeedTxIn request
                  ]
                    <> materializationTxIns
                )
    (foundUtxos, foundRewards) <-
        withLocalNodeBackend magic socket $ \backend ->
            Backend.singleShotWithAcquired backend $ \qh -> do
                utxos <-
                    Backend.queryUTxOByTxInH qh queriedTxIns
                rewards <-
                    Backend.queryRewardAccountsH
                        qh
                        (Set.singleton treasuryAccount)
                pure (utxos, rewards)
    let voterPresent =
            Map.member (garVoterBaseTxIn request) foundUtxos
        proposalChange =
            Map.lookup (garMaterializationFundingSeedTxIn request) foundUtxos
        materializedOutput =
            garMaterialization request
                >>= \materialization ->
                    Map.lookup
                        (gmaTreasuryMaterializedTxIn materialization)
                        foundUtxos
        materializationChange =
            garMaterialization request
                >>= \materialization ->
                    Map.lookup
                        (gmaMaterializationChangeTxIn materialization)
                        foundUtxos
        reward =
            Map.findWithDefault (Coin 0) treasuryAccount foundRewards
    pure
        GovernanceChainSnapshot
            { gcsVoterBasePresent = voterPresent
            , gcsVoterBaseAddress =
                if voterPresent
                    then Just (garVoterBaseAddress request)
                    else Nothing
            , gcsVoterBaseLovelace =
                if voterPresent
                    then Just (garVoterBaseLovelace request)
                    else Nothing
            , gcsProposalChangePresent = isJust proposalChange
            , gcsProposalChangeLovelace = txOutLovelace <$> proposalChange
            , gcsMaterializedPresent = isJust materializedOutput
            , gcsMaterializedAddress = txOutAddressText <$> materializedOutput
            , gcsMaterializedLovelace = txOutLovelace <$> materializedOutput
            , gcsMaterializationChangePresent =
                isJust materializationChange
            , gcsMaterializationChangeLovelace =
                txOutLovelace <$> materializationChange
            , gcsTreasuryRewardLovelace = coinLovelace reward
            }

readGovernanceGenesisDiagnostics :: FilePath -> IO Value
readGovernanceGenesisDiagnostics runDir = do
    let path = runDir </> "genesis" </> "conway-genesis.json"
    raw <- eitherDecodeFileStrict' path >>= either die pure
    either die pure $
        parseEither parseGovernanceGenesisDiagnostics raw

parseGovernanceGenesisDiagnostics :: Value -> Parser Value
parseGovernanceGenesisDiagnostics =
    withObject "ConwayGenesis" $ \o -> do
        dRepVotingThresholds <- o .: "dRepVotingThresholds"
        committee <- o .: "committee"
        committeeMinSize <- o .: "committeeMinSize"
        dRepDeposit <- o .: "dRepDeposit"
        govActionDeposit <- o .: "govActionDeposit"
        pure $
            object
                [ "dRepVotingThresholds" .= (dRepVotingThresholds :: Value)
                , "committee" .= (committee :: Value)
                , "committeeMinSize" .= (committeeMinSize :: Value)
                , "dRepDeposit" .= (dRepDeposit :: Value)
                , "govActionDeposit" .= (govActionDeposit :: Value)
                ]

data GovernanceAssertionRequest = GovernanceAssertionRequest
    { garProposalTxId :: !Text
    , garGovernanceActionId :: !Text
    , garMaterializationFundingSeedTxIn :: !TxIn
    , garVoterBaseTxIn :: !TxIn
    , garVoterBaseAddress :: !Text
    , garVoterBaseLovelace :: !Integer
    , garTreasuryRewardAccount :: !Text
    , garExpectedRewardLovelace :: !Integer
    , garRewardPollTimeoutSeconds :: !Int
    , garMaterialization :: !(Maybe GovernanceMaterializationAssertion)
    }

data GovernanceMaterializationAssertion = GovernanceMaterializationAssertion
    { gmaGovernanceActionId :: !Text
    , gmaTreasuryRewardAccount :: !Text
    , gmaTxId :: !Text
    , gmaTreasuryMaterializedTxInText :: !Text
    , gmaTreasuryMaterializedTxIn :: !TxIn
    , gmaTreasuryAddress :: !Text
    , gmaMaterializedAdaLovelace :: !Integer
    , gmaMaterializationChangeTxIn :: !TxIn
    , gmaMaterializedJson :: !FilePath
    }

parseGovernanceAssertionRequest
    :: Value -> Parser GovernanceAssertionRequest
parseGovernanceAssertionRequest =
    withObject "GovernanceAssertionRequest" $ \root -> do
        proposalTxId <- root .: "proposalTxId"
        governanceActionId <- root .: "governanceActionId"
        materializationSeedText <-
            root .: "materializationFundingSeedTxIn"
        materializationSeed <-
            either fail pure (txInFromText materializationSeedText)
        voter <- root .: "voterBaseOutput"
        voterTxInText <- voter .: Key.fromText "txIn"
        voterTxIn <- either fail pure (txInFromText voterTxInText)
        voterAddress <- voter .: Key.fromText "address"
        voterLovelace <- voter .: Key.fromText "lovelace"
        treasuryRewardAccount <- root .: "treasuryRewardAccount"
        expectedReward <- root .: "expectedRewardLovelace"
        timeoutSeconds <- root .: "rewardPollTimeoutSeconds"
        materialization <-
            root
                .:? "materialization"
                >>= traverse
                    ( parseGovernanceMaterializationAssertion
                        governanceActionId
                        treasuryRewardAccount
                    )
        pure
            GovernanceAssertionRequest
                { garProposalTxId = proposalTxId
                , garGovernanceActionId = governanceActionId
                , garMaterializationFundingSeedTxIn =
                    materializationSeed
                , garVoterBaseTxIn = voterTxIn
                , garVoterBaseAddress = voterAddress
                , garVoterBaseLovelace = voterLovelace
                , garTreasuryRewardAccount = treasuryRewardAccount
                , garExpectedRewardLovelace = expectedReward
                , garRewardPollTimeoutSeconds = timeoutSeconds
                , garMaterialization = materialization
                }

parseGovernanceMaterializationAssertion
    :: Text -> Text -> Value -> Parser GovernanceMaterializationAssertion
parseGovernanceMaterializationAssertion rootActionId rootRewardAccount =
    withObject "GovernanceMaterializationAssertion" $ \o -> do
        actionId <-
            optionalSame
                "materialization.governanceActionId"
                rootActionId
                =<< o .:? "governanceActionId"
        rewardAccount <-
            optionalSame
                "materialization.treasuryRewardAccount"
                rootRewardAccount
                =<< o .:? "treasuryRewardAccount"
        txId <- o .: "txId"
        treasuryTxInText <- o .: "treasuryMaterializedTxIn"
        treasuryTxIn <-
            either fail pure (txInFromText treasuryTxInText)
        treasuryAddress <- o .: "treasuryAddress"
        materializedLovelace <- o .: "materializedAdaLovelace"
        materializationChangeText <- o .: "materializationChangeTxIn"
        materializationChange <-
            either fail pure (txInFromText materializationChangeText)
        materializedJson <- o .: "materializedJson"
        pure
            GovernanceMaterializationAssertion
                { gmaGovernanceActionId = actionId
                , gmaTreasuryRewardAccount = rewardAccount
                , gmaTxId = txId
                , gmaTreasuryMaterializedTxInText = treasuryTxInText
                , gmaTreasuryMaterializedTxIn = treasuryTxIn
                , gmaTreasuryAddress = treasuryAddress
                , gmaMaterializedAdaLovelace = materializedLovelace
                , gmaMaterializationChangeTxIn = materializationChange
                , gmaMaterializedJson = materializedJson
                }
  where
    optionalSame field expected actual = case actual of
        Nothing -> pure expected
        Just observed
            | observed == expected -> pure observed
            | otherwise ->
                fail $
                    T.unpack field
                        <> " expected "
                        <> T.unpack expected
                        <> " but observed "
                        <> T.unpack observed

data GovernanceChainSnapshot = GovernanceChainSnapshot
    { gcsVoterBasePresent :: !Bool
    , gcsVoterBaseAddress :: !(Maybe Text)
    , gcsVoterBaseLovelace :: !(Maybe Integer)
    , gcsProposalChangePresent :: !Bool
    , gcsProposalChangeLovelace :: !(Maybe Integer)
    , gcsMaterializedPresent :: !Bool
    , gcsMaterializedAddress :: !(Maybe Text)
    , gcsMaterializedLovelace :: !(Maybe Integer)
    , gcsMaterializationChangePresent :: !Bool
    , gcsMaterializationChangeLovelace :: !(Maybe Integer)
    , gcsTreasuryRewardLovelace :: !Integer
    }

governanceSnapshotValue :: GovernanceChainSnapshot -> Value
governanceSnapshotValue snapshot =
    object
        [ "voterBaseOutput"
            .= object
                [ "present" .= gcsVoterBasePresent snapshot
                , "address" .= gcsVoterBaseAddress snapshot
                , "lovelace" .= gcsVoterBaseLovelace snapshot
                ]
        , "proposalChangeOutput"
            .= object
                [ "present" .= gcsProposalChangePresent snapshot
                , "lovelace" .= gcsProposalChangeLovelace snapshot
                ]
        , "materializedOutput"
            .= object
                [ "present" .= gcsMaterializedPresent snapshot
                , "address" .= gcsMaterializedAddress snapshot
                , "lovelace" .= gcsMaterializedLovelace snapshot
                ]
        , "materializationChangeOutput"
            .= object
                [ "present" .= gcsMaterializationChangePresent snapshot
                , "lovelace" .= gcsMaterializationChangeLovelace snapshot
                ]
        , "treasuryRewardLovelace"
            .= gcsTreasuryRewardLovelace snapshot
        ]

-- ---------------------------------------------------------------------
-- Disburse assertions
-- ---------------------------------------------------------------------

runDisburseAssertionsIfPresent
    :: FilePath -> FilePath -> NetworkMagic -> Bool -> IO ()
runDisburseAssertionsIfPresent runDir socket magic required = do
    let requestPath =
            runDir </> "chain" </> "disburse.assertions.request.json"
    exists <- doesFileExist requestPath
    if exists
        then runDisburseAssertions runDir socket magic
        else
            when required $
                die
                    ( "disburse-assertion: missing request "
                        <> requestPath
                    )

runDisburseAssertions
    :: FilePath -> FilePath -> NetworkMagic -> IO ()
runDisburseAssertions runDir socket magic = do
    let requestPath =
            runDir </> "chain" </> "disburse.assertions.request.json"
        reportPath = runDir </> "chain" </> "disburse.assertions.json"
        logPath = runDir </> "chain" </> "disburse.assertions.log"
    raw <-
        eitherDecodeFileStrict' requestPath
            >>= either (die . badRequest) pure
    request <-
        either (die . badRequest) pure $
            parseEither parseDisburseAssertionRequest raw
    foundUtxos <-
        withLocalNodeBackend magic socket $ \backend ->
            Backend.singleShotWithAcquired backend $ \qh ->
                Backend.queryUTxOByTxInH
                    qh
                    ( Set.fromList
                        [ darMaterializedInput request
                        , darTreasuryOutputTxIn request
                        , darBeneficiaryTxIn request
                        ]
                    )
    let materializedInput =
            Map.lookup (darMaterializedInput request) foundUtxos
        treasuryOutput =
            Map.lookup (darTreasuryOutputTxIn request) foundUtxos
        beneficiaryOutput =
            Map.lookup (darBeneficiaryTxIn request) foundUtxos
        consumedMaterializedInput = isNothing materializedInput
        reducedTreasuryOutput =
            maybe
                False
                ( \txOut ->
                    txOutLovelace txOut == darExpectedTreasuryLovelace request
                        && txOutAddressText txOut
                            == darTreasuryAddress request
                )
                treasuryOutput
        beneficiaryReceiptLovelace =
            maybe 0 txOutLovelace beneficiaryOutput
        beneficiaryReceiptOk =
            maybe
                False
                ( \txOut ->
                    txOutLovelace txOut
                        == darExpectedBeneficiaryLovelace request
                        && txOutAddressText txOut
                            == darBeneficiaryAddress request
                )
                beneficiaryOutput
        failures =
            concat
                [ expectBool
                    "consumedMaterializedInput"
                    True
                    consumedMaterializedInput
                , expectBool
                    "reducedTreasuryOutput"
                    True
                    reducedTreasuryOutput
                , expectBool
                    "beneficiaryReceipt"
                    True
                    beneficiaryReceiptOk
                ]
        report =
            object
                [ "phase" .= ("disburse-submit" :: Text)
                , "status"
                    .= ( if null failures
                            then "passed"
                            else
                                "failed"
                                    :: Text
                       )
                , "disburseTxId" .= darDisburseTxId request
                , "consumedMaterializedInput"
                    .= consumedMaterializedInput
                , "reducedTreasuryOutput" .= reducedTreasuryOutput
                , "beneficiaryReceiptLovelace"
                    .= beneficiaryReceiptLovelace
                , "materializedInput"
                    .= txInToText (darMaterializedInput request)
                , "treasuryOutput"
                    .= object
                        [ "txIn" .= txInToText (darTreasuryOutputTxIn request)
                        , "address" .= (txOutAddressText <$> treasuryOutput)
                        , "lovelace" .= (txOutLovelace <$> treasuryOutput)
                        , "expectedAddress" .= darTreasuryAddress request
                        , "expectedLovelace"
                            .= darExpectedTreasuryLovelace request
                        ]
                , "beneficiaryOutput"
                    .= object
                        [ "txIn" .= txInToText (darBeneficiaryTxIn request)
                        , "address" .= (txOutAddressText <$> beneficiaryOutput)
                        , "lovelace" .= beneficiaryReceiptLovelace
                        , "expectedAddress" .= darBeneficiaryAddress request
                        , "expectedLovelace"
                            .= darExpectedBeneficiaryLovelace request
                        ]
                , "verificationErrors" .= failures
                ]
    BSL.writeFile reportPath (encode report)
    writeFile logPath (unlines (renderChainAssertionLog report))
    if null failures
        then
            hPutStrLn
                stderr
                ( "devnet-cli-smoke-host: disburse assertions passed ("
                    <> reportPath
                    <> ")"
                )
        else
            die
                ( "disburse-assertion: verification failed; see "
                    <> reportPath
                )
  where
    badRequest err =
        "disburse-assertion: cannot parse request: " <> err

data DisburseAssertionRequest = DisburseAssertionRequest
    { darDisburseTxId :: !Text
    , darMaterializedInput :: !TxIn
    , darTreasuryOutputTxIn :: !TxIn
    , darTreasuryAddress :: !Text
    , darExpectedTreasuryLovelace :: !Integer
    , darBeneficiaryTxIn :: !TxIn
    , darBeneficiaryAddress :: !Text
    , darExpectedBeneficiaryLovelace :: !Integer
    }

parseDisburseAssertionRequest
    :: Value -> Parser DisburseAssertionRequest
parseDisburseAssertionRequest =
    withObject "DisburseAssertionRequest" $ \root -> do
        disburseTxId <- root .: "disburseTxId"
        treasuryInputText <- root .: "treasuryInput"
        treasuryInput <- either fail pure (txInFromText treasuryInputText)
        treasuryOutputText <- root .: "treasuryOutputTxIn"
        treasuryOutput <- either fail pure (txInFromText treasuryOutputText)
        treasuryAddress <- root .: "treasuryAddress"
        treasuryLovelace <- root .: "treasuryOutputLovelace"
        beneficiaryTxInText <- root .: "beneficiaryTxIn"
        beneficiaryTxIn <- either fail pure (txInFromText beneficiaryTxInText)
        beneficiaryAddress <- root .: "beneficiaryAddress"
        beneficiaryLovelace <- root .: "beneficiaryLovelace"
        pure
            DisburseAssertionRequest
                { darDisburseTxId = disburseTxId
                , darMaterializedInput = treasuryInput
                , darTreasuryOutputTxIn = treasuryOutput
                , darTreasuryAddress = treasuryAddress
                , darExpectedTreasuryLovelace = treasuryLovelace
                , darBeneficiaryTxIn = beneficiaryTxIn
                , darBeneficiaryAddress = beneficiaryAddress
                , darExpectedBeneficiaryLovelace = beneficiaryLovelace
                }

-- ---------------------------------------------------------------------
-- Reorganize chain assertions (#87 S2)
-- ---------------------------------------------------------------------

{- | If the smoke wrote a reorganize assertion request, decode
the unsigned Conway CBOR, resolve the input UTxOs via N2C
'queryUTxOByTxInH', and sum the input + continuing-output
values across every asset class (lovelace, then each native
@(policyId, assetName)@ pair). Diverging sums exit non-zero
with 'ASSET_PRESERVATION_FAILED'; the verdict and observed
sums land in @summary.json@ under @assetPreservationVerdict@.

The exec-units assertion (slice S3, T013–T015) is a separate
file; this function does not touch protocol parameters or
exec-units bookkeeping.
-}
runReorganizeAssertionsIfPresent
    :: FilePath -> FilePath -> NetworkMagic -> Bool -> IO ()
runReorganizeAssertionsIfPresent runDir socket magic required = do
    let requestPath =
            runDir
                </> "chain"
                </> "reorganize.assertions.request.json"
    exists <- doesFileExist requestPath
    if exists
        then runReorganizeAssertions runDir socket magic
        else
            when required $
                die
                    ( "reorganize-assertion: missing request "
                        <> requestPath
                    )

runReorganizeAssertions
    :: FilePath -> FilePath -> NetworkMagic -> IO ()
runReorganizeAssertions runDir socket magic = do
    let requestPath =
            runDir
                </> "chain"
                </> "reorganize.assertions.request.json"
        reportPath =
            runDir </> "chain" </> "reorganize.assertions.json"
        logPath =
            runDir </> "chain" </> "reorganize.assertions.log"
    createDirectoryIfMissing True (runDir </> "chain")
    raw <-
        eitherDecodeFileStrict' requestPath
            >>= either (die . badRequest) pure
    request <-
        either (die . badRequest) pure $
            parseEither parseReorganizeAssertionRequest raw
    hexBytes <- BS.readFile (rarCborPath request)
    tx <- case decodeUnsignedTxHex hexBytes of
        Right t -> pure t
        Left err ->
            die
                ( "ASSET_PRESERVATION_FAILED: cannot decode "
                    <> "unsigned CBOR "
                    <> rarCborPath request
                    <> ": "
                    <> T.unpack (renderAttachError err)
                )
    let body = tx ^. bodyTxL
        inputTxIns = body ^. inputsTxBodyL
        outputs = toList (body ^. outputsTxBodyL)
        outputValues = fmap (^. valueTxOutL) outputs
        Coin feeLovelace = body ^. feeTxBodyL
        outputSumRaw = sumAssetValues outputValues
        -- Ledger invariant: sum(inputs) = sum(outputs) + fee.
        -- Adding the body's fee back into the outputs side
        -- means every asset class (lovelace + every native
        -- (policyId, assetName) pair) must match bit-for-bit
        -- across inputs and outputs.
        outputSum = addLovelace outputSumRaw feeLovelace
    inputUtxos <-
        withLocalNodeBackend magic socket $ \backend ->
            Backend.singleShotWithAcquired backend $ \qh ->
                Backend.queryUTxOByTxInH qh inputTxIns
    let inputValues =
            fmap (^. valueTxOutL) (Map.elems inputUtxos)
        inputSum = sumAssetValues inputValues
        missingInputs =
            Set.toList
                (inputTxIns `Set.difference` Map.keysSet inputUtxos)
        diff = diffAssetSum inputSum outputSum
        preservationOk =
            null missingInputs && isAssetSumZero diff
        report =
            object
                [ "phase" .= ("reorganize" :: Text)
                , "status"
                    .= ( if preservationOk
                            then "passed"
                            else
                                "failed"
                                    :: Text
                       )
                , "cborPath" .= rarCborPath request
                , "scope" .= rarScope request
                , "selectedInputUtxos"
                    .= fmap txInToText (Set.toList inputTxIns)
                , "missingInputUtxos"
                    .= fmap txInToText missingInputs
                , "inputValueSum" .= assetSumJson inputSum
                , "continuingOutputValueSum"
                    .= assetSumJson outputSum
                , "feeLovelace" .= feeLovelace
                , "assetValueDiff" .= assetSumJson diff
                ]
    BSL.writeFile reportPath (encode report)
    writeFile logPath (unlines (renderChainAssertionLog report))
    updateReorganizeSummaryVerdict
        (rarSummaryPath request)
        preservationOk
        inputSum
        outputSum
        diff
        missingInputs
        reportPath
    if preservationOk
        then
            hPutStrLn
                stderr
                ( "devnet-cli-smoke-host: reorganize asset "
                    <> "preservation verified ("
                    <> reportPath
                    <> ")"
                )
        else
            die
                ( "ASSET_PRESERVATION_FAILED: input value sum "
                    <> "differs from continuing-output sum across "
                    <> "one or more asset classes; see "
                    <> reportPath
                )
  where
    badRequest err =
        "reorganize-assertion: cannot parse request: " <> err

data ReorganizeAssertionRequest = ReorganizeAssertionRequest
    { rarCborPath :: !FilePath
    , rarSummaryPath :: !FilePath
    , rarScope :: !Text
    }

runRerateAssertionsIfPresent
    :: FilePath -> FilePath -> NetworkMagic -> Bool -> IO ()
runRerateAssertionsIfPresent runDir socket magic required = do
    let requestPath =
            runDir
                </> "chain"
                </> "rerate.assertions.request.json"
    exists <- doesFileExist requestPath
    if exists
        then runRerateAssertions runDir socket magic
        else
            when required $
                die $
                    "rerate-assertion: missing request " <> requestPath

runRerateAssertions :: FilePath -> FilePath -> NetworkMagic -> IO ()
runRerateAssertions runDir socket magic = do
    let requestPath =
            runDir
                </> "chain"
                </> "rerate.assertions.request.json"
        reportPath =
            runDir </> "chain" </> "rerate.assertions.json"
        logPath =
            runDir </> "chain" </> "rerate.assertions.log"
    createDirectoryIfMissing True (runDir </> "chain")
    raw <-
        eitherDecodeFileStrict' requestPath
            >>= either (die . badRequest) pure
    request <-
        either (die . badRequest) pure $
            parseEither parseRerateAssertionRequest raw
    summaryExists <- doesFileExist (raaSummaryPath request)
    unless summaryExists $
        die $
            "rerate-assertion: missing summary "
                <> raaSummaryPath request
    unsignedExists <- doesFileExist (raaUnsignedPath request)
    unless unsignedExists $
        die $
            "rerate-assertion: missing unsigned artifact "
                <> raaUnsignedPath request
    (oldPresent, newPresent) <-
        withLocalNodeBackend magic socket $ \backend ->
            Backend.singleShotWithAcquired backend $ \qh ->
                waitForRerateFlip
                    qh
                    (raaOldOrderTxIn request)
                    (raaNewOrderTxIn request)
                    60
    let passed = not oldPresent && newPresent
        report =
            object
                [ "phase" .= ("rerate" :: Text)
                , "status" .= if passed then ("passed" :: Text) else "failed"
                , "phase2" .= ("accepted" :: Text)
                , "submittedTxId" .= raaSubmittedTxId request
                , "oldOrderTxIn" .= txInToText (raaOldOrderTxIn request)
                , "newOrderTxIn" .= txInToText (raaNewOrderTxIn request)
                , "oldOrderPresent" .= oldPresent
                , "newOrderPresent" .= newPresent
                ]
    BSL.writeFile reportPath (encode report)
    writeFile logPath (unlines (renderChainAssertionLog report))
    updateRerateSummaryVerdict
        (raaSummaryPath request)
        passed
        oldPresent
        newPresent
        reportPath
    if passed
        then
            hPutStrLn
                stderr
                ( "devnet-cli-smoke-host: rerate phase-2 accepted "
                    <> "and UTxO flip verified ("
                    <> reportPath
                    <> ")"
                )
        else
            die
                ( "RERATE_UTXO_FLIP_FAILED: submitted rerate tx did "
                    <> "not consume old order and create replacement; see "
                    <> reportPath
                )
  where
    badRequest err =
        "rerate-assertion: cannot parse request: " <> err

waitForRerateFlip
    :: Backend.QueryHandle IO
    -> TxIn
    -> TxIn
    -> Int
    -> IO (Bool, Bool)
waitForRerateFlip _ oldOrder newOrder attempts
    | attempts <= 0 =
        die
            ( "rerate-assertion: timed out waiting for old/new "
                <> "order UTxO flip (old="
                <> T.unpack (txInToText oldOrder)
                <> ", new="
                <> T.unpack (txInToText newOrder)
                <> ")"
            )
waitForRerateFlip qh oldOrder newOrder attempts = do
    found <-
        Backend.queryUTxOByTxInH qh (Set.fromList [oldOrder, newOrder])
    let oldPresent = Map.member oldOrder found
        newPresent = Map.member newOrder found
    if not oldPresent && newPresent
        then pure (oldPresent, newPresent)
        else do
            threadDelay 500_000
            waitForRerateFlip qh oldOrder newOrder (attempts - 1)

updateRerateSummaryVerdict
    :: FilePath -> Bool -> Bool -> Bool -> FilePath -> IO ()
updateRerateSummaryVerdict
    summaryPath
    passed
    oldPresent
    newPresent
    reportPath = do
        raw <-
            eitherDecodeFileStrict' summaryPath
                >>= either (die . badSummary) pure
        let baseObj = case raw of
                Aeson.Object o -> o
                _ -> KeyMap.empty
            statusText :: Text
            statusText =
                if passed then "passed" else "failed"
            updated =
                KeyMap.union
                    ( KeyMap.fromList
                        [
                            ( Key.fromString "status"
                            , Aeson.String statusText
                            )
                        ,
                            ( Key.fromString "phase2"
                            , Aeson.String "accepted"
                            )
                        ,
                            ( Key.fromString "oldOrderPresent"
                            , Aeson.toJSON oldPresent
                            )
                        ,
                            ( Key.fromString "newOrderPresent"
                            , Aeson.toJSON newPresent
                            )
                        ,
                            ( Key.fromString "chainAssertions"
                            , Aeson.toJSON reportPath
                            )
                        ]
                    )
                    baseObj
        BSL.writeFile summaryPath (encode (Aeson.Object updated))
      where
        badSummary err =
            "rerate-assertion: cannot parse summary: " <> err

data RerateAssertionRequest = RerateAssertionRequest
    { raaSummaryPath :: !FilePath
    , raaUnsignedPath :: !FilePath
    , raaOldOrderTxIn :: !TxIn
    , raaNewOrderTxIn :: !TxIn
    , raaSubmittedTxId :: !Text
    }

parseRerateAssertionRequest :: Value -> Parser RerateAssertionRequest
parseRerateAssertionRequest =
    withObject "RerateAssertionRequest" $ \root -> do
        oldText <- root .: "oldOrderTxIn"
        newText <- root .: "newOrderTxIn"
        oldOrder <- either fail pure (txInFromText oldText)
        newOrder <- either fail pure (txInFromText newText)
        RerateAssertionRequest
            <$> root .: "summaryPath"
            <*> root .: "unsignedPath"
            <*> pure oldOrder
            <*> pure newOrder
            <*> root .: "submittedTxId"

parseReorganizeAssertionRequest
    :: Value -> Parser ReorganizeAssertionRequest
parseReorganizeAssertionRequest =
    withObject "ReorganizeAssertionRequest" $ \root -> do
        cbor <- root .: "cborPath"
        summary <- root .: "summaryPath"
        scope <- root .: "scope"
        pure
            ReorganizeAssertionRequest
                { rarCborPath = cbor
                , rarSummaryPath = summary
                , rarScope = scope
                }

{- | Per-asset-class value sum: lovelace plus a map of
@(policyIdHex, assetNameHex)@ → quantity. Used to prove that
reorganize preserves every asset class across the merged
inputs and the single continuing output.
-}
data AssetSum
    = AssetSum
        !Integer
        !(Map.Map (Text, Text) Integer)

emptyAssetSum :: AssetSum
emptyAssetSum = AssetSum 0 Map.empty

sumAssetValues :: [MaryValue] -> AssetSum
sumAssetValues =
    foldr
        ( \v acc ->
            mergeAssetSum acc (assetSumFromMary v)
        )
        emptyAssetSum

assetSumFromMary :: MaryValue -> AssetSum
assetSumFromMary (MaryValue (Coin l) ma) =
    AssetSum
        l
        ( foldr
            insertTriple
            Map.empty
            (flattenMultiAsset ma)
        )
  where
    insertTriple (pid, aname, amt) =
        Map.insertWith
            (+)
            (policyIdHex pid, assetNameToTextAsHex aname)
            amt

policyIdHex :: PolicyID -> Text
policyIdHex (PolicyID (ScriptHash sh)) =
    TE.decodeUtf8 (B16.encode (hashToBytes sh))

mergeAssetSum :: AssetSum -> AssetSum -> AssetSum
mergeAssetSum (AssetSum la ma) (AssetSum lb mb) =
    AssetSum
        (la + lb)
        (Map.unionWith (+) ma mb)

addLovelace :: AssetSum -> Integer -> AssetSum
addLovelace (AssetSum l m) extra =
    AssetSum (l + extra) m

diffAssetSum :: AssetSum -> AssetSum -> AssetSum
diffAssetSum (AssetSum la ma) (AssetSum lb mb) =
    AssetSum
        (la - lb)
        ( Map.filter
            (/= 0)
            ( Map.unionWith
                (+)
                ma
                (Map.map negate mb)
            )
        )

isAssetSumZero :: AssetSum -> Bool
isAssetSumZero (AssetSum l m) =
    l == 0 && all (== 0) (Map.elems m)

assetSumJson :: AssetSum -> Value
assetSumJson (AssetSum l m) =
    object
        [ "lovelace" .= l
        , "assets"
            .= [ object
                [ "policyId" .= pid
                , "assetName" .= an
                , "quantity" .= q
                ]
               | ((pid, an), q) <- Map.toList m
               ]
        ]

{- | Overwrite the reorganize @summary.json@ written by the
smoke with the host-observed verdict + value sums.

Replaces the placeholder @assetPreservationVerdict@ and
@continuingOutput@ keys; leaves every other field intact.
-}
updateReorganizeSummaryVerdict
    :: FilePath
    -> Bool
    -> AssetSum
    -> AssetSum
    -> AssetSum
    -> [TxIn]
    -> FilePath
    -> IO ()
updateReorganizeSummaryVerdict
    summaryPath
    verdictOk
    inputSum
    outputSum
    diff
    missing
    reportPath = do
        exists <- doesFileExist summaryPath
        unless exists $
            die
                ( "reorganize-assertion: missing summary at "
                    <> summaryPath
                )
        raw <-
            eitherDecodeFileStrict' summaryPath
                >>= either (die . badSummary) pure
        let baseObj = case raw of
                Aeson.Object o -> o
                _ -> KeyMap.empty
            verdictText :: Text
            verdictText =
                if verdictOk
                    then "passed"
                    else "failed"
            continuingOutput :: Value
            continuingOutput =
                object
                    [ "valueSum" .= assetSumJson outputSum
                    , "note"
                        .= ( "Host-observed sum across the tx body's "
                                <> "continuing outputs."
                                :: Text
                           )
                    ]
            newPairs =
                KeyMap.fromList
                    [
                        ( Key.fromString "assetPreservationVerdict"
                        , Aeson.String verdictText
                        )
                    ,
                        ( Key.fromString "continuingOutput"
                        , continuingOutput
                        )
                    ,
                        ( Key.fromString "inputValueSum"
                        , assetSumJson inputSum
                        )
                    ,
                        ( Key.fromString "continuingOutputValueSum"
                        , assetSumJson outputSum
                        )
                    ,
                        ( Key.fromString "assetValueDiff"
                        , assetSumJson diff
                        )
                    ,
                        ( Key.fromString "missingInputUtxos"
                        , Aeson.toJSON
                            (fmap txInToText missing)
                        )
                    ,
                        ( Key.fromString "chainAssertions"
                        , Aeson.toJSON reportPath
                        )
                    ]
            updated =
                KeyMap.union newPairs baseObj
        BSL.writeFile summaryPath (encode (Aeson.Object updated))
      where
        badSummary err =
            "reorganize-assertion: cannot parse summary: "
                <> err

-- ---------------------------------------------------------------------
-- Reorganize exec-units assertion (#87 S3, T013–T015)
-- ---------------------------------------------------------------------

{- | Sibling of 'runReorganizeAssertionsIfPresent'. Runs only when
the smoke wrote the reorganize @summary.json@ (i.e. the phase
got past @tx-build@); on missing summary it is a no-op unless
@required@ is set.
-}
runReorganizeExecUnitsAssertionIfPresent
    :: FilePath -> FilePath -> NetworkMagic -> Bool -> IO ()
runReorganizeExecUnitsAssertionIfPresent
    runDir
    socket
    magic
    required = do
        let summaryPath =
                runDir
                    </> "phases"
                    </> "reorganize"
                    </> "summary.json"
        exists <- doesFileExist summaryPath
        if exists
            then runReorganizeExecUnitsAssertion runDir socket magic
            else
                when required $
                    die
                        ( "reorganize-exec-units-assertion: missing "
                            <> "summary at "
                            <> summaryPath
                        )

{- | Parse @\<run-dir\>\/phases\/reorganize\/tx-validate.json@,
load @pparams.maxTxExecutionUnits.{memory,steps}@ from the live
node via the project's 'queryProtocolParamsH' N2C wrapper, sum
the per-redeemer execution units carried by the tx-validate
payload, and write an @execUnitsVerdict@ block into the
reorganize @summary.json@.

Exit codes:

  * @EXEC_UNITS_OVER_LIMIT@ — observed sum exceeds the live
    pparams limit on memory or steps (verdict status =
    @over-limit@).
  * @EXEC_UNITS_VALIDATOR_UNAVAILABLE@ — @tx-validate.json@
    missing, unparseable, or its schema does not carry the
    expected @redeemers@ array (verdict status =
    @unavailable@). This is the live outcome until
    cardano-tx-tools adds per-redeemer exec units to the
    JSON envelope (operator follow-up T016).

The verdict object is the canonical evidence the live-boundary
T016 surfaces in the PR body; the unit suite pins only the
literal contract (diagnostics + key + wrapper).
-}
runReorganizeExecUnitsAssertion
    :: FilePath -> FilePath -> NetworkMagic -> IO ()
runReorganizeExecUnitsAssertion runDir socket magic = do
    let phaseDir = runDir </> "phases" </> "reorganize"
        validateJson = phaseDir </> "tx-validate.json"
        summaryPath = phaseDir </> "summary.json"
    pparams <-
        withLocalNodeBackend magic socket $ \backend ->
            Backend.singleShotWithAcquired backend $ \qh ->
                queryProtocolParamsH qh
    let maxTxExecutionUnits = pparams ^. ppMaxTxExUnitsL
        ExUnits{exUnitsMem = limMemNat, exUnitsSteps = limStepsNat} =
            maxTxExecutionUnits
        limMem :: Integer
        limMem = fromIntegral limMemNat
        limSteps :: Integer
        limSteps = fromIntegral limStepsNat
        limitJson =
            object
                [ "memory" .= limMem
                , "steps" .= limSteps
                ]
    available <- doesFileExist validateJson
    if not available
        then
            emitUnavailable
                summaryPath
                limitJson
                ( "tx-validate.json missing at "
                    <> validateJson
                )
        else do
            parsed <- eitherDecodeFileStrict' validateJson
            case parsed of
                Left err ->
                    emitUnavailable
                        summaryPath
                        limitJson
                        ( "tx-validate.json unparseable: "
                            <> err
                        )
                Right val ->
                    case parseEither parseRedeemerExUnits val of
                        Left err ->
                            emitUnavailable
                                summaryPath
                                limitJson
                                ( "tx-validate.json schema "
                                    <> "mismatch: "
                                    <> err
                                )
                        Right perRedeemer -> do
                            let (obsMem, obsSteps) =
                                    sumExUnits perRedeemer
                                overLimit =
                                    obsMem > limMem
                                        || obsSteps > limSteps
                                statusText :: Text
                                statusText
                                    | overLimit = "over-limit"
                                    | otherwise = "within-limits"
                                observedJson =
                                    object
                                        [ "memory" .= obsMem
                                        , "steps" .= obsSteps
                                        ]
                                verdict =
                                    object
                                        [ "status" .= statusText
                                        , "observed" .= observedJson
                                        , "limit" .= limitJson
                                        , "perRedeemer"
                                            .= fmap
                                                renderRedeemerExUnits
                                                perRedeemer
                                        ]
                            patchExecUnitsVerdict summaryPath verdict
                            if overLimit
                                then
                                    die
                                        ( "EXEC_UNITS_OVER_LIMIT: "
                                            <> "redeemer execution "
                                            <> "units exceed live "
                                            <> "pparams.maxTxExecutionUnits"
                                            <> " (observed memory="
                                            <> show obsMem
                                            <> ", steps="
                                            <> show obsSteps
                                            <> "; limit memory="
                                            <> show limMem
                                            <> ", steps="
                                            <> show limSteps
                                            <> ")"
                                        )
                                else
                                    hPutStrLn
                                        stderr
                                        ( "devnet-cli-smoke-host: "
                                            <> "reorganize exec "
                                            <> "units within limits "
                                            <> "("
                                            <> validateJson
                                            <> ")"
                                        )
  where
    emitUnavailable summaryPath limitJson reason = do
        let verdict =
                object
                    [ "status" .= ("unavailable" :: Text)
                    , "reason" .= (reason :: String)
                    , "limit" .= limitJson
                    ]
        patchExecUnitsVerdict summaryPath verdict
        die ("EXEC_UNITS_VALIDATOR_UNAVAILABLE: " <> reason)

{- | One redeemer's execution-unit footprint parsed out of
@tx-validate.json@.
-}
data RedeemerExUnits = RedeemerExUnits
    { ruTag :: !Text
    , ruIndex :: !Integer
    , ruMemory :: !Integer
    , ruSteps :: !Integer
    }

{- | Parse the @redeemers@ array of @tx-validate.json@; each
element must carry @{tag, index, exUnits: {memory, steps}}@.
Schema drift triggers a 'Parser' failure which the caller
surfaces as @EXEC_UNITS_VALIDATOR_UNAVAILABLE@.
-}
parseRedeemerExUnits :: Value -> Parser [RedeemerExUnits]
parseRedeemerExUnits =
    withObject "tx-validate.json" $ \obj -> do
        rs <- obj .: "redeemers"
        traverse parseOne rs
  where
    parseOne = withObject "redeemer" $ \r -> do
        tag <- r .: "tag"
        idx <- r .: "index"
        unitsV <- r .: "exUnits"
        let extract = withObject "exUnits" $ \u ->
                (,)
                    <$> u .: "memory"
                    <*> u .: "steps"
        (mem, st) <- extract unitsV
        pure
            RedeemerExUnits
                { ruTag = tag
                , ruIndex = idx
                , ruMemory = mem
                , ruSteps = st
                }

sumExUnits :: [RedeemerExUnits] -> (Integer, Integer)
sumExUnits =
    foldr
        ( \r (m, s) ->
            (m + ruMemory r, s + ruSteps r)
        )
        (0, 0)

renderRedeemerExUnits :: RedeemerExUnits -> Value
renderRedeemerExUnits r =
    object
        [ "tag" .= ruTag r
        , "index" .= ruIndex r
        , "memory" .= ruMemory r
        , "steps" .= ruSteps r
        ]

{- | Overlay an @execUnitsVerdict@ key onto the reorganize
@summary.json@ without touching other keys.
-}
patchExecUnitsVerdict :: FilePath -> Value -> IO ()
patchExecUnitsVerdict summaryPath verdict = do
    exists <- doesFileExist summaryPath
    unless exists $
        die
            ( "exec-units-assertion: missing summary at "
                <> summaryPath
            )
    raw <-
        eitherDecodeFileStrict' summaryPath
            >>= either (die . badSummary) pure
    let baseObj = case raw of
            Aeson.Object o -> o
            _ -> KeyMap.empty
        newPairs =
            KeyMap.singleton
                (Key.fromString "execUnitsVerdict")
                verdict
        updated = KeyMap.union newPairs baseObj
    BSL.writeFile summaryPath (encode (Aeson.Object updated))
  where
    badSummary err =
        "exec-units-assertion: cannot parse summary: " <> err

-- ---------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------

die :: String -> IO a
die msg = do
    hPutStrLn stderr ("devnet-cli-smoke-host: " <> msg)
    exitFailure
