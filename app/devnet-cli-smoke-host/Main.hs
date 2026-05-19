{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Main
Description : Narrow DevNet lifecycle host for the CLI smoke (#161)
License     : Apache-2.0

This executable is intentionally not a transaction
runner. It owns DevNet lifecycle, governance-genesis
patching, deterministic key fixture generation, and
launching @scripts\/smoke\/smoke.sh --inside-devnet@.
The shell smoke is the only place where bootstrap
transactions are built, signed, and submitted, and it
only uses the shipped @amaru-treasury-tx@ CLI to do
so.

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
import Cardano.Ledger.Hashes (KeyHash (..))
import Cardano.Ledger.Keys
    ( VKey (..)
    , hashKey
    )
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup
    ( devnetMagic
    , genesisDir
    , genesisSignKey
    , mkSignKey
    )
import Control.Monad (unless, when)
import Data.Aeson (encode, object, (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.Foldable (traverse_)
import Data.List (isPrefixOf)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
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
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Posix.Files (ownerReadMode, setFileMode)
import System.Process
    ( createProcess
    , env
    , proc
    , waitForProcess
    )

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

    withCardanoNode smokeGenesis $ \socket _startMs -> do
        keys <- writeDevnetKeyFixtures runDir
        let NetworkMagic magicWord = devnetMagic
            envEntries =
                [ ("CLI_SMOKE_RUN_DIR", runDir)
                , ("CARDANO_NODE_SOCKET_PATH", socket)
                , ("CLI_SMOKE_SOCKET", socket)
                , ("CLI_SMOKE_NETWORK_MAGIC", show magicWord)
                , ("CLI_SMOKE_NETWORK_NAME", "devnet")
                , ("CLI_SMOKE_GENESIS_DIR", smokeGenesis)
                , ("CLI_SMOKE_FUNDING_SKEY", devnetFundingSkeyPath keys)
                , ("CLI_SMOKE_FUNDING_KEY_HASH", devnetFundingKeyHashHex keys)
                , ("CLI_SMOKE_VOTER_SKEY", devnetVoterSkeyPath keys)
                , ("CLI_SMOKE_VOTER_KEY_HASH", devnetVoterKeyHashHex keys)
                ]
        callSmokeScript opts runDir envEntries

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
as cardano-cli payment signing-key JSON envelopes
with @0600@ permissions.
-}
data DevnetKeys = DevnetKeys
    { devnetFundingSkeyPath :: !FilePath
    , devnetFundingKeyHashHex :: !String
    , devnetVoterSkeyPath :: !FilePath
    , devnetVoterKeyHashHex :: !String
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
            , devnetFundingKeyHashHex = paymentKeyHashHex genesisSignKey
            , devnetVoterSkeyPath = voterPath
            , devnetVoterKeyHashHex = paymentKeyHashHex voterSignKey
            }

{- | Deterministic voter signing key, matching
@SmokeSpec@'s voter seed so artifacts compare
directly.
-}
voterSignKey :: SignKeyDSIGN Ed25519DSIGN
voterSignKey =
    mkSignKey "amaru-governance-voter-key-00001"

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

paymentKeyHashHex :: SignKeyDSIGN Ed25519DSIGN -> String
paymentKeyHashHex sk =
    case hashKey (VKey (deriveVerKeyDSIGN sk)) of
        KeyHash kh ->
            BS8.unpack (B16.encode (hashToBytes kh))
                :: String

-- ---------------------------------------------------------------------
-- Smoke script handoff
-- ---------------------------------------------------------------------

callSmokeScript
    :: HostOpts
    -> FilePath
    -> [(String, String)]
    -> IO ()
callSmokeScript opts runDir extraEnv = do
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
            , hoPhase opts
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
    waitForProcess ph >>= \case
        ExitSuccess -> pure ()
        code -> exitWith code

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
-- Diagnostics
-- ---------------------------------------------------------------------

die :: String -> IO a
die msg = do
    hPutStrLn stderr ("devnet-cli-smoke-host: " <> msg)
    exitFailure
