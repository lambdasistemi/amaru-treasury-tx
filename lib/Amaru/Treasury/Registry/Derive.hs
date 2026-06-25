{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Registry.Derive
Description : Registry script derivation helpers
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pure helpers for applying Aiken validator parameters and hashing the
resulting Plutus V3 scripts. These functions are one of the build-time
trust-root checks for the registry walk.
-}
module Amaru.Treasury.Registry.Derive
    ( ScriptParam (..)
    , applyParams
    , applyScriptParams
    , scriptHashOfBlob
    , scriptHashToHex
    , derivedScopesNftPolicyBlob
    , derivedScopesNftPolicy
    , derivedRegistryNftPolicyBlob
    , derivedRegistryNftPolicy
    , derivedPermissionsScriptBlob
    , derivedPermissionsScriptHash
    , derivedTreasuryScriptBlob
    , derivedTreasuryScriptHash
    ) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Text (Text)
import Data.Text.Encoding qualified as T
import Data.Word (Word64)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV3)
    , Plutus (..)
    , PlutusBinary (..)
    , hashPlutusScript
    )
import PlutusCore.Data (Data (..))
import PlutusCore.DeBruijn
    ( DeBruijn
    , NamedDeBruijn
    , unNameDeBruijn
    )
import PlutusCore.Default (DefaultFun, DefaultUni, someValue)
import PlutusLedgerApi.Common qualified as Plutus
import UntypedPlutusCore.Core
    ( Program (..)
    , Term
    )
import UntypedPlutusCore.Core qualified as UPLC

import Amaru.Treasury.Registry.Constants
    ( payoutUpperbound
    , permissionsValidatorBlob
    , registrySeedIx
    , registrySeedTxIdHex
    , scopesSeedIx
    , scopesSeedTxIdHex
    , scopesValidatorBlob
    , treasuryExpirationMs
    , treasuryRegistryValidatorBlob
    , treasuryValidatorBlob
    )
import Amaru.Treasury.Scope (ScopeId (..))

-- | A Plutus validator parameter.
data ScriptParam
    = -- | Parameter passed as Plutus @Data@.
      ParamData !Data
    | -- | Parameter passed as Plutus builtin bytes.
      ParamBytes !ByteString
    | -- | Parameter passed as a Plutus builtin integer.
      ParamInteger !Integer
    deriving (Eq, Show)

-- | Apply Plutus @Data@ parameters to a compiled validator blob.
applyParams
    :: ByteString
    -> [Data]
    -> Either String ByteString
applyParams blob =
    applyScriptParams blob . fmap ParamData

-- | Apply typed script parameters to a compiled validator blob.
applyScriptParams
    :: ByteString
    -> [ScriptParam]
    -> Either String ByteString
applyScriptParams blob params = do
    Program () version term <- decodeProgram blob
    let
        applied =
            foldl'
                (\f param -> UPLC.Apply () f (paramTerm param))
                term
                params
    Right . SBS.fromShort . Plutus.serialiseUPLC $
        Program () version applied

decodeProgram
    :: ByteString
    -> Either String (Program DeBruijn DefaultUni DefaultFun ())
decodeProgram blob =
    case Plutus.deserialiseScript
        Plutus.PlutusV3
        (Plutus.ledgerLanguageIntroducedIn Plutus.PlutusV3)
        (SBS.toShort blob) of
        Left err -> Left (show err)
        Right script ->
            let Plutus.ScriptNamedDeBruijn (Program () version term) =
                    Plutus.deserialisedScript script
            in  Right (Program () version (stripTermNames term))

stripTermNames
    :: Term NamedDeBruijn DefaultUni DefaultFun ()
    -> Term DeBruijn DefaultUni DefaultFun ()
stripTermNames = \case
    UPLC.Var ann name -> UPLC.Var ann (unNameDeBruijn name)
    UPLC.Delay ann term -> UPLC.Delay ann (stripTermNames term)
    UPLC.LamAbs ann name body ->
        UPLC.LamAbs ann (unNameDeBruijn name) (stripTermNames body)
    UPLC.Apply ann function argument ->
        UPLC.Apply ann (stripTermNames function) (stripTermNames argument)
    UPLC.Constant ann value -> UPLC.Constant ann value
    UPLC.Force ann term -> UPLC.Force ann (stripTermNames term)
    UPLC.Error ann -> UPLC.Error ann
    UPLC.Builtin ann fun -> UPLC.Builtin ann fun
    UPLC.Constr ann tag fields ->
        UPLC.Constr ann tag (stripTermNames <$> fields)
    UPLC.Case ann scrutinee branches ->
        UPLC.Case ann (stripTermNames scrutinee) (stripTermNames <$> branches)

-- | Hash a compiled Plutus V3 validator blob.
scriptHashOfBlob
    :: ByteString
    -> Either String ScriptHash
scriptHashOfBlob blob =
    Right . hashPlutusScript $
        ( Plutus
            (PlutusBinary (SBS.toShort blob))
            :: Plutus 'PlutusV3
        )

