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
    , execApiConfig
    , parseApiArgsWithEnv
    , module Amaru.Treasury.Config
    ) where

import Control.Applicative ((<|>))
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
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
    , arcGlobalOpts :: !GlobalOpts
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
    }
    deriving stock (Eq, Show)

data ApiConfigError
    = ApiConfigFileError !ConfigFileError
    | ApiConfigResolveError !ResolveError
    | ApiConfigMissingRequired !Text
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
        pure
            ApiRuntimeConfig
                { arcHost = acoHost opts
                , arcPort = acoPort opts
                , arcSocket = socket
                , arcMetadata = metadata
                , arcManifest = manifest
                , arcBuildIdentity = buildIdentity
                , arcStatic = static
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
        }

apiPath
    :: TreasuryConfigOverrides
    -> TreasuryConfigOverrides
    -> (TreasuryConfigOverrides -> Maybe FilePath)
    -> (ApiConfig -> Maybe FilePath)
    -> Maybe TreasuryConfig
    -> Maybe FilePath
apiPath cliOverrides envOverrides overrideField apiField config =
    overrideField cliOverrides
        <|> overrideField envOverrides
        <|> (config >>= apiField . tcApi)

requireResolved
    :: Text
    -> Maybe FilePath
    -> Either ApiConfigError FilePath
requireResolved name =
    maybe (Left (ApiConfigMissingRequired name)) Right

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
    ApiConfigNonMainnet network ->
        "api: expected mainnet network, got "
            <> networkDescription network

networkDescription :: ResolvedNetwork -> String
networkDescription network =
    case rnName network of
        Just name ->
            T.unpack name <> " (" <> show (rnMagic network) <> ")"
        Nothing -> show (rnMagic network)
