{- |
Module      : Amaru.Treasury.Cli.Config
Description : CLI boundary for shared treasury config
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Adapter from the shared config resolver into the CLI's
legacy runtime option records.
-}
module Amaru.Treasury.Cli.Config
    ( CliConfigError (..)
    , renderCliConfigError
    , resolveGlobalConfig
    , resolveTreasuryInspectConfig
    ) where

import Control.Applicative ((<|>))
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import Ouroboros.Network.Magic (NetworkMagic (..))

import Amaru.Treasury.Cli.Common
    ( GlobalConfigOpts (..)
    , GlobalNetworkArg (..)
    , GlobalOpts (..)
    )
import Amaru.Treasury.Cli.TreasuryInspect
    ( InspectOpts (..)
    )
import Amaru.Treasury.Config.File
    ( ConfigFileError (..)
    , readTreasuryConfigYaml
    )
import Amaru.Treasury.Config.Resolve
    ( RequiredField (..)
    , ResolveError (..)
    , ResolveInput (..)
    , envTreasuryConfigOverrides
    , resolveTreasuryConfig
    )
import Amaru.Treasury.Config.Types
    ( ResolvedNetwork (..)
    , ResolvedTreasuryConfig (..)
    , TreasuryConfig
    , TreasuryConfigOverrides (..)
    , emptyTreasuryConfigOverrides
    )
import Amaru.Treasury.Scope
    ( ScopeId
    , scopeFromText
    , scopeText
    )

-- | CLI config resolution failure.
data CliConfigError
    = CliConfigFileError !ConfigFileError
    | CliConfigResolveError !ResolveError
    | CliConfigInvalidScope !Text !String
    deriving stock (Eq, Show)

-- | Render a CLI-facing config diagnostic.
renderCliConfigError :: CliConfigError -> String
renderCliConfigError = \case
    CliConfigFileError (ConfigFileReadError path err) ->
        "config: " <> path <> ": " <> err
    CliConfigFileError (ConfigFileDecodeError path err) ->
        "config: " <> path <> ": " <> err
    CliConfigResolveError (UnknownProfile name) ->
        "config: unknown profile " <> T.unpack name
    CliConfigResolveError (MissingConfigForProfile name) ->
        "config: profile "
            <> T.unpack name
            <> " requires --config or AMARU_TREASURY_CONFIG"
    CliConfigResolveError (MissingRequiredField field) ->
        "config: missing required field " <> T.unpack field
    CliConfigResolveError (InvalidNetwork name) ->
        "config: unknown network "
            <> T.unpack name
            <> " (expected mainnet|preprod|preview|devnet)"
    CliConfigInvalidScope raw err ->
        "config: defaultScope "
            <> T.unpack raw
            <> ": "
            <> err

-- | Resolve global config for commands without command-specific defaults.
resolveGlobalConfig
    :: [(String, String)]
    -> GlobalConfigOpts
    -> IO (Either CliConfigError GlobalOpts)
resolveGlobalConfig envs globals =
    fmap globalOptsFromResolved
        <$> resolveRuntimeConfig envs globals id []

-- | Resolve global and @treasury-inspect@ command config together.
resolveTreasuryInspectConfig
    :: [(String, String)]
    -> GlobalConfigOpts
    -> InspectOpts
    -> IO (Either CliConfigError (GlobalOpts, InspectOpts))
resolveTreasuryInspectConfig envs globals inspect = do
    resolved <-
        resolveRuntimeConfig
            envs
            globals
            (addInspectOverrides inspect)
            [RequireNodeSocket, RequireMetadataPath]
    pure $ do
        runtime <- resolved
        resolvedInspect <- fillInspectOpts runtime inspect
        pure (globalOptsFromResolved runtime, resolvedInspect)

resolveRuntimeConfig
    :: [(String, String)]
    -> GlobalConfigOpts
    -> (TreasuryConfigOverrides -> TreasuryConfigOverrides)
    -> [RequiredField]
    -> IO (Either CliConfigError ResolvedTreasuryConfig)
resolveRuntimeConfig envs globals adjustCli requiredFields = do
    config <- loadConfig selectedConfigPath
    pure $ do
        treasuryConfig <- config
        first CliConfigResolveError $
            resolveTreasuryConfig
                ResolveInput
                    { riCli = cliOverrides
                    , riEnv = envOverrides
                    , riConfig = treasuryConfig
                    , riRequiredFields = requiredFields
                    }
  where
    envOverrides = envTreasuryConfigOverrides envs
    cliOverrides = adjustCli (globalOverrides globals)
    selectedConfigPath =
        tcoConfigPath cliOverrides <|> tcoConfigPath envOverrides

loadConfig
    :: Maybe FilePath
    -> IO (Either CliConfigError (Maybe TreasuryConfig))
loadConfig Nothing = pure (Right Nothing)
loadConfig (Just path) = do
    loaded <- readTreasuryConfigYaml path
    pure $ first CliConfigFileError (Just <$> loaded)

globalOverrides :: GlobalConfigOpts -> TreasuryConfigOverrides
globalOverrides globals =
    emptyTreasuryConfigOverrides
        { tcoConfigPath = gcoConfigPath globals
        , tcoProfile = gcoProfile globals
        , tcoNodeSocket = gcoSocketPath globals
        , tcoNetwork = networkNameArg (gcoNetwork globals)
        , tcoNetworkMagic = networkMagicArg (gcoNetwork globals)
        }

networkNameArg :: Maybe GlobalNetworkArg -> Maybe Text
networkNameArg = \case
    Just (GlobalNetworkByName name _) -> Just name
    _ -> Nothing

networkMagicArg :: Maybe GlobalNetworkArg -> Maybe Word32
networkMagicArg = \case
    Just (GlobalNetworkByMagic magic) -> Just (fromIntegral magic)
    _ -> Nothing

addInspectOverrides
    :: InspectOpts
    -> TreasuryConfigOverrides
    -> TreasuryConfigOverrides
addInspectOverrides inspect overrides =
    overrides
        { tcoMetadataPath = ioMetadata inspect
        , tcoDefaultScope = scopeText <$> ioScope inspect
        , tcoSwapOrderAddress = ioSwapOrderAddress inspect
        }

globalOptsFromResolved :: ResolvedTreasuryConfig -> GlobalOpts
globalOptsFromResolved resolved =
    GlobalOpts
        { goSocketPath = rtcNodeSocket resolved
        , goNetworkMagic = NetworkMagic (rnMagic (rtcNetwork resolved))
        , goNetworkName = rnName (rtcNetwork resolved)
        }

fillInspectOpts
    :: ResolvedTreasuryConfig
    -> InspectOpts
    -> Either CliConfigError InspectOpts
fillInspectOpts resolved inspect = do
    resolvedScope <-
        resolveScope (ioScope inspect) (rtcDefaultScope resolved)
    pure
        inspect
            { ioMetadata = ioMetadata inspect <|> rtcMetadataPath resolved
            , ioScope = resolvedScope
            , ioSwapOrderAddress =
                ioSwapOrderAddress inspect <|> rtcSwapOrderAddress resolved
            }

resolveScope
    :: Maybe ScopeId
    -> Maybe Text
    -> Either CliConfigError (Maybe ScopeId)
resolveScope (Just scope) _ = Right (Just scope)
resolveScope Nothing Nothing = Right Nothing
resolveScope Nothing (Just raw) =
    first (CliConfigInvalidScope raw) (Just <$> scopeFromText raw)
