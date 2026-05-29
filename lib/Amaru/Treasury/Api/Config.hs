{- |
Module      : Amaru.Treasury.Api.Config
Description : API boundary for shared treasury config
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Adapter from shared treasury config sources into the API
server's runtime startup record.
-}
module Amaru.Treasury.Api.Config
    ( ApiRuntimeConfig (..)
    , ApiIndexerRuntimeConfig (..)
    , execApiConfig
    , parseApiArgsWithEnv
    , module Amaru.Treasury.Config
    ) where

import Cardano.Node.Client.UTxOIndexer.Types (BlockHash (..))
import Control.Applicative ((<|>))
import Data.Bifunctor (first)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word32, Word64)
import Options.Applicative
    ( Parser
    , ParserInfo
    , ParserResult (..)
    , auto
    , defaultPrefs
    , execParserPure
    , fullDesc
    , handleParseResult
    , help
    , helper
    , info
    , long
    , metavar
    , option
    , optional
    , progDesc
    , renderFailure
    , short
    , strOption
    , value
    , (<**>)
    )
import Ouroboros.Network.Magic (NetworkMagic (..))
import System.Environment
    ( getArgs
    , getEnvironment
    )
import System.Exit qualified as Exit

import Amaru.Treasury.Cli.Common (GlobalOpts (..))
import Amaru.Treasury.Config

-- | Fully resolved API startup configuration.
data ApiRuntimeConfig = ApiRuntimeConfig
    { arcHost :: !String
    , arcPort :: !Int
    , arcSocket :: !FilePath
    , arcMetadata :: !FilePath
    , arcManifest :: !FilePath
    , arcBuildIdentity :: !FilePath
    , arcStatic :: !FilePath
    , arcIndexer :: !ApiIndexerRuntimeConfig
    , arcGlobalOpts :: !GlobalOpts
    }
    deriving stock (Eq, Show)

-- | Fully resolved embedded-indexer startup configuration.
data ApiIndexerRuntimeConfig = ApiIndexerRuntimeConfig
    { aircDbPath :: !FilePath
    , aircLagThresholdSlots :: !Word64
    , aircStartPoint :: !(Maybe (Word64, BlockHash))
    }
    deriving stock (Eq, Show)

