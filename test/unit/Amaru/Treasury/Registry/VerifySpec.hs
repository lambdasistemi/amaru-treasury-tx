{- |
Module      : Amaru.Treasury.Registry.VerifySpec
Description : Mutation tests for registry anchor verification
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0
-}
module Amaru.Treasury.Registry.VerifySpec (spec) where

import Data.Aeson (eitherDecodeFileStrict)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Function ((&))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as TE
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldSatisfy
    )

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts
    ( fromPlutusScript
    , mkPlutusScript
    )
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core (Script)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    , multiAssetFromList
    )
import Cardano.Ledger.Plutus.Data (mkInlineDatum)
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV3)
    , Plutus (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Lens.Micro ((.~))
import PlutusCore.Data (Data (..))

import Amaru.Treasury.Backend
    ( Provider (..)
    , singleShotWithAcquired
    )
import Amaru.Treasury.LedgerParse
    ( scriptHashFromHex
    , txInFromText
    )
import Amaru.Treasury.Registry.Constants
    ( registryTokenName
    , scopesTokenName
    )
import Amaru.Treasury.Registry.Derive
    ( derivedPermissionsScriptBlob
    , derivedRegistryNftPolicy
    , derivedRegistryNftPolicyBlob
    , derivedScopesNftPolicy
    , derivedTreasuryScriptBlob
    )
import Amaru.Treasury.Registry.Metadata
    ( RegistryWalkError (..)
    , ScriptDeployment (..)
    , TreasuryEntry (..)
    , TxInRef (..)
    , UpstreamMetadata (..)
    , readUpstreamMetadataFile
    )
import Amaru.Treasury.Registry.Verify
    ( RegistryAnchors (..)
    , RegistryNftAnchor (..)
    , verifyRegistry
    , verifyWithAnchors
    )
import Amaru.Treasury.Scope
    ( ScopeId
        ( CoreDevelopment
        , Middleware
        , NetworkCompliance
        , OpsAndUseCases
        )
    )

spec :: Spec
spec =
    describe "Amaru.Treasury.Registry.Verify" $ do
        it "accepts metadata whose claims match all anchors" $ do
            metadata <- loadMetadata
            anchors <- loadAnchors
            verifyWithAnchors
                metadata
                anchors
                (Set.singleton CoreDevelopment)
                `shouldSatisfy` isRight

        it "accepts metadata whose live Provider anchors match" $ do
            metadata <- loadMetadata
            provider <- liveProvider metadata
            result <-
                verifyRegistry
                    provider
                    "test/fixtures/registry-walk/metadata.json"
                    (Set.singleton CoreDevelopment)
            result `shouldSatisfy` isRight

        it "rejects owner tampering" $ do
            metadata <-
                mutateCore
                    (\entry -> entry{teOwner = Just badHash})
                    <$> loadMetadata
            expectMismatch "owner" =<< run metadata

        it "rejects treasury script hash tampering" $ do
            metadata <-
                mutateCore
                    ( \entry ->
                        entry
                            { teTreasuryScript =
                                (teTreasuryScript entry)
                                    { sdHash = badHash
                                    }
                            }
                    )
                    <$> loadMetadata
            expectMismatch "treasury_script.hash" =<< run metadata

        it "rejects registry script hash tampering" $ do
            metadata <-
                mutateCore
                    ( \entry ->
                        entry
                            { teRegistryScript =
                                (teRegistryScript entry)
                                    { sdHash = badHash
                                    }
                            }
                    )
                    <$> loadMetadata
            expectMismatch "registry_script.hash" =<< run metadata

        it "rejects permissions script hash tampering" $ do
            metadata <-
                mutateCore
                    ( \entry ->
                        entry
                            { tePermissionsScript =
                                (tePermissionsScript entry)
                                    { sdHash = badHash
                                    }
                            }
                    )
                    <$> loadMetadata
            expectMismatch "permissions_script.hash" =<< run metadata

        it "rejects address tampering" $ do
            metadata <-
                mutateCore
                    ( \entry ->
                        entry
                            { teAddress =
                                "addr_test1vzqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqql3zc5q"
                            }
                    )
                    <$> loadMetadata
            expectMismatch "address" =<< run metadata

        it "rejects a spent treasury_script.deployed_at" $ do
            metadata <- loadMetadata
            anchors <-
                removeReference
                    (sdDeployedAt . teTreasuryScript)
                    <$> loadAnchors
            verify metadata anchors `shouldSatisfy` isSpent

        it "rejects a wrong reference script at treasury_script.deployed_at" $ do
            metadata <- loadMetadata
            anchors <-
                overwriteReference
                    (sdDeployedAt . teTreasuryScript)
                    badHash
                    <$> loadAnchors
            expectMismatch "treasury_script.deployed_at.metadata" $
                verify metadata anchors

        it "rejects a spent permissions_script.deployed_at" $ do
            metadata <- loadMetadata
            anchors <-
                removeReference
                    (sdDeployedAt . tePermissionsScript)
                    <$> loadAnchors
            verify metadata anchors `shouldSatisfy` isSpent

        it
            "rejects a wrong reference script at permissions_script.deployed_at"
            $ do
                metadata <- loadMetadata
                anchors <-
                    overwriteReference
                        (sdDeployedAt . tePermissionsScript)
                        badHash
                        <$> loadAnchors
                expectMismatch "permissions_script.deployed_at.metadata" $
                    verify metadata anchors

        it "rejects a spent registry NFT" $ do
            metadata <- loadMetadata
            anchors <-
                mutateRegistryAnchor
                    (\anchor -> anchor{rnaMatches = []})
                    <$> loadAnchors
            verify metadata anchors `shouldSatisfy` isSpent

        it "rejects ambiguous registry NFT anchors" $ do
            metadata <- loadMetadata
            anchors <-
                mutateRegistryAnchor
                    ( \anchor ->
                        anchor
                            { rnaMatches =
                                rnaMatches anchor
                                    <> [ TxInRef
                                            "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff#0"
                                       ]
                            }
                    )
                    <$> loadAnchors
            verify metadata anchors `shouldSatisfy` isAmbiguous

loadMetadata :: IO UpstreamMetadata
loadMetadata = do
    result <-
        readUpstreamMetadataFile
            "test/fixtures/registry-walk/metadata.json"
    case result of
        Right metadata -> pure metadata
        Left err ->
            expectationFailure ("metadata fixture failed: " <> show err)
                *> error "unreachable"

loadAnchors :: IO RegistryAnchors
loadAnchors = do
    result <-
        eitherDecodeFileStrict
            "test/fixtures/registry-walk/anchors.json"
    case result of
        Right anchors -> pure anchors
        Left err ->
            expectationFailure ("anchors fixture failed: " <> err)
                *> error "unreachable"

liveProvider :: UpstreamMetadata -> IO (Provider IO)
liveProvider metadata = do
    let entry = coreEntryFrom metadata
    scopesPolicy <- orFail "scopes policy" derivedScopesNftPolicy
    registryPolicy <-
        orFail
            "registry policy"
            (derivedRegistryNftPolicy CoreDevelopment)
    treasuryHash <-
        orFail
            "treasury hash"
            (scriptHashFromHex (sdHash (teTreasuryScript entry)))

    scopesRef <- parseFixtureTxIn (umScopeOwners metadata)
    registryRef <-
        parseFixtureTxIn (sdDeployedAt (teRegistryScript entry))
    treasuryRef <-
        parseFixtureTxIn (sdDeployedAt (teTreasuryScript entry))
    permissionsRef <-
        parseFixtureTxIn (sdDeployedAt (tePermissionsScript entry))

    treasuryScript <-
        scriptFromBlob
            =<< orFail
                "treasury script"
                (derivedTreasuryScriptBlob CoreDevelopment)
    permissionsScript <-
        scriptFromBlob
            =<< orFail
                "permissions script"
                (derivedPermissionsScriptBlob CoreDevelopment)
    registryScript <-
        scriptFromBlob
            =<< orFail
                "registry script"
                (derivedRegistryNftPolicyBlob CoreDevelopment)

    let scopesAddr = scriptAddr Mainnet scopesPolicy
        registryAddr = scriptAddr Mainnet registryPolicy
        refAddr = scriptAddr Mainnet treasuryHash
        scopesOut =
            nftTxOut
                scopesAddr
                scopesPolicy
                scopesTokenName
                (ownersDatum metadata)
        registryOut =
            nftTxOut
                registryAddr
                registryPolicy
                registryTokenName
                (registryDatum entry)
                & referenceScriptTxOutL .~ SJust registryScript
        treasuryOut = refScriptTxOut refAddr treasuryScript
        permissionsOut = refScriptTxOut refAddr permissionsScript
        byTxIn =
            Map.fromList
                [ (scopesRef, scopesOut)
                , (treasuryRef, treasuryOut)
                , (permissionsRef, permissionsOut)
                , (registryRef, registryOut)
                ]
        provider =
            Provider
                { withAcquired = singleShotWithAcquired provider
                , queryUTxOs = \_ -> pure []
                , queryUTxOByTxIn =
                    pure . Map.restrictKeys byTxIn
                , queryProtocolParams = fail "unused queryProtocolParams"
                , queryLedgerSnapshot = fail "unused queryLedgerSnapshot"
                , queryStakeRewards = \_ ->
                    fail "unused queryStakeRewards"
                , queryRewardAccounts = \_ ->
                    fail "unused queryRewardAccounts"
                , queryVoteDelegatees = \_ ->
                    fail "unused queryVoteDelegatees"
                , queryTreasury = fail "unused queryTreasury"
                , queryGovernanceState =
                    fail "unused queryGovernanceState"
                , evaluateTx = \_ -> fail "unused evaluateTx"
                , posixMsToSlot = \_ -> fail "unused posixMsToSlot"
                , posixMsCeilSlot = \_ -> fail "unused posixMsCeilSlot"
                , queryUpperBoundSlot = \_ ->
                    fail "unused queryUpperBoundSlot"
                }
    pure provider

ownersDatum :: UpstreamMetadata -> Data
ownersDatum metadata =
    Constr 0 $
        ownerSignature
            <$> [ CoreDevelopment
                , OpsAndUseCases
                , NetworkCompliance
                , Middleware
                ]
  where
    ownerSignature scope =
        Constr
            0
            [ B $
                decodeHexFixture $
                    fromJust $
                        teOwner $
                            coreEntryFor scope metadata
            ]

registryDatum :: TreasuryEntry -> Data
registryDatum entry =
    Constr
        0
        [ scriptCredential (sdHash (teTreasuryScript entry))
        , scriptCredential (TE.decodeUtf8 (B16.encode (BS.replicate 28 0)))
        ]

scriptCredential :: Text -> Data
scriptCredential =
    Constr 1 . pure . B . decodeHexFixture

nftTxOut
    :: Addr
    -> ScriptHash
    -> ByteString
    -> Data
    -> TxOut ConwayEra
nftTxOut addr policy tokenName datum =
    mkBasicTxOut
        addr
        ( MaryValue
            (Coin 2_000_000)
            ( multiAssetFromList
                [
                    ( PolicyID policy
                    , AssetName (SBS.toShort tokenName)
                    , 1
                    )
                ]
            )
        )
        & datumTxOutL .~ mkInlineDatum @ConwayEra datum

refScriptTxOut
    :: Addr
    -> Script ConwayEra
    -> TxOut ConwayEra
refScriptTxOut addr script =
    mkBasicTxOut addr (MaryValue (Coin 2_000_000) (MultiAsset Map.empty))
        & referenceScriptTxOutL .~ SJust script

scriptAddr :: Network -> ScriptHash -> Addr
scriptAddr network scriptHash =
    Addr
        network
        (ScriptHashObj scriptHash)
        (StakeRefBase (ScriptHashObj scriptHash))

scriptFromBlob :: ByteString -> IO (Script ConwayEra)
scriptFromBlob blob =
    case mkPlutusScript plutus of
        Just script -> pure (fromPlutusScript script)
        Nothing ->
            expectationFailure "failed to build Plutus script"
                *> error "unreachable"
  where
    plutus =
        Plutus @PlutusV3 (PlutusBinary (SBS.toShort blob))

parseFixtureTxIn :: TxInRef -> IO TxIn
parseFixtureTxIn (TxInRef ref) =
    orFail "txin" (txInFromText ref)

coreEntryFor :: ScopeId -> UpstreamMetadata -> TreasuryEntry
coreEntryFor scope metadata =
    fromJust $ Map.lookup scope (umTreasuries metadata)

coreEntryFrom :: UpstreamMetadata -> TreasuryEntry
coreEntryFrom =
    coreEntryFor CoreDevelopment

decodeHexFixture :: Text -> ByteString
decodeHexFixture text =
    case B16.decode (TE.encodeUtf8 text) of
        Right bytes -> bytes
        Left err -> error ("invalid fixture hex: " <> err)

orFail :: String -> Either String a -> IO a
orFail label =
    either
        ( \err ->
            expectationFailure (label <> " failed: " <> err)
                *> error "unreachable"
        )
        pure

run
    :: UpstreamMetadata
    -> IO (Either RegistryWalkError ())
run metadata =
    verify metadata <$> loadAnchors

verify
    :: UpstreamMetadata
    -> RegistryAnchors
    -> Either RegistryWalkError ()
verify metadata anchors =
    case verifyWithAnchors
        metadata
        anchors
        (Set.singleton CoreDevelopment) of
        Right _ -> Right ()
        Left err -> Left err

mutateCore
    :: (TreasuryEntry -> TreasuryEntry)
    -> UpstreamMetadata
    -> UpstreamMetadata
mutateCore f metadata =
    metadata
        { umTreasuries =
            Map.adjust f CoreDevelopment (umTreasuries metadata)
        }

mutateRegistryAnchor
    :: (RegistryNftAnchor -> RegistryNftAnchor)
    -> RegistryAnchors
    -> RegistryAnchors
mutateRegistryAnchor f anchors =
    anchors
        { raRegistries =
            Map.adjust f CoreDevelopment (raRegistries anchors)
        }

removeReference
    :: (TreasuryEntry -> TxInRef)
    -> RegistryAnchors
    -> RegistryAnchors
removeReference select anchors =
    anchors
        { raReferenceScripts =
            Map.delete
                (select coreEntry)
                (raReferenceScripts anchors)
        }

overwriteReference
    :: (TreasuryEntry -> TxInRef)
    -> Text
    -> RegistryAnchors
    -> RegistryAnchors
overwriteReference select scriptHash anchors =
    anchors
        { raReferenceScripts =
            Map.insert
                (select coreEntry)
                scriptHash
                (raReferenceScripts anchors)
        }

coreEntry :: TreasuryEntry
coreEntry =
    fromJust $
        Map.lookup
            CoreDevelopment
            (umTreasuries fixtureMetadata)

fixtureMetadata :: UpstreamMetadata
fixtureMetadata =
    UpstreamMetadata
        { umScopeOwners =
            TxInRef
                "11ace24a7b0caad4a68a38ef2fff18185dc9ea604e84425dab487cae94e4cf54#00"
        , umTreasuries =
            Map.singleton
                CoreDevelopment
                TreasuryEntry
                    { teOwner =
                        Just
                            "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
                    , teAddress =
                        "addr1x90mk0jjjhppr36ethwj8kewpgyrxyc7q6qucl4gqru96dzlhvl999wzz8r4jhway0djuzsgxvf3up5pe3l2sq8ct56qtjz6ah"
                    , teTreasuryScript =
                        ScriptDeployment
                            "5fbb3e5295c211c7595ddd23db2e0a0833131e0681cc7ea800f85d34"
                            ( TxInRef
                                "87ee53271fb41021efa13c2dbe2998c18ead07d32a6ab6dda184853ed7e39aae#00"
                            )
                    , tePermissionsScript =
                        ScriptDeployment
                            "03ee9cf951e89fb82c47edbff562ee90be17de85b2c24b451c7e8e39"
                            ( TxInRef
                                "25ba96f5deb14bb5c56e7542d6a9ba8450f52cc698ebd74574e1a0525d861095#00"
                            )
                    , teRegistryScript =
                        ScriptDeployment
                            "1e1ee91b8e2bddc9d583d92fd1ba5ea47b8a3e62c1eacb0ec799b99b"
                            ( TxInRef
                                "e7b395a93d49a17994d66df0e4778a01dee05e7711e6612f28d97b63e4e6311c#00"
                            )
                    }
        }

expectMismatch
    :: Text
    -> Either RegistryWalkError ()
    -> IO ()
expectMismatch field result =
    result `shouldSatisfy` \case
        Left (AnchorMismatch actual (Just CoreDevelopment) _ _) ->
            actual == field
        _ -> False

isRight :: Either RegistryWalkError a -> Bool
isRight = \case
    Right _ -> True
    _ -> False

isSpent :: Either RegistryWalkError a -> Bool
isSpent = \case
    Left AnchorSpent{} -> True
    _ -> False

isAmbiguous :: Either RegistryWalkError a -> Bool
isAmbiguous = \case
    Left AnchorAmbiguous{} -> True
    _ -> False

badHash :: Text
badHash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
