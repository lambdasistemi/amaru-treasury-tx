{- |
Module      : Amaru.Treasury.Config.Resolve
Description : Pure treasury config precedence resolution
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pure helpers for merging CLI, environment, YAML profile,
and default values into a runtime treasury config.
-}
module Amaru.Treasury.Config.Resolve
    ( RequiredField (..)
    , ResolveError (..)
    , ResolveInput (..)
    , envTreasuryConfigOverrides
    , resolveTreasuryConfig
    ) where

import Control.Applicative ((<|>))
import Data.List (find)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import Text.Read (readMaybe)

import Amaru.Treasury.Config.Types
    ( ResolvedNetwork (..)
    , ResolvedTreasuryConfig (..)
    , TreasuryConfig (..)
    , TreasuryConfigOverrides (..)
    , TreasuryProfileConfig (..)
    , emptyTreasuryConfigOverrides
    )

-- | Fields a caller requires before starting command IO.
data RequiredField
    = RequireNodeSocket
    | RequireMetadataPath
    | RequireDefaultScope
    | RequireWalletAddress
    | RequireSwapOrderAddress
    deriving stock (Eq, Show)

-- | Pure resolution failure.
data ResolveError
    = UnknownProfile !Text
    | MissingConfigForProfile !Text
    | MissingRequiredField !Text
    | InvalidNetwork !Text
    deriving stock (Eq, Show)

-- | All source tiers consumed by the resolver.
data ResolveInput = ResolveInput
    { riCli :: !TreasuryConfigOverrides
    , riEnv :: !TreasuryConfigOverrides
    , riConfig :: !(Maybe TreasuryConfig)
    , riRequiredFields :: ![RequiredField]
    }
    deriving stock (Eq, Show)

-- | Build environment overrides from process environment key/value pairs.
envTreasuryConfigOverrides
    :: [(String, String)]
    -> TreasuryConfigOverrides
envTreasuryConfigOverrides envs =
    emptyTreasuryConfigOverrides
        { tcoConfigPath = lookupString "AMARU_TREASURY_CONFIG"
        , tcoProfile = lookupText "AMARU_TREASURY_PROFILE"
        , tcoNetwork = lookupText "AMARU_TREASURY_NETWORK"
        , tcoNetworkMagic =
            lookupString "AMARU_TREASURY_NETWORK_MAGIC" >>= readMaybe
        , tcoNodeSocket =
            lookupString "AMARU_TREASURY_NODE_SOCKET"
                <|> lookupString "CARDANO_NODE_SOCKET_PATH"
        , tcoMetadataPath = lookupString "AMARU_TREASURY_METADATA"
        , tcoDefaultScope = lookupText "AMARU_TREASURY_DEFAULT_SCOPE"
        , tcoTenantId = lookupText "AMARU_TREASURY_TENANT_ID"
        , tcoWalletAddress = lookupText "AMARU_TREASURY_WALLET_ADDRESS"
        , tcoSwapOrderAddress =
            lookupText "AMARU_TREASURY_SWAP_ORDER_ADDRESS"
        , tcoApiManifest =
            lookupString "AMARU_TREASURY_API_MANIFEST"
        , tcoApiBuildIdentity =
            lookupString "AMARU_TREASURY_API_BUILD_IDENTITY"
        , tcoApiStatic =
            lookupString "AMARU_TREASURY_API_STATIC"
        }
  where
    lookupString key = lookup key envs
    lookupText key = T.pack <$> lookupString key

-- | Resolve treasury config using CLI > env > profile > default precedence.
resolveTreasuryConfig
    :: ResolveInput
    -> Either ResolveError ResolvedTreasuryConfig
