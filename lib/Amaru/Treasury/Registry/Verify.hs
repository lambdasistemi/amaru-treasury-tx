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
    , ToJSON (..)
    , Value
    , object
    , withObject
    , (.:)
    , (.=)
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
import Cardano.Ledger.Hashes (KeyHash (..), ScriptHash, extractHash)
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
        -- registry_script.deployed_at IS the registry NFT UTxO
        -- (inline datum, no reference script). NFT presence is
        -- already enforced via 'requireUnique' on rnaMatches.
        registryScriptRef <-
            parseTxInRef
                "registry_script.deployed_at"
                (Just scope)
                (sdDeployedAt (teRegistryScript entry))

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
        -- Two independent comparisons: metadata's claimed hash vs
        -- chain, and our build-time derivation vs chain. Distinct
        -- labels so a failure pinpoints which side disagreed.
        assertText
            (field <> ".metadata")
            (Just scope)
            (sdHash deployment)
            actual
        assertText
            (field <> ".derived")
            (Just scope)
            (scriptHashToHex expected)
            actual
        parseTxInRef field (Just scope) (sdDeployedAt deployment)

    ownerEntry (scope, Just ownerHex) =
        do
            owner <- parseOwner "owner" (Just scope) ownerHex
            pure (scope, owner)
    ownerEntry (_scope, Nothing) =
        Left (ChainQueryError "verified owner map cannot contain null owner")

    -- The metadata's @deployed_at@ string is normalised through
    -- 'TxIn' parsing to absorb leading-zero @#00@ vs @#0@ casing
    -- mismatches between metadata and on-chain rendering.
    lookupReferenceScript field scope ref = do
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

{- | Verify a local metadata snapshot against on-chain anchors.
The set of requested scopes must be non-empty: callers passing an
empty set are almost always a bug, not a request to verify the
entire metadata. Use 'Set.fromList allScopeIds' explicitly to
opt into a full sweep.
-}
verifyRegistry
    :: Provider IO
    -> FilePath
    -> Set ScopeId
    -> IO (Either RegistryWalkError VerifiedRegistry)
verifyRegistry _ _ scopes
    | Set.null scopes =
        pure $
            Left
                ( ChainQueryError
                    "verifyRegistry: empty scope set; pass an explicit Set ScopeId"
                )
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
            case parseRegistryRefs metadata requested of
                Left err -> pure (Left err)
                Right registryRefs -> do
                    scopesRef <-
                        either (pure . Left) (fmap Right . fetchScopes) $
                            parseTxInRef
                                "scope_owners"
                                Nothing
                                (umScopeOwners metadata)
                    case scopesRef of
                        Left err -> pure (Left err)
                        Right (scopesTxIn, fetched) ->
                            pure $
                                buildAnchors
                                    network
                                    scopesPolicy
                                    scopePlans
                                    scopesTxIn
                                    registryRefs
                                    fetched
  where
    fetchScopes scopesTxIn =
        withAcquired provider $ \handle -> do
            utxos <-
                queryUTxOByTxInH handle $
                    Set.insert scopesTxIn $
                        deploymentRefs metadata requested
            pure (scopesTxIn, utxos)

    buildAnchors
        network
        scopesPolicy
        scopePlans
        scopesTxIn
        registryRefs
        fetched =
            do
                owners <-
                    extractScopeOwners
                        scopesPolicy
                        scopesTxIn
                        fetched
                registries <-
                    Map.fromList
                        <$> traverse
                            (extractRegistryAnchor network scopePlans fetched)
                            registryRefs
                references <- extractReferenceScripts fetched
                pure
                    RegistryAnchors
                        { raScopesNftPolicy = scriptHashToHex scopesPolicy
                        , raScopesNftMatches =
                            renderTxInRef
                                <$> nftMatches
                                    scopesPolicy
                                    scopesTokenName
                                    scopesTxIn
                                    fetched
                        , raOwners = owners
                        , raRegistries = registries
                        , raReferenceScripts = references
                        }

parseRegistryRefs
    :: UpstreamMetadata
    -> Set ScopeId
    -> Either RegistryWalkError [(ScopeId, TxIn)]
parseRegistryRefs metadata requested =
    traverse parseEntry $
        Map.toList (requestedTreasuries metadata requested)
  where
    parseEntry (scope, entry) =
        fmap
            (scope,)
            ( parseTxInRef
                "registry_script.deployed_at"
                (Just scope)
                (sdDeployedAt (teRegistryScript entry))
            )

-- | Single-element match list when the named UTxO holds the NFT.
nftMatches
    :: ScriptHash
    -> ByteString
    -> TxIn
    -> Map TxIn (TxOut ConwayEra)
    -> [TxIn]
nftMatches policy tokenName txIn fetched =
    case Map.lookup txIn fetched of
        Just txOut | hasNft policy tokenName txOut -> [txIn]
        _ -> []

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

{- | Build the per-scope treasury address from its script hash.
Upstream's deployment recipe (@journal/2026/treasury.sh@) gives
each treasury an address whose payment AND staking credentials
are both the treasury script itself — i.e.
@addr1x<treasury_hash><treasury_hash>@. Using any other stake
reference would produce a different bech32 string and the
@address@ field check in 'verifyWithAnchors' would refuse the
metadata.
-}
scriptAddress :: Network -> ScriptHash -> Addr
scriptAddress network scriptHash =
    Addr
        network
        (ScriptHashObj scriptHash)
        (StakeRefBase (ScriptHashObj scriptHash))

