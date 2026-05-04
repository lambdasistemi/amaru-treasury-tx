{- |
Module      : Amaru.Treasury.Scope
Description : Scope identifiers for Amaru treasury contracts
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The five Amaru treasury scopes per the
[`pragma-org/amaru-treasury` configuration](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json).
The scope set is fixed by the on-chain deployment and is
never extended at the CLI level.
-}
module Amaru.Treasury.Scope
    ( -- * Scope identifier
      ScopeId (..)

      -- * Conversion
    , scopeText
    , scopeFromText
    , allScopes
    ) where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import Data.Text qualified as T

-- | One of the five Amaru treasury scopes.
data ScopeId
    = -- | @core_development@
      CoreDevelopment
    | -- | @ops_and_use_cases@
      OpsAndUseCases
    | -- | @network_compliance@
      NetworkCompliance
    | -- | @middleware@
      Middleware
    | -- | @contingency@
      Contingency
    deriving (Eq, Ord, Show, Read, Bounded, Enum)

-- | Render a 'ScopeId' as the canonical bash identifier.
scopeText :: ScopeId -> Text
scopeText = \case
    CoreDevelopment -> "core_development"
    OpsAndUseCases -> "ops_and_use_cases"
    NetworkCompliance -> "network_compliance"
    Middleware -> "middleware"
    Contingency -> "contingency"

-- | Total parser. Rejects any unknown name.
scopeFromText :: Text -> Either String ScopeId
scopeFromText t = case t of
    "core_development" -> Right CoreDevelopment
    "ops_and_use_cases" -> Right OpsAndUseCases
    "network_compliance" -> Right NetworkCompliance
    "middleware" -> Right Middleware
    "contingency" -> Right Contingency
    _ ->
        Left $
            "unknown scope: "
                <> T.unpack t
                <> "; expected one of "
                <> show (map scopeText allScopes)

-- | The five scopes in declaration order.
allScopes :: [ScopeId]
allScopes = [minBound .. maxBound]

instance ToJSON ScopeId where
    toJSON = toJSON . scopeText

instance FromJSON ScopeId where
    parseJSON = withText "ScopeId" $ \t ->
        case scopeFromText t of
            Right s -> pure s
            Left err -> fail err :: Parser ScopeId
