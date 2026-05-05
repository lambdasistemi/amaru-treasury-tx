{- |
Module      : Amaru.Treasury.Registry.Verify
Description : On-chain registry anchor verification
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Entry point and verified projection for registry anchor verification.
The pure core, 'verifyWithAnchors', checks a parsed metadata snapshot
against already-extracted chain anchors. The IO entry point reads the
local metadata file, extracts the on-chain anchors through the current
'Provider', then delegates to the pure verifier.
-}
module Amaru.Treasury.Registry.Verify
    ( VerifiedRegistry (..)
    , VerifiedScope (..)
    , RegistryAnchors (..)
    , RegistryNftAnchor (..)
    , verifyWithAnchors
    , verifyRegistry
    , RegistryWalkError (..)
    ) where

import Control.Monad (unless)
import Data.Aeson
    ( FromJSON (..)
    , withObject
    , (.:)
    )
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address
    ( Addr (..)
    , getNetwork
    , serialiseAddr
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , datumTxOutL
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    , txIxToInt
    )
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core qualified as Core
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (KeyHash, ScriptHash, extractHash)
import Cardano.Ledger.Keys (KeyRole (Witness))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , PolicyID (..)
    , lookupMultiAsset
    )
import Cardano.Ledger.Plutus.Data
    ( Datum (..)
    , binaryDataToData
    , getPlutusData
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Codec.Binary.Bech32 qualified as Bech32
import Lens.Micro ((^.))
import PlutusCore.Data (Data (..))

import Amaru.Treasury.Backend
    ( Provider (..)
    , queryUTxOByTxInH
    , queryUTxOsAtH
    )
import Amaru.Treasury.LedgerParse
    ( addrFromText
    , keyHashFromHex
    , scriptHashFromHex
    , txInFromText
    )
import Amaru.Treasury.Registry.Constants
    ( registryTokenName
    , scopesTokenName
    )
import Amaru.Treasury.Registry.Derive
    ( derivedPermissionsScriptHash
    , derivedRegistryNftPolicy
    , derivedScopesNftPolicy
    , derivedTreasuryScriptHash
    , scriptHashToHex
    )
import Amaru.Treasury.Registry.Metadata
    ( RegistryWalkError (..)
    , ScriptDeployment (..)
    , TreasuryEntry (..)
    , TxInRef (..)
    , UpstreamMetadata (..)
    , readUpstreamMetadataFile
    )
import Amaru.Treasury.Scope
    ( ScopeId (..)
    , scopeFromText
    , scopeText
    )

-- | Registry data after every consumed metadata field has been verified.
data VerifiedRegistry = VerifiedRegistry
    { vrScopesNftUtxo :: !TxIn
    , vrScopesNftPolicy :: !ScriptHash
    , vrOwners :: !(Map ScopeId (KeyHash Witness))
    , vrTreasuriesByScope :: !(Map ScopeId VerifiedScope)
    }
    deriving (Eq, Show)

-- | Per-scope verified registry projection.
data VerifiedScope = VerifiedScope
    { vsAddress :: !Addr
    , vsTreasuryScriptHash :: !ScriptHash
    , vsRegistryScriptHash :: !ScriptHash
    , vsPermissionsScriptHash :: !ScriptHash
    , vsRegistryNftUtxo :: !TxIn
    , vsTreasuryDeployedAt :: !TxIn
    , vsPermissionsDeployedAt :: !TxIn
    , vsRegistryDeployedAt :: !TxIn
    }
    deriving (Eq, Show)

-- | Chain and locally-derived anchors used by the pure verifier.
data RegistryAnchors = RegistryAnchors
    { raScopesNftPolicy :: !Text
    , raScopesNftMatches :: ![TxInRef]
    , raOwners :: !(Map ScopeId (Maybe Text))
    , raRegistries :: !(Map ScopeId RegistryNftAnchor)
    , raReferenceScripts :: !(Map TxInRef Text)
    }
    deriving (Eq, Show)

-- | Per-scope registry NFT anchor.
data RegistryNftAnchor = RegistryNftAnchor
    { rnaMatches :: ![TxInRef]
    , rnaTreasuryScriptHash :: !Text
    , rnaRegistryScriptHash :: !Text
    , rnaPermissionsScriptHash :: !Text
    , rnaAddress :: !Text
    }
    deriving (Eq, Show)

-- | Verify parsed metadata against extracted anchors.
verifyWithAnchors
    :: UpstreamMetadata
    -> RegistryAnchors
    -> Set ScopeId
    -> Either RegistryWalkError VerifiedRegistry
verifyWithAnchors metadata anchors requested = do
    scopesRef <-
        requireUnique
            "scope_owners"
            Nothing
            (umScopeOwners metadata)
            (raScopesNftMatches anchors)
    scopesTxIn <- parseTxInRef "scope_owners" Nothing scopesRef
    metadataScopesTxIn <-
        parseTxInRef "scope_owners" Nothing (umScopeOwners metadata)
    unless (scopesTxIn == metadataScopesTxIn) $
        Left $
            AnchorMismatch
                "scope_owners"
                Nothing
                (unTxInRef (umScopeOwners metadata))
                (unTxInRef scopesRef)
    scopesPolicy <-
        parseScriptHash
            "scopes_nft_policy"
            Nothing
            (raScopesNftPolicy anchors)

    verifiedScopes <-
        Map.fromList
            <$> traverse verifyScope (Set.toList requested)
    owners <-
        Map.fromList
            <$> traverse ownerEntry (Map.toList (raOwners anchors))

    pure
        VerifiedRegistry
            { vrScopesNftUtxo = scopesTxIn
            , vrScopesNftPolicy = scopesPolicy
            , vrOwners = owners
            , vrTreasuriesByScope = verifiedScopes
            }
  where
    verifyScope scope = do
        entry <-
            maybe
                ( Left (ChainQueryError ("missing metadata scope: " <> scopeText scope))
                )
                Right
                (Map.lookup scope (umTreasuries metadata))
        registryAnchor <-
            maybe
                ( Left
                    (ChainQueryError ("missing registry anchor: " <> scopeText scope))
                )
                Right
                (Map.lookup scope (raRegistries anchors))

        assertText
            "owner"
            (Just scope)
            (maybe "null" renderOwner (Map.lookup scope (raOwners anchors)))
            (renderOwner (teOwner entry))
        assertText
            "treasury_script.hash"
            (Just scope)
            (rnaTreasuryScriptHash registryAnchor)
            (sdHash (teTreasuryScript entry))
        assertText
            "registry_script.hash"
            (Just scope)
            (rnaRegistryScriptHash registryAnchor)
            (sdHash (teRegistryScript entry))
        assertText
            "permissions_script.hash"
            (Just scope)
            (rnaPermissionsScriptHash registryAnchor)
            (sdHash (tePermissionsScript entry))
        assertText
            "address"
            (Just scope)
            (rnaAddress registryAnchor)
            (teAddress entry)

        registryRef <-
            requireUnique
                "registry_nft"
                (Just scope)
                (sdDeployedAt (teRegistryScript entry))
                (rnaMatches registryAnchor)

        treasuryHash <-
            parseScriptHash
                "treasury_script.hash"
                (Just scope)
                (rnaTreasuryScriptHash registryAnchor)
        registryHash <-
            parseScriptHash
                "registry_script.hash"
                (Just scope)
                (rnaRegistryScriptHash registryAnchor)
        permissionsHash <-
            parseScriptHash
                "permissions_script.hash"
                (Just scope)
                (rnaPermissionsScriptHash registryAnchor)
        address <-
            parseAddress
                "address"
                (Just scope)
                (rnaAddress registryAnchor)

        treasuryRef <-
            verifyReferenceScript
                "treasury_script.deployed_at"
                scope
                treasuryHash
                (teTreasuryScript entry)
        permissionsRef <-
            verifyReferenceScript
                "permissions_script.deployed_at"
                scope
                permissionsHash
                (tePermissionsScript entry)
        registryScriptRef <-
            verifyReferenceScript
                "registry_script.deployed_at"
                scope
                registryHash
                (teRegistryScript entry)

        registryNftUtxo <-
            parseTxInRef "registry_nft" (Just scope) registryRef

        pure
            ( scope
            , VerifiedScope
                { vsAddress = address
                , vsTreasuryScriptHash = treasuryHash
                , vsRegistryScriptHash = registryHash
                , vsPermissionsScriptHash = permissionsHash
                , vsRegistryNftUtxo = registryNftUtxo
                , vsTreasuryDeployedAt = treasuryRef
                , vsPermissionsDeployedAt = permissionsRef
                , vsRegistryDeployedAt = registryScriptRef
                }
            )

    verifyReferenceScript field scope expected deployment = do
        actual <-
            lookupReferenceScript field scope (sdDeployedAt deployment)
        assertText field (Just scope) (sdHash deployment) actual
        assertText field (Just scope) (scriptHashToHex expected) actual
        parseTxInRef field (Just scope) (sdDeployedAt deployment)

    ownerEntry (scope, Just ownerHex) =
        do
            owner <- parseOwner "owner" (Just scope) ownerHex
            pure (scope, owner)
    ownerEntry (_scope, Nothing) =
        Left (ChainQueryError "verified owner map cannot contain null owner")

    lookupReferenceScript field scope ref =
        case Map.lookup ref (raReferenceScripts anchors) of
            Just scriptHash -> Right scriptHash
            Nothing -> do
                target <- parseTxInRef field (Just scope) ref
                case matchingReferenceScripts target of
                    [] -> Left (AnchorSpent field (Just scope) ref)
                    [(_refText, scriptHash)] -> Right scriptHash
                    many ->
                        Left $
                            AnchorAmbiguous
                                field
                                (Just scope)
                                (fst <$> many)

    matchingReferenceScripts target =
        mapMaybe
            ( \(candidate, scriptHash) ->
                case txInFromText (unTxInRef candidate) of
                    Right candidateTxIn
                        | candidateTxIn == target ->
                            Just (unTxInRef candidate, scriptHash)
                    _ -> Nothing
            )
            (Map.toList (raReferenceScripts anchors))

-- | Verify a local metadata snapshot against on-chain anchors.
verifyRegistry
    :: Provider IO
    -> FilePath
    -> Set ScopeId
    -> IO (Either RegistryWalkError VerifiedRegistry)
verifyRegistry provider metadataPath scopes = do
    metadata <- readUpstreamMetadataFile metadataPath
    case metadata of
        Left err -> pure (Left err)
        Right parsed -> do
            anchors <- extractRegistryAnchors provider parsed scopes
            pure $ do
                extracted <- anchors
                verifyWithAnchors parsed extracted scopes

data ScopeAnchorPlan = ScopeAnchorPlan
    { sapScope :: !ScopeId
    , sapTreasuryHash :: !ScriptHash
    , sapRegistryPolicy :: !ScriptHash
    , sapPermissionsHash :: !ScriptHash
    }

extractRegistryAnchors
    :: Provider IO
    -> UpstreamMetadata
    -> Set ScopeId
    -> IO (Either RegistryWalkError RegistryAnchors)
extractRegistryAnchors provider metadata requested =
    case buildAnchorPlan metadata requested of
        Left err -> pure (Left err)
        Right (network, scopesPolicy, scopePlans) ->
            let scopesAddress =
                    scriptAddress network scopesPolicy
                registryAddresses =
                    ( \plan ->
                        ( sapScope plan
                        , scriptAddress network (sapRegistryPolicy plan)
                        )
                    )
                        <$> scopePlans
            in  withAcquired provider $ \handle -> do
                    byAddress <-
                        queryUTxOsAtH handle $
                            Set.fromList $
                                scopesAddress
                                    : ( snd <$> registryAddresses
                                      )
                    referenceUtxos <-
                        queryUTxOByTxInH
                            handle
                            (deploymentRefs metadata requested)
                    let scopesUtxos =
                            Map.findWithDefault [] scopesAddress byAddress
                        registryUtxos =
                            ( \(scope, address) ->
                                ( scope
                                , Map.findWithDefault [] address byAddress
                                )
                            )
                                <$> registryAddresses
                    pure $
                        buildAnchors
                            network
                            scopesPolicy
                            scopePlans
                            scopesUtxos
                            registryUtxos
                            referenceUtxos
  where
    buildAnchors
        network
        scopesPolicy
        scopePlans
        scopesUtxos
        registryUtxos
        referenceUtxos =
            do
                owners <-
                    extractScopeOwners
                        (nftOutputs scopesPolicy scopesTokenName scopesUtxos)
                registries <-
                    Map.fromList
                        <$> traverse
                            (uncurry (extractRegistryAnchor network scopePlans))
                            registryUtxos
                references <- extractReferenceScripts referenceUtxos
                pure
                    RegistryAnchors
                        { raScopesNftPolicy = scriptHashToHex scopesPolicy
                        , raScopesNftMatches =
                            renderTxInRef . fst
                                <$> nftOutputs
                                    scopesPolicy
                                    scopesTokenName
                                    scopesUtxos
                        , raOwners = owners
                        , raRegistries = registries
                        , raReferenceScripts = references
                        }

buildAnchorPlan
    :: UpstreamMetadata
    -> Set ScopeId
    -> Either RegistryWalkError (Network, ScriptHash, [ScopeAnchorPlan])
buildAnchorPlan metadata requested = do
    network <- inferMetadataNetwork metadata requested
    scopesPolicy <-
        mapParseError
            "scopes_nft_policy"
            Nothing
            derivedScopesNftPolicy
    plans <-
        traverse
            scopePlan
            (Map.toList (requestedTreasuries metadata requested))
    pure (network, scopesPolicy, plans)
  where
    scopePlan (scope, _entry) = do
        registryPolicy <-
            mapParseError
                "registry_script.hash"
                (Just scope)
                (derivedRegistryNftPolicy scope)
        permissionsHash <-
            mapParseError
                "permissions_script.hash"
                (Just scope)
                (derivedPermissionsScriptHash scope)
        treasuryHash <-
            mapParseError
                "treasury_script.hash"
                (Just scope)
                (derivedTreasuryScriptHash scope)
        pure
            ScopeAnchorPlan
                { sapScope = scope
                , sapTreasuryHash = treasuryHash
                , sapRegistryPolicy = registryPolicy
                , sapPermissionsHash = permissionsHash
                }

requestedTreasuries
    :: UpstreamMetadata
    -> Set ScopeId
    -> Map ScopeId TreasuryEntry
requestedTreasuries metadata requested
    | Set.null requested = umTreasuries metadata
    | otherwise =
        Map.restrictKeys (umTreasuries metadata) requested

inferMetadataNetwork
    :: UpstreamMetadata
    -> Set ScopeId
    -> Either RegistryWalkError Network
inferMetadataNetwork metadata requested = do
    networks <-
        traverse
            ( \(_scope, entry) ->
                getNetwork
                    <$> parseAddress "address" Nothing (teAddress entry)
            )
            (Map.toList entries)
    case Set.toList (Set.fromList networks) of
        [network] -> Right network
        [] -> Left (ChainQueryError "metadata contains no treasury addresses")
        many ->
            Left $
                ChainQueryError $
                    "metadata mixes address networks: "
                        <> T.intercalate ", " (renderNetwork <$> many)
  where
    scopedEntries = requestedTreasuries metadata requested
    entries
        | Map.null scopedEntries = umTreasuries metadata
        | otherwise = scopedEntries

renderNetwork :: Network -> Text
renderNetwork = \case
    Mainnet -> "mainnet"
    Testnet -> "testnet"

scriptAddress :: Network -> ScriptHash -> Addr
scriptAddress network scriptHash =
    Addr
        network
        (ScriptHashObj scriptHash)
        (StakeRefBase (ScriptHashObj scriptHash))

nftOutputs
    :: ScriptHash
    -> ByteString
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
nftOutputs policy tokenName =
    filter (hasNft policy tokenName . snd)

hasNft :: ScriptHash -> ByteString -> TxOut ConwayEra -> Bool
hasNft policy tokenName txOut =
    lookupMultiAsset
        (PolicyID policy)
        (AssetName (SBS.toShort tokenName))
        (txOut ^. valueTxOutL)
        == 1

extractScopeOwners
    :: [(TxIn, TxOut ConwayEra)]
    -> Either RegistryWalkError (Map ScopeId (Maybe Text))
extractScopeOwners scopesMatches =
    case scopesMatches of
        [(_txIn, txOut)] -> parseOwnersDatum =<< inlineDatum "scope_owners" Nothing txOut
        _ -> Right Map.empty

parseOwnersDatum
    :: Data
    -> Either RegistryWalkError (Map ScopeId (Maybe Text))
parseOwnersDatum = \case
    Constr 0 [core, ops, network, middleware] ->
        Map.fromList
            <$> traverse
                (uncurry parseOwnerDatum)
                [ (CoreDevelopment, core)
                , (OpsAndUseCases, ops)
                , (NetworkCompliance, network)
                , (Middleware, middleware)
                ]
    other ->
        Left $
            ChainQueryError $
                "scope_owners inline datum: expected Scopes constructor, got "
                    <> T.pack (show other)

parseOwnerDatum
    :: ScopeId
    -> Data
    -> Either RegistryWalkError (ScopeId, Maybe Text)
parseOwnerDatum scope = \case
    Constr 0 [B owner] ->
        Right (scope, Just (bytesToHex owner))
    other ->
        Left $
            ChainQueryError $
                fieldLabel "owner" (Just scope)
                    <> " inline datum: expected Signature, got "
                    <> T.pack (show other)

extractRegistryAnchor
    :: Network
    -> [ScopeAnchorPlan]
    -> ScopeId
    -> [(TxIn, TxOut ConwayEra)]
    -> Either RegistryWalkError (ScopeId, RegistryNftAnchor)
extractRegistryAnchor network plans scope registryUtxos = do
    plan <-
        maybe
            ( Left (ChainQueryError ("missing registry plan: " <> scopeText scope))
            )
            Right
            (findPlan scope plans)
    let matches =
            nftOutputs
                (sapRegistryPolicy plan)
                registryTokenName
                registryUtxos
    treasuryHashText <-
        case matches of
            [(_txIn, txOut)] ->
                extractRegistryTreasuryHash
                    scope
                    =<< inlineDatum "registry_nft" (Just scope) txOut
            _ -> Right ""
    if T.null treasuryHashText
        then Right ()
        else
            assertText
                "treasury_script.hash"
                (Just scope)
                (scriptHashToHex (sapTreasuryHash plan))
                treasuryHashText
    addressText <-
        if T.null treasuryHashText
            then Right ""
            else do
                treasuryHash <-
                    parseScriptHash
                        "treasury_script.hash"
                        (Just scope)
                        treasuryHashText
                renderAddress (scriptAddress network treasuryHash)
    pure
        ( scope
        , RegistryNftAnchor
            { rnaMatches = renderTxInRef . fst <$> matches
            , rnaTreasuryScriptHash = treasuryHashText
            , rnaRegistryScriptHash =
                scriptHashToHex (sapRegistryPolicy plan)
            , rnaPermissionsScriptHash =
                scriptHashToHex (sapPermissionsHash plan)
            , rnaAddress = addressText
            }
        )

findPlan :: ScopeId -> [ScopeAnchorPlan] -> Maybe ScopeAnchorPlan
findPlan scope =
    go
  where
    go [] = Nothing
    go (plan : rest)
        | sapScope plan == scope = Just plan
        | otherwise = go rest

extractRegistryTreasuryHash
    :: ScopeId
    -> Data
    -> Either RegistryWalkError Text
extractRegistryTreasuryHash scope = \case
    Constr 0 [treasuryCredential, _vendorCredential] ->
        extractScriptCredential scope treasuryCredential
    other ->
        Left $
            ChainQueryError $
                fieldLabel "registry_nft" (Just scope)
                    <> " inline datum: expected ScriptHashRegistry, got "
                    <> T.pack (show other)

extractScriptCredential
    :: ScopeId
    -> Data
    -> Either RegistryWalkError Text
extractScriptCredential scope = \case
    Constr 1 [B scriptHash] -> Right (bytesToHex scriptHash)
    other ->
        Left $
            ChainQueryError $
                fieldLabel "treasury_script.hash" (Just scope)
                    <> " inline datum: expected script credential, got "
                    <> T.pack (show other)

inlineDatum
    :: Text
    -> Maybe ScopeId
    -> TxOut ConwayEra
    -> Either RegistryWalkError Data
inlineDatum field scope txOut =
    case txOut ^. datumTxOutL of
        Datum datum ->
            Right $ getPlutusData (binaryDataToData datum)
        DatumHash _ ->
            Left $
                ChainQueryError $
                    fieldLabel field scope <> ": datum hash, expected inline datum"
        NoDatum ->
            Left $
                ChainQueryError $
                    fieldLabel field scope <> ": missing inline datum"

deploymentRefs :: UpstreamMetadata -> Set ScopeId -> Set TxIn
deploymentRefs metadata requested =
    Set.fromList $
        mapMaybe
            (either (const Nothing) Just . txInFromText . unTxInRef)
            refs
  where
    refs =
        concatMap
            ( \entry ->
                [ sdDeployedAt (teTreasuryScript entry)
                , sdDeployedAt (tePermissionsScript entry)
                , sdDeployedAt (teRegistryScript entry)
                ]
            )
            (Map.elems (requestedTreasuries metadata requested))

extractReferenceScripts
    :: Map TxIn (TxOut ConwayEra)
    -> Either RegistryWalkError (Map TxInRef Text)
extractReferenceScripts =
    fmap Map.fromList . traverse referenceScriptEntry . Map.toList

referenceScriptEntry
    :: (TxIn, TxOut ConwayEra)
    -> Either RegistryWalkError (TxInRef, Text)
referenceScriptEntry (txIn, txOut) =
    Right
        ( renderTxInRef txIn
        , case txOut ^. referenceScriptTxOutL of
            SJust script ->
                scriptHashToHex (Core.hashScript @ConwayEra script)
            SNothing -> ""
        )

renderAddress :: Addr -> Either RegistryWalkError Text
renderAddress addr = do
    hrp <-
        case Bech32.humanReadablePartFromText
            ( case getNetwork addr of
                Mainnet -> "addr"
                Testnet -> "addr_test"
            ) of
            Right value -> Right value
            Left err ->
                Left $
                    ChainQueryError $
                        "bech32 address prefix: " <> T.pack (show err)
    pure $
        Bech32.encodeLenient
            hrp
            (Bech32.dataPartFromBytes (serialiseAddr addr))

renderTxInRef :: TxIn -> TxInRef
renderTxInRef (TxIn (TxId txIdHash) txIx) =
    TxInRef $
        bytesToHex (hashToBytes (extractHash txIdHash))
            <> "#"
            <> T.pack (show (txIxToInt txIx))

bytesToHex :: ByteString -> Text
bytesToHex =
    TE.decodeUtf8 . B16.encode

requireUnique
    :: Text
    -> Maybe ScopeId
    -> TxInRef
    -> [TxInRef]
    -> Either RegistryWalkError TxInRef
requireUnique field scope fallback refs =
    case refs of
        [] -> Left (AnchorSpent field scope fallback)
        [ref] -> Right ref
        many -> Left (AnchorAmbiguous field scope (unTxInRef <$> many))

assertText
    :: Text
    -> Maybe ScopeId
    -> Text
    -> Text
    -> Either RegistryWalkError ()
assertText field scope expected actual
    | expected == actual = Right ()
    | otherwise =
        Left (AnchorMismatch field scope expected actual)

parseTxInRef
    :: Text
    -> Maybe ScopeId
    -> TxInRef
    -> Either RegistryWalkError TxIn
parseTxInRef field scope (TxInRef ref) =
    mapParseError field scope (txInFromText ref)

parseOwner
    :: Text
    -> Maybe ScopeId
    -> Text
    -> Either RegistryWalkError (KeyHash Witness)
parseOwner field scope =
    mapParseError field scope . keyHashFromHex

parseScriptHash
    :: Text
    -> Maybe ScopeId
    -> Text
    -> Either RegistryWalkError ScriptHash
parseScriptHash field scope =
    mapParseError field scope . scriptHashFromHex

parseAddress
    :: Text
    -> Maybe ScopeId
    -> Text
    -> Either RegistryWalkError Addr
parseAddress field scope =
    mapParseError field scope . addrFromText

mapParseError
    :: Text
    -> Maybe ScopeId
    -> Either String a
    -> Either RegistryWalkError a
mapParseError field scope =
    either
        ( Left
            . ChainQueryError
            . ((fieldLabel field scope <> ": ") <>)
            . T.pack
        )
        Right

fieldLabel :: Text -> Maybe ScopeId -> Text
fieldLabel field = \case
    Nothing -> field
    Just scope -> scopeText scope <> "." <> field

renderOwner :: Maybe Text -> Text
renderOwner = fromMaybe "null"

instance FromJSON RegistryAnchors where
    parseJSON = withObject "RegistryAnchors" $ \o -> do
        ownersRaw <- o .: "owners" :: Parser (Map Text (Maybe Text))
        registriesRaw <-
            o .: "registries" :: Parser (Map Text RegistryNftAnchor)
        referenceScriptsRaw <-
            o .: "reference_scripts" :: Parser (Map Text Text)
        owners <- traverse parseScopeKey (Map.toList ownersRaw)
        registries <- traverse parseScopeKey (Map.toList registriesRaw)
        RegistryAnchors
            <$> o .: "scopes_nft_policy"
            <*> o .: "scopes_nft_matches"
            <*> pure (Map.fromList owners)
            <*> pure (Map.fromList registries)
            <*> pure (Map.mapKeys TxInRef referenceScriptsRaw)

instance FromJSON RegistryNftAnchor where
    parseJSON = withObject "RegistryNftAnchor" $ \o ->
        RegistryNftAnchor
            <$> o .: "matches"
            <*> o .: "treasury_script_hash"
            <*> o .: "registry_script_hash"
            <*> o .: "permissions_script_hash"
            <*> o .: "address"

parseScopeKey
    :: (Text, a)
    -> Parser (ScopeId, a)
parseScopeKey (key, value) =
    case scopeFromText key of
        Right scope -> pure (scope, value)
        Left err -> fail err