resolveTreasuryConfig input = do
    profile <- selectedProfile input selectedProfileName
    network <- resolveNetwork input profile
    let resolved =
            ResolvedTreasuryConfig
                { rtcProfileName = selectedProfileName
                , rtcNetwork = network
                , rtcNodeSocket = choose profile tcoNodeSocket tpcNodeSocket
                , rtcMetadataPath =
                    choose profile tcoMetadataPath tpcMetadataPath
                , rtcDefaultScope =
                    choose profile tcoDefaultScope tpcDefaultScope
                , rtcTenantId =
                    choose profile tcoTenantId tpcTenantId
                , rtcWalletAddress =
                    choose profile tcoWalletAddress tpcWalletAddress
                , rtcSwapOrderAddress =
                    choose profile tcoSwapOrderAddress tpcSwapOrderAddress
                }
    checkRequiredFields (riRequiredFields input) resolved
    pure resolved
  where
    selectedProfileName =
        tcoProfile (riCli input) <|> tcoProfile (riEnv input)

    choose
        :: Maybe TreasuryProfileConfig
        -> (TreasuryConfigOverrides -> Maybe a)
        -> (TreasuryProfileConfig -> Maybe a)
        -> Maybe a
    choose profile overrideField profileField =
        overrideField (riCli input)
            <|> overrideField (riEnv input)
            <|> (profile >>= profileField)

selectedProfile
    :: ResolveInput
    -> Maybe Text
    -> Either ResolveError (Maybe TreasuryProfileConfig)
selectedProfile _ Nothing = Right Nothing
selectedProfile input (Just name) =
    case riConfig input of
        Nothing -> Left (MissingConfigForProfile name)
        Just config ->
            case Map.lookup name (tcProfiles config) of
                Nothing -> Left (UnknownProfile name)
                Just profile -> Right (Just profile)

resolveNetwork
    :: ResolveInput
    -> Maybe TreasuryProfileConfig
    -> Either ResolveError ResolvedNetwork
resolveNetwork input profile =
    case mName of
        Just name -> do
            namedMagic <- networkMagicFromName name
            pure
                ResolvedNetwork
                    { rnName = Just name
                    , rnMagic = namedMagic
                    }
        Nothing ->
            pure
                ResolvedNetwork
                    { rnName = networkNameFromMagic magic
                    , rnMagic = magic
                    }
  where
    mName =
        tcoNetwork (riCli input)
            <|> tcoNetwork (riEnv input)
            <|> (profile >>= tpcNetwork)
    magic =
        fromMaybe mainnetMagic $
            tcoNetworkMagic (riCli input)
                <|> tcoNetworkMagic (riEnv input)
                <|> (profile >>= tpcNetworkMagic)

networkMagicFromName :: Text -> Either ResolveError Word32
networkMagicFromName name =
    case lookup name knownNetworks of
        Just magic -> Right magic
        Nothing -> Left (InvalidNetwork name)

networkNameFromMagic :: Word32 -> Maybe Text
networkNameFromMagic magic =
    fst <$> find ((== magic) . snd) knownNetworks

knownNetworks :: [(Text, Word32)]
knownNetworks =
    [ ("mainnet", mainnetMagic)
    , ("preprod", 1)
    , ("preview", 2)
    , ("devnet", 42)
    ]

mainnetMagic :: Word32
mainnetMagic = 764_824_073

checkRequiredFields
    :: [RequiredField]
    -> ResolvedTreasuryConfig
    -> Either ResolveError ()
checkRequiredFields fields resolved =
    case filter (missingRequiredField resolved) fields of
        [] -> Right ()
        field : _ -> Left (MissingRequiredField (requiredFieldName field))

missingRequiredField
    :: ResolvedTreasuryConfig
    -> RequiredField
    -> Bool
missingRequiredField resolved = \case
    RequireNodeSocket -> isMissing (rtcNodeSocket resolved)
    RequireMetadataPath -> isMissing (rtcMetadataPath resolved)
    RequireDefaultScope -> isMissing (rtcDefaultScope resolved)
    RequireWalletAddress -> isMissing (rtcWalletAddress resolved)
    RequireSwapOrderAddress -> isMissing (rtcSwapOrderAddress resolved)

requiredFieldName :: RequiredField -> Text
requiredFieldName = \case
    RequireNodeSocket -> "nodeSocket"
    RequireMetadataPath -> "metadataPath"
    RequireDefaultScope -> "defaultScope"
    RequireWalletAddress -> "walletAddress"
    RequireSwapOrderAddress -> "swapOrderAddress"

isMissing :: Maybe a -> Bool
isMissing Nothing = True
isMissing (Just _) = False