-- | Render a ledger script hash as 28-byte lower-case hex.
scriptHashToHex :: ScriptHash -> Text
scriptHashToHex (ScriptHash h) =
    T.decodeUtf8 (B16.encode (hashToBytes h))

-- | Derive the Scopes NFT policy from the pinned scopes validator.
derivedScopesNftPolicyBlob :: Either String ByteString
derivedScopesNftPolicyBlob =
    applyParams
        scopesValidatorBlob
        [ outputReferenceData scopesSeedTxIdHex scopesSeedIx
        ]

-- | Derive the Scopes NFT policy from the pinned scopes validator.
derivedScopesNftPolicy :: Either String ScriptHash
derivedScopesNftPolicy =
    scriptHashOfBlob =<< derivedScopesNftPolicyBlob

-- | Derive a per-scope registry NFT policy.
derivedRegistryNftPolicyBlob
    :: ScopeId
    -> Either String ByteString
derivedRegistryNftPolicyBlob scope =
    applyParams
        treasuryRegistryValidatorBlob
        [ outputReferenceData registrySeedTxIdHex registrySeedIx
        , scopeData scope
        ]

-- | Derive a per-scope registry NFT policy hash.
derivedRegistryNftPolicy
    :: ScopeId
    -> Either String ScriptHash
derivedRegistryNftPolicy scope =
    scriptHashOfBlob =<< derivedRegistryNftPolicyBlob scope

-- | Derive a per-scope permissions script.
derivedPermissionsScriptBlob
    :: ScopeId
    -> Either String ByteString
derivedPermissionsScriptBlob scope = do
    scopesPolicy <- derivedScopesNftPolicy
    policyBytes <- scriptHashBytes scopesPolicy
    applyScriptParams
        permissionsValidatorBlob
        [ ParamData (B policyBytes)
        , ParamData (scopeData scope)
        ]

-- | Derive a per-scope permissions script hash.
derivedPermissionsScriptHash
    :: ScopeId
    -> Either String ScriptHash
derivedPermissionsScriptHash scope =
    scriptHashOfBlob =<< derivedPermissionsScriptBlob scope

-- | Derive a per-scope treasury script.
derivedTreasuryScriptBlob
    :: ScopeId
    -> Either String ByteString
derivedTreasuryScriptBlob scope = do
    registryPolicy <- derivedRegistryNftPolicy scope
    permissionsHash <- derivedPermissionsScriptHash scope
    registryBytes <- scriptHashBytes registryPolicy
    permissionsBytes <- scriptHashBytes permissionsHash
    applyParams
        treasuryValidatorBlob
        [treasuryConfigurationData registryBytes permissionsBytes]

-- | Derive a per-scope treasury script hash.
derivedTreasuryScriptHash
    :: ScopeId
    -> Either String ScriptHash
derivedTreasuryScriptHash scope =
    scriptHashOfBlob =<< derivedTreasuryScriptBlob scope

paramTerm
    :: ScriptParam
    -> Term DeBruijn DefaultUni DefaultFun ()
paramTerm = \case
    ParamData datum -> UPLC.Constant () (someValue datum)
    ParamBytes bytes -> UPLC.Constant () (someValue bytes)
    ParamInteger integer -> UPLC.Constant () (someValue integer)

outputReferenceData
    :: Text
    -> Word64
    -> Data
outputReferenceData txIdHex ix =
    Constr
        0
        [ B (decodeHexUnsafe 32 txIdHex)
        , I (toInteger ix)
        ]

treasuryConfigurationData :: ByteString -> ByteString -> Data
treasuryConfigurationData registryPolicy permissionsHash =
    Constr
        0
        [ B registryPolicy
        , treasuryPermissionsData permissionsHash
        , I treasuryExpirationMs
        , I payoutUpperbound
        ]

treasuryPermissionsData :: ByteString -> Data
treasuryPermissionsData permissionsHash =
    Constr
        0
        [ multisigScriptPermission permissionsHash
        , multisigScriptPermission permissionsHash
        , Constr 2 [List []]
        , multisigScriptPermission permissionsHash
        ]

multisigScriptPermission :: ByteString -> Data
multisigScriptPermission scriptHash =
    Constr 6 [B scriptHash]

scopeData :: ScopeId -> Data
scopeData scope =
    Constr (scopeIndex scope) []

scopeIndex :: ScopeId -> Integer
scopeIndex = \case
    CoreDevelopment -> 0
    OpsAndUseCases -> 1
    NetworkCompliance -> 2
    Middleware -> 3
    Contingency -> 4

scriptHashBytes :: ScriptHash -> Either String ByteString
scriptHashBytes (ScriptHash h) =
    Right (hashToBytes h)

decodeHexUnsafe
    :: Int
    -> Text
    -> ByteString
decodeHexUnsafe expected t =
    case B16.decode (T.encodeUtf8 t) of
        Right bytes
            | BS.length bytes == expected -> bytes
        _ -> error ("invalid pinned hex constant: " <> show t)
