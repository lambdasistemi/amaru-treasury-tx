{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Report.Identity
Description : Report identity resolution types
License     : Apache-2.0

Pure address, signer, and reference-input identity maps for report
rendering. A miss is represented explicitly as 'Unresolved' so callers
never need to print a bare on-chain identifier.
-}
module Amaru.Treasury.Report.Identity
    ( AddressBook (..)
    , IdentityMap (..)
    , ReferenceInputMap (..)
    , ResolutionInputs (..)
    , Resolved (..)
    , RoleLabel (..)
    , buildAddressBook
    , buildIdentityMap
    , buildReferenceInputMap
    , resolveAddress
    , resolveReferenceInput
    , resolveSigner
    ) where

import Data.Either (fromRight)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

import Amaru.Treasury.IntentJSON
    ( DisburseInputs (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , SwapInputs (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    )
import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , ScriptRef (..)
    , TreasuryMetadata (..)
    )
import Amaru.Treasury.Report
    ( SignerRequirement (..)
    , SignerSource (..)
    , TransactionReport (..)
    )
import Amaru.Treasury.Scope
    ( ScopeId (..)
    , scopeFromText
    , scopeText
    )

-- | Resolved label for a printable identity.
data RoleLabel = RoleLabel
    { rlText :: !Text
    , rlScope :: !(Maybe ScopeId)
    }
    deriving stock (Eq, Ord, Show)

-- | Resolution outcome for a printable identity.
data Resolved
    = Resolved !RoleLabel
    | Unresolved
    deriving stock (Eq, Show)

-- | Address book keyed by bech32 address.
newtype AddressBook = AddressBook
    { abAddresses :: Map Text Resolved
    }
    deriving stock (Eq, Show)

-- | Signer identity map keyed by 28-byte key-hash hex.
newtype IdentityMap = IdentityMap
    { imSigners :: Map Text Resolved
    }
    deriving stock (Eq, Show)

-- | Reference-input labels keyed by @txid#ix@.
newtype ReferenceInputMap = ReferenceInputMap
    { rimReferenceInputs :: Map Text Resolved
    }
    deriving stock (Eq, Show)

-- | Declarative inputs consumed by the pure resolver.
data ResolutionInputs = ResolutionInputs
    { riMetadata :: !(Maybe TreasuryMetadata)
    , riIntent :: !SomeTreasuryIntent
    , riReport :: !TransactionReport
    }
    deriving stock (Eq, Show)

buildAddressBook :: ResolutionInputs -> AddressBook
buildAddressBook inputs =
    AddressBook . Map.unions $
        [ maybe Map.empty metadataAddresses (riMetadata inputs)
        , intentAddresses (riIntent inputs)
        ]

buildIdentityMap :: ResolutionInputs -> IdentityMap
buildIdentityMap inputs =
    IdentityMap . Map.unions $
        [ maybe Map.empty metadataSigners (riMetadata inputs)
        , intentOwnerSigners (riIntent inputs)
        , reportSigners (riReport inputs)
        , intentRequiredSigners (riIntent inputs)
        ]

buildReferenceInputMap :: ResolutionInputs -> ReferenceInputMap
buildReferenceInputMap inputs =
    ReferenceInputMap . Map.unions $
        [ maybe Map.empty metadataReferences (riMetadata inputs)
        , intentReferences (riIntent inputs)
        ]

resolveAddress :: AddressBook -> Text -> Resolved
resolveAddress (AddressBook addresses) address =
    Map.findWithDefault Unresolved address addresses

resolveSigner :: IdentityMap -> Text -> Resolved
resolveSigner (IdentityMap signers) keyHash =
    Map.findWithDefault Unresolved keyHash signers

resolveReferenceInput :: ReferenceInputMap -> Text -> Resolved
resolveReferenceInput (ReferenceInputMap references) txIn =
    Map.findWithDefault Unresolved txIn references

metadataAddresses :: TreasuryMetadata -> Map Text Resolved
metadataAddresses metadata =
    Map.fromList
        [ ( smAddress scopeMetadata
          , resolvedForScope (scopeRole scope "treasury") scope
          )
        | (scope, scopeMetadata) <- Map.toList (tmTreasuries metadata)
        ]

metadataSigners :: TreasuryMetadata -> Map Text Resolved
metadataSigners metadata =
    Map.fromList
        [ (owner, resolvedForScope (scopeRole scope "scope owner") scope)
        | (scope, scopeMetadata) <- Map.toList (tmTreasuries metadata)
        , Just owner <- [smOwner scopeMetadata]
        ]

metadataReferences :: TreasuryMetadata -> Map Text Resolved
metadataReferences metadata =
    Map.fromList $
        [
            ( tmScopeOwners metadata
            , resolved "scope owners registry" Nothing
            )
        ]
            <> concatMap
                (uncurry metadataScopeReferences)
                (Map.toList (tmTreasuries metadata))

metadataScopeReferences
    :: ScopeId -> ScopeMetadata -> [(Text, Resolved)]
metadataScopeReferences scope scopeMetadata =
    [ scriptRef
        (smTreasury scopeMetadata)
        (scopeRole scope "treasury reference script")
    , scriptRef
        (smPermissions scopeMetadata)
        (scopeRole scope "permissions reference script")
    , scriptRef
        (smRegistry scopeMetadata)
        (scopeRole scope "registry reference")
    ]
  where
    scriptRef ref label =
        (srDeployedAt ref, resolvedForScope label scope)

intentAddresses :: SomeTreasuryIntent -> Map Text Resolved
intentAddresses (SomeTreasuryIntent action intent) =
    Map.fromList $
        baseIntentAddresses intent
            <> actionAddresses action intent

baseIntentAddresses :: TreasuryIntent a -> [(Text, Resolved)]
baseIntentAddresses intent =
    [ (wjAddress (tiWallet intent), resolved "operator wallet" Nothing)
    ,
        ( sjTreasuryAddress scope
        , resolvedForScope (scopeRole resolvedScope "treasury") resolvedScope
        )
    ]
  where
    scope = tiScope intent
    resolvedScope = intentScope intent

actionAddresses :: SAction a -> TreasuryIntent a -> [(Text, Resolved)]
actionAddresses action intent =
    case action of
        SSwap ->
            [
                ( swiSwapOrderAddress (tiPayload intent)
                , resolved
                    ( "Sundae swap-order ["
                        <> scopeText resolvedScope
                        <> "]"
                    )
                    (Just resolvedScope)
                )
            ]
        SDisburse ->
            [
                ( diBeneficiaryAddress (tiPayload intent)
                , resolved "beneficiary" Nothing
                )
            ]
        SWithdraw -> []
        SReorganize -> []
  where
    resolvedScope = intentScope intent

intentOwnerSigners :: SomeTreasuryIntent -> Map Text Resolved
intentOwnerSigners (SomeTreasuryIntent action intent) =
    case action of
        SSwap ->
            Map.fromList
                [ owner CoreDevelopment (swiCoreOwner payload)
                , owner OpsAndUseCases (swiOpsOwner payload)
                , owner
                    NetworkCompliance
                    (swiNetworkComplianceOwner payload)
                , owner Middleware (swiMiddlewareOwner payload)
                ]
          where
            payload = tiPayload intent
        SDisburse -> Map.empty
        SWithdraw -> Map.empty
        SReorganize -> Map.empty
  where
    owner scope keyHash =
        (keyHash, resolvedForScope (scopeRole scope "scope owner") scope)

reportSigners :: TransactionReport -> Map Text Resolved
reportSigners report =
    Map.fromList
        [ (srKeyHash signer, reportSignerLabel signer)
        | signer <- trSigners report
        ]

reportSignerLabel :: SignerRequirement -> Resolved
reportSignerLabel signer =
    case (srSource signer, srScope signer >>= scopeFromTextMaybe) of
        (SourceSelectedScopeOwner, Just scope) ->
            resolvedForScope (scopeRole scope "scope owner") scope
        (SourceIntentRequiredSigner, Just scope) ->
            resolvedForScope (scopeRole scope "intent required signer") scope
        (SourceExtraSigner, Just scope) ->
            resolvedForScope (scopeRole scope "extra signer") scope
        (SourceTxBodyRequiredSigner, Just scope) ->
            resolvedForScope (scopeRole scope "tx-body required signer") scope
        (SourceSelectedScopeOwner, Nothing) ->
            resolved "selected scope owner" Nothing
        (SourceExtraSigner, Nothing) ->
            resolved "extra required signer" Nothing
        (SourceIntentRequiredSigner, Nothing) ->
            resolved "intent required signer" Nothing
        (SourceTxBodyRequiredSigner, Nothing) ->
            resolved "tx-body required signer" Nothing

intentRequiredSigners :: SomeTreasuryIntent -> Map Text Resolved
intentRequiredSigners (SomeTreasuryIntent _ intent) =
    Map.fromList $
        case tiSigners intent of
            [] -> []
            first : rest ->
                ( first
                , resolvedForScope
                    (scopeRole resolvedScope "scope owner")
                    resolvedScope
                )
                    : [ (keyHash, resolved "intent required signer" Nothing)
                      | keyHash <- rest
                      ]
  where
    resolvedScope = intentScope intent

intentReferences :: SomeTreasuryIntent -> Map Text Resolved
intentReferences (SomeTreasuryIntent _ intent) =
    Map.fromList
        [ (sjScopesDeployedAt scope, resolved "scope owners registry" Nothing)
        ,
            ( sjPermissionsDeployedAt scope
            , resolved
                (scopeRole resolvedScope "permissions reference script")
                (Just resolvedScope)
            )
        ,
            ( sjTreasuryDeployedAt scope
            , resolved
                (scopeRole resolvedScope "treasury reference script")
                (Just resolvedScope)
            )
        ,
            ( sjRegistryDeployedAt scope
            , resolvedForScope
                (scopeRole resolvedScope "registry reference")
                resolvedScope
            )
        ]
  where
    scope = tiScope intent
    resolvedScope = intentScope intent

intentScope :: TreasuryIntent a -> ScopeId
intentScope intent =
    fromRight NetworkCompliance $
        scopeFromText (sjId (tiScope intent))

scopeFromTextMaybe :: Text -> Maybe ScopeId
scopeFromTextMaybe =
    either (const Nothing) Just . scopeFromText

scopeRole :: ScopeId -> Text -> Text
scopeRole scope role =
    scopeText scope <> " " <> role

resolved :: Text -> Maybe ScopeId -> Resolved
resolved label scope =
    Resolved RoleLabel{rlText = label, rlScope = scope}

resolvedForScope :: Text -> ScopeId -> Resolved
resolvedForScope label scope =
    resolved label (Just scope)