data ApiCliOpts = ApiCliOpts
    { acoConfigPath :: !(Maybe FilePath)
    , acoProfile :: !(Maybe Text)
    , acoHost :: !String
    , acoPort :: !Int
    , acoSocket :: !(Maybe FilePath)
    , acoMetadata :: !(Maybe FilePath)
    , acoManifest :: !(Maybe FilePath)
    , acoBuildIdentity :: !(Maybe FilePath)
    , acoStatic :: !(Maybe FilePath)
    , acoIndexerDb :: !(Maybe FilePath)
    , acoIndexerLagThresholdSlots :: !(Maybe Word64)
    , acoIndexerStartSlot :: !(Maybe Word64)
    , acoIndexerStartBlockHash :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

data ApiConfigError
    = ApiConfigFileError !ConfigFileError
    | ApiConfigResolveError !ResolveError
    | ApiConfigMissingRequired !Text
    | ApiConfigInvalidStartPoint !Text
    | ApiConfigNonMainnet !ResolvedNetwork
    deriving stock (Eq, Show)

-- | Parse process arguments and environment into API runtime config.
execApiConfig :: IO ApiRuntimeConfig
execApiConfig = do
    args <- getArgs
    raw <- handleParseResult (parseApiConfigArgs args)
    envs <- getEnvironment
    resolved <- resolveApiRuntimeConfig envs raw
    case resolved of
        Right runtime -> pure runtime
        Left err ->
            Exit.die $
                "amaru-treasury-tx-api: " <> renderApiConfigError err

-- | Pure-ish test helper with an injected environment.
parseApiArgsWithEnv
    :: [(String, String)]
    -> [String]
    -> IO (Either String ApiRuntimeConfig)
parseApiArgsWithEnv envs args =
    case parseApiConfigArgs args of
        Success raw ->
            first renderApiConfigError
                <$> resolveApiRuntimeConfig envs raw
        Failure failure ->
            let (body, _) = renderFailure failure "amaru-treasury-tx-api"
            in  pure (Left body)
        CompletionInvoked{} -> pure (Left "completion invoked")

parseApiConfigArgs :: [String] -> ParserResult ApiCliOpts
parseApiConfigArgs =
    execParserPure defaultPrefs apiConfigInfo

apiConfigInfo :: ParserInfo ApiCliOpts
apiConfigInfo =
    info
        (apiConfigOptsP <**> helper)
        ( fullDesc
            <> progDesc
                "Run the amaru-treasury read-only HTTP dashboard backend."
        )

apiConfigOptsP :: Parser ApiCliOpts
apiConfigOptsP =
    ApiCliOpts
        <$> optional
            ( strOption
                ( long "config"
                    <> metavar "PATH"
                    <> help "Path to treasury YAML config"
                )
            )
        <*> optional
            ( strOption
                ( long "profile"
                    <> metavar "NAME"
                    <> help "Treasury profile name"
                )
            )
        <*> strOption
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
        <*> optional
            ( strOption
                ( long "socket"
                    <> metavar "PATH"
                    <> help "Cardano N2C socket path"
                )
            )
        <*> optional
            ( strOption
                ( long "metadata"
                    <> metavar "PATH"
                    <> help "journal/2026/metadata.json (baked in)"
                )
            )
        <*> optional
            ( strOption
                ( long "manifest"
                    <> metavar "PATH"
                    <> help "recent-txs.json (baked in)"
                )
            )
        <*> optional
            ( strOption
                ( long "build-identity"
                    <> metavar "PATH"
                    <> help "build-identity.json (baked in)"
                )
            )
        <*> optional
            ( strOption
                ( long "static"
                    <> metavar "DIR"
                    <> help "Halogen bundle directory (baked in)"
                )
            )
        <*> optional
            ( strOption
                ( long "indexer-db"
                    <> metavar "PATH"
                    <> help
                        "RocksDB directory for the embedded indexer"
                )
            )
        <*> optional
            ( option
                auto
                ( long "indexer-lag-threshold-slots"
                    <> metavar "SLOTS"
                    <> help
                        "Lag-slots above which the service returns HTTP 503"
                )
            )
        <*> optional
            ( option
                auto
                ( long "indexer-start-slot"
                    <> metavar "SLOT"
                    <> help "Override the mainnet cold-boot starting slot"
                )
            )
        <*> optional
            ( T.pack
                <$> strOption
                    ( long "indexer-start-block-hash"
                        <> metavar "HASH"
                        <> help
                            "Block hash for --indexer-start-slot"
                    )
            )

resolveApiRuntimeConfig
    :: [(String, String)]
    -> ApiCliOpts
    -> IO (Either ApiConfigError ApiRuntimeConfig)
resolveApiRuntimeConfig envs opts = do
    loaded <- loadConfig selectedConfigPath
    pure $ do
        treasuryConfig <- loaded
        resolved <-
            first ApiConfigResolveError $
                resolveTreasuryConfig
                    ResolveInput
                        { riCli = cliOverrides
                        , riEnv = envOverrides
                        , riConfig = treasuryConfig
                        , riRequiredFields =
                            [RequireNodeSocket, RequireMetadataPath]
                        }
        requireMainnet resolved
        socket <- requireResolved "nodeSocket" (rtcNodeSocket resolved)
        metadata <-
            requireResolved "metadataPath" (rtcMetadataPath resolved)
        manifest <-
            requireResolved
                "api.manifest"
                ( apiPath
                    cliOverrides
                    envOverrides
                    tcoApiManifest
                    acManifest
                    treasuryConfig
                )
        buildIdentity <-
            requireResolved
                "api.buildIdentity"
                ( apiPath
                    cliOverrides
                    envOverrides
                    tcoApiBuildIdentity
                    acBuildIdentity
                    treasuryConfig
                )
        static <-
            requireResolved
                "api.static"
                ( apiPath
                    cliOverrides
                    envOverrides
                    tcoApiStatic
                    acStatic
                    treasuryConfig
                )
        indexerDb <-
            requireResolved
                "api.indexerDb"
                ( apiValue
                    cliOverrides
                    envOverrides
                    tcoApiIndexerDb
                    acIndexerDb
                    treasuryConfig
                )
        startPoint <-
            resolveIndexerStartPoint
                ( apiValue
                    cliOverrides
                    envOverrides
                    tcoApiIndexerStartSlot
                    acIndexerStartSlot
                    treasuryConfig
                )
                ( apiValue
                    cliOverrides
                    envOverrides
                    tcoApiIndexerStartBlockHash
                    acIndexerStartBlockHash
                    treasuryConfig
                )
        let indexer =
                ApiIndexerRuntimeConfig
                    { aircDbPath = indexerDb
                    , aircLagThresholdSlots =
                        fromMaybe 60 $
                            apiValue
                                cliOverrides
                                envOverrides
                                tcoApiIndexerLagThresholdSlots
                                acIndexerLagThresholdSlots
                                treasuryConfig
                    , aircStartPoint = startPoint
                    }
        pure
            ApiRuntimeConfig
                { arcHost = acoHost opts
                , arcPort = acoPort opts
                , arcSocket = socket
                , arcMetadata = metadata
                , arcManifest = manifest
                , arcBuildIdentity = buildIdentity
                , arcStatic = static
                , arcIndexer = indexer
                , arcGlobalOpts =
                    globalOptsFromResolved socket resolved
                }
  where
    envOverrides = envTreasuryConfigOverrides envs
    cliOverrides = apiCliOverrides opts
    selectedConfigPath =
        tcoConfigPath cliOverrides <|> tcoConfigPath envOverrides

loadConfig
    :: Maybe FilePath
    -> IO (Either ApiConfigError (Maybe TreasuryConfig))
loadConfig Nothing = pure (Right Nothing)
loadConfig (Just path) = do
    loaded <- readTreasuryConfigYaml path
    pure $ first ApiConfigFileError (Just <$> loaded)

apiCliOverrides :: ApiCliOpts -> TreasuryConfigOverrides
apiCliOverrides opts =
    emptyTreasuryConfigOverrides
        { tcoConfigPath = acoConfigPath opts
        , tcoProfile = acoProfile opts
        , tcoNodeSocket = acoSocket opts
        , tcoMetadataPath = acoMetadata opts
        , tcoApiManifest = acoManifest opts
        , tcoApiBuildIdentity = acoBuildIdentity opts
        , tcoApiStatic = acoStatic opts
        , tcoApiIndexerDb = acoIndexerDb opts
        , tcoApiIndexerLagThresholdSlots =
            acoIndexerLagThresholdSlots opts
        , tcoApiIndexerStartSlot = acoIndexerStartSlot opts
        , tcoApiIndexerStartBlockHash = acoIndexerStartBlockHash opts
        }

apiPath
    :: TreasuryConfigOverrides
    -> TreasuryConfigOverrides
    -> (TreasuryConfigOverrides -> Maybe FilePath)
    -> (ApiConfig -> Maybe FilePath)
    -> Maybe TreasuryConfig
    -> Maybe FilePath
apiPath = apiValue

apiValue
    :: TreasuryConfigOverrides
    -> TreasuryConfigOverrides
    -> (TreasuryConfigOverrides -> Maybe a)
    -> (ApiConfig -> Maybe a)
    -> Maybe TreasuryConfig
    -> Maybe a
apiValue cliOverrides envOverrides overrideField apiField config =
    overrideField cliOverrides
        <|> overrideField envOverrides
        <|> (config >>= apiField . tcApi)

requireResolved
    :: Text
    -> Maybe FilePath
    -> Either ApiConfigError FilePath
requireResolved name =
    maybe (Left (ApiConfigMissingRequired name)) Right

resolveIndexerStartPoint
    :: Maybe Word64
    -> Maybe Text
    -> Either ApiConfigError (Maybe (Word64, BlockHash))
resolveIndexerStartPoint Nothing Nothing = Right Nothing
resolveIndexerStartPoint (Just _) Nothing =
    Left $
        ApiConfigInvalidStartPoint
            "api.indexerStartPoint requires both indexerStartSlot and indexerStartBlockHash"
resolveIndexerStartPoint Nothing (Just _) =
    Left $
        ApiConfigInvalidStartPoint
            "api.indexerStartPoint requires both indexerStartSlot and indexerStartBlockHash"
resolveIndexerStartPoint (Just slot) (Just rawHash) = do
    blockHash <- parseIndexerStartBlockHash rawHash
    Right (Just (slot, blockHash))

parseIndexerStartBlockHash :: Text -> Either ApiConfigError BlockHash
parseIndexerStartBlockHash rawHash = do
    bytes <-
        first
            ( ApiConfigInvalidStartPoint
                . T.pack
                . ("api.indexerStartBlockHash: invalid hex: " <>)
            )
            (B16.decode (TE.encodeUtf8 rawHash))
    if BS.length bytes == 32
        then Right (BlockHash bytes)
        else
            Left $
                ApiConfigInvalidStartPoint
                    "api.indexerStartBlockHash must be 64 hex characters (32 bytes)"

requireMainnet
    :: ResolvedTreasuryConfig
    -> Either ApiConfigError ()
requireMainnet resolved
    | rnMagic network == mainnetMagic = Right ()
    | otherwise = Left (ApiConfigNonMainnet network)
  where
    network = rtcNetwork resolved

mainnetMagic :: Word32
mainnetMagic = 764_824_073

globalOptsFromResolved
    :: FilePath
    -> ResolvedTreasuryConfig
    -> GlobalOpts
globalOptsFromResolved socket resolved =
    GlobalOpts
        { goSocketPath = Just socket
        , goNetworkMagic = NetworkMagic (rnMagic (rtcNetwork resolved))
        , goNetworkName = rnName (rtcNetwork resolved)
        }

renderApiConfigError :: ApiConfigError -> String
renderApiConfigError = \case
    ApiConfigFileError (ConfigFileReadError path err) ->
        "config: " <> path <> ": " <> err
    ApiConfigFileError (ConfigFileDecodeError path err) ->
        "config: " <> path <> ": " <> err
    ApiConfigResolveError (UnknownProfile name) ->
        "config: unknown profile " <> T.unpack name
    ApiConfigResolveError (MissingConfigForProfile name) ->
        "config: profile "
            <> T.unpack name
            <> " requires --config or AMARU_TREASURY_CONFIG"
    ApiConfigResolveError (MissingRequiredField field) ->
        "config: missing required field " <> T.unpack field
    ApiConfigResolveError (InvalidNetwork name) ->
        "config: unknown network "
            <> T.unpack name
            <> " (expected mainnet|preprod|preview|devnet)"
    ApiConfigMissingRequired field ->
        "config: missing required field " <> T.unpack field
    ApiConfigInvalidStartPoint err ->
        T.unpack err
    ApiConfigNonMainnet network ->
        "api: expected mainnet network, got "
            <> networkDescription network

networkDescription :: ResolvedNetwork -> String
networkDescription network =
    case rnName network of
        Just name ->
            T.unpack name <> " (" <> show (rnMagic network) <> ")"
        Nothing -> show (rnMagic network)
