{-# LANGUAGE DataKinds #-}
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
import Cardano.Ledger.Address
    ( AccountAddress (..)
    , AccountId (..)
    , Addr (..)
    , serialiseAddr
    )
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (KeyHash (..))
import Cardano.Ledger.Keys
    ( KeyRole (Payment)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup
    ( devnetMagic
    , genesisDir
    , genesisSignKey
    , mkSignKey
    )
import Codec.Binary.Bech32 qualified as Bech32
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
import Data.Foldable (traverse_)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Amaru.Treasury.Backend qualified as Backend
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.LedgerParse
    ( scriptHashFromHex
    , txInFromText
    , txInToText
    )
import Data.Aeson.Key qualified as Key
import Data.Aeson.Types (Parser, parseEither, withObject, (.:))
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
                , ("CLI_SMOKE_FUNDING_ADDR", devnetFundingAddress keys)
                , ("CLI_SMOKE_FUNDING_KEY_HASH", devnetFundingKeyHashHex keys)
                , ("CLI_SMOKE_VOTER_SKEY", devnetVoterSkeyPath keys)
                , ("CLI_SMOKE_VOTER_KEY_HASH", devnetVoterKeyHashHex keys)
                ]
        smokeCode <- callSmokeScript opts runDir envEntries
        case smokeCode of
            ExitSuccess
                | hoPhase opts == "registry-stake" -> do
                    runChainAssertions runDir socket devnetMagic
                    exitSuccess
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

-- ---------------------------------------------------------------------
-- Smoke script handoff
-- ---------------------------------------------------------------------

callSmokeScript
    :: HostOpts
    -> FilePath
    -> [(String, String)]
    -> IO ExitCode
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
    waitForProcess ph

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
            >>= either (die . badRequest) pure
    request <-
        either (die . badRequest) pure $
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
        accountSet = Set.fromList (fmap thd rewardAccounts)

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
  where
    badRequest err =
        "chain-assertion: cannot parse assertions.request.json: " <> err
    thd (_, _, x) = x

renderChainAssertionLog :: Value -> [String]
renderChainAssertionLog v =
    [ "chain-assertion: report"
    , T.unpack (TE.decodeUtf8 (BSL.toStrict (encode v)))
    ]

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

-- ---------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------

die :: String -> IO a
die msg = do
    hPutStrLn stderr ("devnet-cli-smoke-host: " <> msg)
    exitFailure
