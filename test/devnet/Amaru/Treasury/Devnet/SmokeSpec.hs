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
import Data.List (intercalate)
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
    describe "local devnet smoke" $ do
        it
            "node: starts cardano-node-clients devnet and records short-epoch timing evidence"
            (runForPhases ["node", "all"] nodeSmoke)
        it
            "governance: fails with a typed upstream-support blocker"
            (runForPhases ["governance", "all"] governanceSmoke)

runForPhases :: [String] -> IO () -> IO ()
runForPhases accepted action = do
    phase <- maybe "node" id <$> lookupEnv "DEVNET_SMOKE_PHASE"
    when (phase `elem` accepted) action

governanceSmoke :: IO ()
governanceSmoke = do
    runDir <- resolveRunDir
    prepareRunDir runDir
    createDirectoryIfMissing True (runDir </> "governance")

    let blocker =
            object
                [ "phase" .= ("governance" :: String)
                , "status" .= ("blocked" :: String)
                , "failureCode"
                    .= ( "MISSING_UPSTREAM_GOVERNANCE_SUPPORT"
                            :: String
                       )
                , "runDirectory" .= runDir
                , "upstream"
                    .= [ object
                            [ "repository"
                                .= ( "lambdasistemi/cardano-node-clients"
                                        :: String
                                   )
                            , "issue" .= (130 :: Int)
                            , "url"
                                .= ( "https://github.com/lambdasistemi/cardano-node-clients/issues/130"
                                        :: String
                                   )
                            , "capability"
                                .= ( "Conway stake certificates and treasury-withdrawal proposal support"
                                        :: String
                                   )
                            ]
                       , object
                            [ "repository"
                                .= ( "lambdasistemi/cardano-node-clients"
                                        :: String
                                   )
                            , "issue" .= (131 :: Int)
                            , "url"
                                .= ( "https://github.com/lambdasistemi/cardano-node-clients/issues/131"
                                        :: String
                                   )
                            , "capability"
                                .= ( "Governance action and reward-account state queries"
                                        :: String
                                   )
                            ]
                       ]
                ]

    BSL.writeFile
        (runDir </> "governance" </> "summary.json")
        (encode blocker)
    writeFile
        (runDir </> "summary.log")
        ( unlines
            [ "devnet-smoke: run-dir " <> runDir
            , "devnet-smoke: phase governance blocked"
            , "devnet-smoke: failure MISSING_UPSTREAM_GOVERNANCE_SUPPORT"
            , "devnet-smoke: upstream lambdasistemi/cardano-node-clients#130"
            , "devnet-smoke: upstream lambdasistemi/cardano-node-clients#131"
            ]
        )
    expectationFailure
        ( intercalate
            "\n"
            [ "MISSING_UPSTREAM_GOVERNANCE_SUPPORT: cardano-node-clients lacks the required governance setup capabilities"
            , "run directory: " <> runDir
            , "blocked by lambdasistemi/cardano-node-clients#130"
            , "blocked by lambdasistemi/cardano-node-clients#131"
            ]
        )

nodeSmoke :: IO ()
nodeSmoke = do
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