hasNft :: ScriptHash -> ByteString -> TxOut ConwayEra -> Bool
hasNft policy tokenName txOut =
    lookupMultiAsset
        (PolicyID policy)
        (AssetName (SBS.toShort tokenName))
        (txOut ^. valueTxOutL)
        == 1

extractScopeOwners
    :: ScriptHash
    -> TxIn
    -> Map TxIn (TxOut ConwayEra)
    -> Either RegistryWalkError (Map ScopeId (Maybe Text))
extractScopeOwners policy scopesTxIn fetched =
    case Map.lookup scopesTxIn fetched of
        Just txOut
            | hasNft policy scopesTokenName txOut ->
                parseOwnersDatum
                    =<< inlineDatum "scope_owners" Nothing txOut
        _ -> Right Map.empty

{- | The on-chain Scopes NFT datum is the @Scopes@ constructor with
exactly four 'Signature' fields (one per budget scope). 'Contingency'
is metadata-only — it has a @null@ owner, no on-chain owner slot —
so we deliberately do NOT include it here. If upstream ever rotates
the seed and adds a fifth field, this match will surface as
@ChainQueryError@; bump it together with the seed pin in
@Amaru.Treasury.Registry.Constants@.
-}
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
    -> Map TxIn (TxOut ConwayEra)
    -> (ScopeId, TxIn)
    -> Either RegistryWalkError (ScopeId, RegistryNftAnchor)
extractRegistryAnchor network plans fetched (scope, registryTxIn) = do
    plan <-
        maybe
            ( Left
                (ChainQueryError ("missing registry plan: " <> scopeText scope))
            )
            Right
            (findPlan scope plans)
    let matches =
            nftMatches
                (sapRegistryPolicy plan)
                registryTokenName
                registryTxIn
                fetched
    (treasuryHashText, addressText) <-
        case matches of
            [_] -> do
                txOut <-
                    maybe
                        (Left (ChainQueryError "registry_nft: missing utxo"))
                        Right
                        (Map.lookup registryTxIn fetched)
                hashText <-
                    extractRegistryTreasuryHash scope
                        =<< inlineDatum "registry_nft" (Just scope) txOut
                assertText
                    "treasury_script.hash"
                    (Just scope)
                    (scriptHashToHex (sapTreasuryHash plan))
                    hashText
                treasuryHash <-
                    parseScriptHash
                        "treasury_script.hash"
                        (Just scope)
                        hashText
                pure
                    ( hashText
                    , renderAddressUnchecked
                        (scriptAddress network treasuryHash)
                    )
            _ -> Right ("", "")
    pure
        ( scope
        , RegistryNftAnchor
            { rnaMatches = renderTxInRef <$> matches
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

{- | Bech32 render the address using the prefix derived from its
network discriminator. The prefix is always one of @addr@ or
@addr_test@, so 'humanReadablePartFromText' cannot fail in practice.
-}
renderAddressUnchecked :: Addr -> Text
renderAddressUnchecked addr =
    Bech32.encodeLenient
        ( either (error "renderAddressUnchecked: prefix") id $
            Bech32.humanReadablePartFromText (addrPrefix addr)
        )
        (Bech32.dataPartFromBytes (serialiseAddr addr))

addrPrefix :: Addr -> Text
addrPrefix addr = case getNetwork addr of
    Mainnet -> "addr"
    Testnet -> "addr_test"

renderTxIn :: TxIn -> Text
renderTxIn = unTxInRef . renderTxInRef

renderKeyHashWitness :: KeyHash Witness -> Text
renderKeyHashWitness (KeyHash h) =
    TE.decodeUtf8 (B16.encode (hashToBytes h))

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

{- | Mirrors the upstream @metadata.json@ schema so a reviewer can
diff "claimed in metadata" against "verified on chain" side by side.
Only the verified fields are emitted (no @budget@ — the verifier
does not bind it).
-}
instance ToJSON VerifiedRegistry where
    toJSON vr =
        object
            [ "scope_owners" .= renderTxIn (vrScopesNftUtxo vr)
            , "treasuries"
                .= Map.fromList
                    [ ( scopeText scope
                      , verifiedScopeJson scope (vrOwners vr) vs
                      )
                    | (scope, vs) <-
                        Map.toList (vrTreasuriesByScope vr)
                    ]
            ]

verifiedScopeJson
    :: ScopeId
    -> Map ScopeId (KeyHash Witness)
    -> VerifiedScope
    -> Value
verifiedScopeJson scope owners vs =
    object
        [ "owner"
            .= fmap renderKeyHashWitness (Map.lookup scope owners)
        , "address" .= renderAddressUnchecked (vsAddress vs)
        , "treasury_script"
            .= scriptDeploymentJson
                (vsTreasuryScriptHash vs)
                (vsTreasuryDeployedAt vs)
        , "permissions_script"
            .= scriptDeploymentJson
                (vsPermissionsScriptHash vs)
                (vsPermissionsDeployedAt vs)
        , "registry_script"
            .= scriptDeploymentJson
                (vsRegistryScriptHash vs)
                (vsRegistryDeployedAt vs)
        ]

scriptDeploymentJson :: ScriptHash -> TxIn -> Value
scriptDeploymentJson hash deployedAt =
    object
        [ "hash" .= scriptHashToHex hash
        , "deployed_at" .= renderTxIn deployedAt
        ]
