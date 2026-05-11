{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Devnet.SmokeSpec
Description : Opt-in local cardano-node-clients devnet smoke
License     : Apache-2.0

This suite is intentionally not part of @just ci@. It starts a real
local @cardano-node@ through @cardano-node-clients:devnet@ and records
release-evidence artifacts for manual verification.
-}
module Amaru.Treasury.Devnet.SmokeSpec (spec) where

import Control.Monad (unless, when)
import Data.Aeson
    ( FromJSON (..)
    , Value
    , eitherDecodeFileStrict
    , encode
    , object
    , withObject
    , (.:)
    , (.=)
    )
import Data.ByteString.Lazy qualified as BSL
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import System.Directory
    ( copyFile
    , createDirectoryIfMissing
    , doesDirectoryExist
    , doesFileExist
    , getCurrentDirectory
    , listDirectory
    , makeAbsolute
    )
import System.Environment (lookupEnv)
import System.FilePath
    ( takeDirectory
    , (</>)
    )
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    , shouldSatisfy
    )

import Cardano.Node.Client.E2E.Devnet
    ( withCardanoNode
    )
import Cardano.Node.Client.E2E.Setup
    ( devnetMagic
    , genesisDir
    )

import Amaru.Treasury.Backend.N2C
    ( probeNetworkMagic
    )

data ShelleyGenesisTiming = ShelleyGenesisTiming
    { sgtEpochLength :: !Int
    , sgtNetworkMagic :: !Int
    , sgtSlotLength :: !Double
    }
    deriving stock (Eq, Show)

instance FromJSON ShelleyGenesisTiming where
    parseJSON =
        withObject "ShelleyGenesisTiming" $ \o ->
            ShelleyGenesisTiming
                <$> o .: "epochLength"
                <*> o .: "networkMagic"
                <*> o .: "slotLength"

spec :: Spec
spec =
    describe "local devnet node smoke" $
        it
            "starts cardano-node-clients devnet and records short-epoch timing evidence"
            nodeSmoke

nodeSmoke :: IO ()
nodeSmoke = do
    phase <- lookupEnv "DEVNET_SMOKE_PHASE"
    when (maybe False (/= "node") phase) $
        expectationFailure "devnet smoke MVP only supports phase=node"

    runDir <- resolveRunDir
    prepareRunDir runDir

    gDir <- genesisDir
    assertGenesisDir gDir
    timing <- readShelleyTiming gDir
    let epochDuration = epochDurationSeconds timing
    sgtNetworkMagic timing `shouldBe` 42
    epochDuration `shouldSatisfy` (<= 60)

    withCardanoNode gDir $ \socket startMs -> do
        accepted <- probeNetworkMagic devnetMagic socket
        accepted `shouldBe` True

        copyNodeLog socket runDir
        writeTiming runDir startMs socket timing
        writeSummary runDir socket timing "passed"
        putSummaryLines runDir socket timing "passed"

resolveRunDir :: IO FilePath
resolveRunDir = do
    explicit <- lookupEnv "DEVNET_SMOKE_RUN_DIR"
    case explicit of
        Just p -> makeAbsolute p
        Nothing -> do
            cwd <- getCurrentDirectory
            stamp <- utcStamp
            pure (cwd </> "dist-newstyle" </> "devnet-smoke" </> stamp)

prepareRunDir :: FilePath -> IO ()
prepareRunDir runDir = do
    exists <- doesDirectoryExist runDir
    contents <-
        if exists
            then listDirectory runDir
            else pure []
    unless (null contents) $
        expectationFailure
            ( "devnet smoke run directory is not empty: "
                <> runDir
            )
    createDirectoryIfMissing True runDir
    createDirectoryIfMissing True (runDir </> "withdraw")
    createDirectoryIfMissing True (runDir </> "disburse")

assertGenesisDir :: FilePath -> IO ()
assertGenesisDir gDir = do
    present <- doesFileExist (gDir </> "shelley-genesis.json")
    unless present $
        expectationFailure
            ( "E2E_GENESIS_DIR does not point at cardano-node-clients genesis: "
                <> gDir
            )

readShelleyTiming :: FilePath -> IO ShelleyGenesisTiming
readShelleyTiming gDir = do
    decoded <-
        eitherDecodeFileStrict
            (gDir </> "shelley-genesis.json")
    case decoded of
        Left err ->
            expectationFailure
                ( "decode shelley-genesis.json: "
                    <> err
                )
                *> error "unreachable"
        Right timing -> pure timing

epochDurationSeconds :: ShelleyGenesisTiming -> Double
epochDurationSeconds timing =
    fromIntegral (sgtEpochLength timing) * sgtSlotLength timing

copyNodeLog :: FilePath -> FilePath -> IO ()
copyNodeLog socket runDir = do
    let source = takeDirectory socket </> "node.log"
        target = runDir </> "node.log"
    exists <- doesFileExist source
    when exists (copyFile source target)

writeTiming
    :: FilePath
    -> Integer
    -> FilePath
    -> ShelleyGenesisTiming
    -> IO ()
writeTiming runDir startMs socket timing =
    BSL.writeFile
        (runDir </> "timing.json")
        ( encode
            ( timingValue
                startMs
                socket
                timing
            )
        )

writeSummary
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> String
    -> IO ()
writeSummary runDir socket timing status =
    BSL.writeFile
        (runDir </> "summary.json")
        ( encode
            ( object
                [ "phase" .= ("node" :: String)
                , "status" .= status
                , "socket" .= socket
                , "network" .= ("devnet" :: String)
                , "networkMagic" .= sgtNetworkMagic timing
                , "epochDurationSeconds"
                    .= epochDurationSeconds timing
                ]
            )
        )

timingValue
    :: Integer
    -> FilePath
    -> ShelleyGenesisTiming
    -> Value
timingValue startMs socket timing =
    object
        [ "network" .= ("devnet" :: String)
        , "networkMagic" .= sgtNetworkMagic timing
        , "epochLength" .= sgtEpochLength timing
        , "slotLengthSeconds" .= sgtSlotLength timing
        , "epochDurationSeconds" .= epochDurationSeconds timing
        , "systemStartMs" .= startMs
        , "socket" .= socket
        ]

putSummaryLines
    :: FilePath
    -> FilePath
    -> ShelleyGenesisTiming
    -> String
    -> IO ()
putSummaryLines runDir socket timing status = do
    let linesOut =
            [ "devnet-smoke: run-dir " <> runDir
            , "devnet-smoke: network devnet magic "
                <> show (sgtNetworkMagic timing)
            , "devnet-smoke: epoch-duration "
                <> show (epochDurationSeconds timing)
            , "devnet-smoke: socket " <> socket
            , "devnet-smoke: phase node " <> status
            ]
    writeFile (runDir </> "summary.log") (unlines linesOut)
    mapM_ putStrLn linesOut

utcStamp :: IO FilePath
utcStamp =
    formatTime defaultTimeLocale "%Y%m%dT%H%M%SZ"
        <$> getCurrentTime
