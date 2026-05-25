{- |
Module      : Amaru.Treasury.Config.File
Description : YAML treasury config decoding
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

YAML file loading for treasury profile config. The rest of
the runtime config stack consumes the typed 'TreasuryConfig'
value and does not depend on the YAML parser directly.
-}
module Amaru.Treasury.Config.File
    ( ConfigFileError (..)
    , decodeTreasuryConfigYaml
    , readTreasuryConfigYaml
    ) where

import Data.ByteString (ByteString)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Data.Yaml qualified as Yaml

import Amaru.Treasury.Config.Types
    ( TreasuryConfig (..)
    , TreasuryProfileConfig (..)
    )

-- | Failure while reading or decoding a config file.
data ConfigFileError
    = ConfigFileReadError !FilePath !String
    | ConfigFileDecodeError !FilePath !String
    deriving stock (Eq, Show)

-- | Decode a treasury YAML config from bytes.
decodeTreasuryConfigYaml :: ByteString -> Either String TreasuryConfig
decodeTreasuryConfigYaml bytes =
    normalizeProfileNames
        <$> firstYamlError (Yaml.decodeEither' bytes)

-- | Read and decode a treasury YAML config file.
readTreasuryConfigYaml
    :: FilePath
    -> IO (Either ConfigFileError TreasuryConfig)
readTreasuryConfigYaml path = do
    loaded <- Yaml.decodeFileEither path
    pure $ case loaded of
        Left err ->
            Left $
                ConfigFileDecodeError
                    path
                    (Yaml.prettyPrintParseException err)
        Right config -> Right (normalizeProfileNames config)

firstYamlError :: Either Yaml.ParseException a -> Either String a
firstYamlError =
    either (Left . Yaml.prettyPrintParseException) Right

normalizeProfileNames :: TreasuryConfig -> TreasuryConfig
normalizeProfileNames config =
    config
        { tcProfiles =
            Map.mapWithKey normalizeProfileName (tcProfiles config)
        }

normalizeProfileName
    :: Text
    -> TreasuryProfileConfig
    -> TreasuryProfileConfig
normalizeProfileName key profile
    | T.null (tpcProfileName profile) =
        profile{tpcProfileName = key}
    | otherwise = profile
