{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Main
Description : HTTP entry point for the #239 dashboard
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Thin binary that:

  * parses a small CLI surface (@--bind@, @--socket@,
    @--metadata@, @--manifest@, @--build-identity@,
    @--static@);
  * loads the three read-only JSON artefacts the image bakes
    in;
  * opens a single N2C session against the cardano mainnet
    node and reuses it across every HTTP request;
  * runs the servant 'mkApplication' from
    'Amaru.Treasury.Api.Server' on warp at the requested bind
    address.

Refuses to start against any non-mainnet network magic
(FR-025).
-}
module Main (main) where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as LBS
import Data.Streaming.Network (HostPreference)
import Data.String (IsString (..))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word16)
import Network.Wai.Handler.Warp
    ( defaultSettings
    , runSettings
    , setHost
    , setPort
    )
import Options.Applicative
    ( Parser
    , auto
    , execParser
    , fullDesc
    , help
    , helper
    , info
    , long
    , metavar
    , option
    , progDesc
    , short
    , strOption
    , value
    , (<**>)
    )
import Servant.Server.StaticFiles (serveDirectoryFileServer)
import System.Exit (die)

import Ouroboros.Network.Magic (NetworkMagic (..))

import Amaru.Treasury.Api.Server
    ( Handlers (..)
    , mkApplication
    )
import Amaru.Treasury.Api.Types
    ( BuildIdentity
    , RecentTxManifest
    )
import Amaru.Treasury.Backend.N2C (withLocalNodeBackend)
import Amaru.Treasury.Cli.TreasuryInspect
    ( runInspectFromBackend
    )
import Amaru.Treasury.Constants
    ( sundaeOrderAddressMainnet
    )
import Amaru.Treasury.Inspect.Types
    ( DeploymentAnchor (..)
    , Outref (..)
    )
import Amaru.Treasury.IntentJSON.Common (parseAddr)
import Amaru.Treasury.Metadata
    ( TreasuryMetadata (..)
    , readMetadataFile
    )

-- ---------------------------------------------------------------------------
-- CLI

data Opts = Opts
    { optsHost :: String
    , optsPort :: Int
    , optsSocket :: FilePath
    , optsMetadata :: FilePath
    , optsManifest :: FilePath
    , optsBuildIdentity :: FilePath
    , optsStatic :: FilePath
    }
    deriving (Show)

optsP :: Parser Opts
optsP =
    Opts
        <$> strOption
            ( long "host"
                <> metavar "ADDR"
                <> help "Bind host (default 0.0.0.0)"
                <> value "0.0.0.0"
            )
        <*> option
            auto
            ( long "port"
                <> short 'p'
                <> metavar "PORT"
                <> help "TCP port (default 8080)"
                <> value 8080
            )
        <*> strOption
            ( long "socket"
                <> metavar "PATH"
                <> help "Cardano N2C socket path"
            )
        <*> strOption
            ( long "metadata"
                <> metavar "PATH"
                <> help "journal/2026/metadata.json (baked in)"
            )
        <*> strOption
            ( long "manifest"
                <> metavar "PATH"
                <> help "recent-txs.json (baked in)"
            )
        <*> strOption
            ( long "build-identity"
                <> metavar "PATH"
                <> help "build-identity.json (baked in)"
            )
        <*> strOption
            ( long "static"
                <> metavar "DIR"
                <> help "Halogen bundle directory (baked in)"
            )

-- ---------------------------------------------------------------------------
-- Main

mainnetMagic :: NetworkMagic
mainnetMagic = NetworkMagic 764824073

main :: IO ()
main = do
    opts <-
        execParser $
            info
                (optsP <**> helper)
                ( fullDesc
                    <> progDesc
                        "Run the amaru-treasury read-only \
                        \HTTP dashboard backend."
                )

    metadata <- readMetadataFile (optsMetadata opts)
    anchor <- parseAnchorOrDie (tmScopeOwners metadata)
    swapAddr <- case parseAddr sundaeOrderAddressMainnet of
        Right a -> pure a
        Left e ->
            die $
                "amaru-treasury-tx-api: built-in \
                \sundaeOrderAddressMainnet failed to \
                \parse: " <> e

    manifest <- readJsonOrDie (optsManifest opts) :: IO RecentTxManifest
    buildId <- readJsonOrDie (optsBuildIdentity opts) :: IO BuildIdentity

    let host :: HostPreference
        host = fromString (optsHost opts)
        warpSettings =
            setHost host
                . setPort (optsPort opts)
                $ defaultSettings

    putStrLn $
        "amaru-treasury-tx-api: opening N2C session on "
            <> optsSocket opts
    withLocalNodeBackend mainnetMagic (optsSocket opts) $
        \backend -> do
            let handlers =
                    Handlers
                        { hInspectReport = \scope ->
                            runInspectFromBackend
                                metadata
                                anchor
                                swapAddr
                                (Just scope)
                                backend
                        , hRecentTxs = manifest
                        , hBuildIdentity = buildId
                        , hRawHandler =
                            serveDirectoryFileServer
                                (optsStatic opts)
                        }
            putStrLn $
                "amaru-treasury-tx-api: listening on "
                    <> optsHost opts
                    <> ":"
                    <> show (optsPort opts)
            runSettings warpSettings (mkApplication handlers)

readJsonOrDie :: (Aeson.FromJSON a) => FilePath -> IO a
readJsonOrDie path = do
    bytes <- LBS.readFile path
    case Aeson.eitherDecode bytes of
        Right v -> pure v
        Left e ->
            die $
                "amaru-treasury-tx-api: failed to decode "
                    <> path
                    <> ": "
                    <> e

parseAnchorOrDie :: Text -> IO DeploymentAnchor
parseAnchorOrDie raw =
    case T.splitOn "#" raw of
        [txid, ix] ->
            case reads (T.unpack ix) :: [(Word16, String)] of
                [(n, "")] ->
                    pure
                        ( DeploymentAnchor
                            Outref
                                { orTxId = txid
                                , orIx = n
                                }
                        )
                _ ->
                    die $
                        "amaru-treasury-tx-api: \
                        \metadata.scope_owners ix not \
                        \numeric: " <> T.unpack raw
        _ ->
            die $
                "amaru-treasury-tx-api: \
                \metadata.scope_owners not txid#ix: "
                    <> T.unpack raw

