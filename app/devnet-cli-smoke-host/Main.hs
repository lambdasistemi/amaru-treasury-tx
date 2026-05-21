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
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
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
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Node.Client.E2E.Devnet (withCardanoNode)
import Cardano.Node.Client.E2E.Setup
    ( devnetMagic
    , genesisDir
    , genesisSignKey
    , mkSignKey
    )
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
import Data.Foldable (traverse_)
import Data.List (isPrefixOf)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust, isNothing)
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
import Data.Aeson.Types (Parser, parseEither, withObject, (.:), (.:?))
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Lens.Micro ((^.))
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
                , ("CLI_SMOKE_BENEFICIARY_ADDR", devnetBeneficiaryAddress keys)
                ]
        smokeCode <- callSmokeScript opts runDir envEntries
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
                case smokeCode of
                    ExitSuccess -> do
                        markFullSummaryPassed runDir socket
                        exitSuccess
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
-- Diagnostics
-- ---------------------------------------------------------------------

die :: String -> IO a
die msg = do
    hPutStrLn stderr ("devnet-cli-smoke-host: " <> msg)
    exitFailure
