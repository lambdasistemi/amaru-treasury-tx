{- |
Module      : Amaru.Treasury.Devnet.RegistryInitSpec
Description : Unit tests for DevNet registry publication projections
License     : Apache-2.0
-}
module Amaru.Treasury.Devnet.RegistryInitSpec (spec) where

import Cardano.Ledger.Address
    ( Addr
    , getNetwork
    , serialiseAddr
    )
import Cardano.Ledger.BaseTypes (Network (..), txIxToInt)
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Codec.Binary.Bech32 qualified as Bech32
import Control.Exception (bracket)
import Data.Aeson
    ( object
    , (.=)
    )
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import System.Directory
    ( createDirectory
    , doesDirectoryExist
    , doesFileExist
    , getTemporaryDirectory
    , removeDirectoryRecursive
    )
import System.FilePath ((</>))
import Test.Hspec
    ( Spec
    , describe
    , expectationFailure
    , it
    , shouldBe
    )

import Amaru.Treasury.Devnet.RegistryInit
    ( BootstrapArtifactArgs (..)
    , DevnetBootstrapArtifactInputs (..)
    , DevnetRegistryAnchors (..)
    , DevnetRegistryPublication (..)
    , TreasuryTarget (..)
    , bootstrapDevnetPublication
    , devnetRegistryView
    , registryInitDirectory
    , registryInitProvenancePath
    , registryInitProvenanceValue
    , registryInitRegistryPath
    , registryInitRegistryValue
    , registryInitSummaryPath
    , registryInitSummaryValue
    , runBootstrapWriter
    , treasuryTargetFromBlob
    , validateBootstrapArgs
    , withdrawalRegistryPath
    , withdrawalRegistryValue
    )
import Amaru.Treasury.LedgerParse
    ( scriptHashFromHex
    , txInFromText
    )
import Amaru.Treasury.Registry.Constants
    ( treasuryValidatorBlob
    )
import Amaru.Treasury.Scope
    ( ScopeId (CoreDevelopment)
    )
import Amaru.Treasury.Tx.SwapWizard
    ( ScopeOwners (..)
    )
import Amaru.Treasury.Tx.WithdrawWizard qualified as Withdraw

spec :: Spec
spec =
    describe "Amaru.Treasury.Devnet.RegistryInit" $ do
        it "renders the withdrawal registry artifact path" $
            withdrawalRegistryPath sampleRunDir
                `shouldBe` sampleRunDir </> "withdraw" </> "registry.json"

        it "renders the registry-init artifact paths" $ do
            registryInitSummaryPath sampleRunDir
                `shouldBe` sampleRunDir
                    </> "registry-init"
                    </> "summary.json"
            registryInitRegistryPath sampleRunDir
                `shouldBe` sampleRunDir
                    </> "registry-init"
                    </> "registry.json"
            registryInitProvenancePath sampleRunDir
                `shouldBe` sampleRunDir
                    </> "registry-init"
                    </> "provenance.json"

        it "renders registry-init summary and registry artifact fields" $ do
            publication <- sampleRegistryPublication
            let registry =
                    drpAnchors publication
            registryInitSummaryValue 42 sampleRunDir publication
                `shouldBe` object
                    [ "phase" .= ("registry-init" :: T.Text)
                    , "network" .= ("devnet" :: T.Text)
                    , "networkMagic" .= (42 :: Int)
                    , "seedSplitTxId" .= sampleSeedSplitTxId
                    , "registryMintTxId" .= sampleRegistryMintTxId
                    , "referenceScriptsTxId"
                        .= sampleReferenceScriptsTxId
                    , "registryPath" .= registryInitRegistryPath sampleRunDir
                    , "provenancePath"
                        .= registryInitProvenancePath sampleRunDir
                    ]
            registryInitRegistryValue publication
                `shouldBe` object
                    [ "phase" .= ("registry-init" :: T.Text)
                    , "network" .= ("devnet" :: T.Text)
                    , "anchors"
                        .= object
                            [ "scopesDeployedAt" .= sampleScopesRefText
                            , "registryDeployedAt"
                                .= sampleRegistryRefText
                            , "permissionsDeployedAt"
                                .= samplePermissionsRefText
                            , "treasuryDeployedAt"
                                .= sampleTreasuryRefText
                            ]
                    , "policies"
                        .= object
                            [ "scopesPolicyId" .= sampleScopesPolicyId
                            , "registryPolicyId" .= sampleRegistryPolicyId
                            ]
                    , "scripts"
                        .= object
                            [ "permissionsScriptHash"
                                .= samplePermissionsHashText
                            , "treasuryScriptHash"
                                .= ttScriptHashText
                                    (draTreasuryTarget registry)
                            ]
                    , "addresses"
                        .= object
                            [ "treasuryAddress"
                                .= renderAddr
                                    (ttAddress (draTreasuryTarget registry))
                            ]
                    , "owners"
                        .= object
                            [ "scopeOwnerKeyHash" .= sampleOwnerKeyHash
                            ]
                    , "submittedTxIds"
                        .= object
                            [ "seedSplit" .= sampleSeedSplitTxId
                            , "registryMint" .= sampleRegistryMintTxId
                            , "referenceScripts"
                                .= sampleReferenceScriptsTxId
                            ]
                    ]
            registryInitProvenanceValue
                `shouldBe` object
                    [ "phase" .= ("registry-init" :: T.Text)
                    , "source" .= ("amaru-treasury-tx" :: T.Text)
                    , "issue" .= (147 :: Int)
                    , "parentIssue" .= (151 :: Int)
                    ]

        it "renders withdrawal registry artifact fields" $ do
            registry <- sampleRegistryAnchors
            withdrawalRegistryValue registry
                `shouldBe` object
                    [ "scopesDeployedAt" .= sampleScopesRefText
                    , "permissionsDeployedAt" .= samplePermissionsRefText
                    , "permissionsScriptHash"
                        .= samplePermissionsHashText
                    , "treasuryDeployedAt" .= sampleTreasuryRefText
                    , "registryDeployedAt" .= sampleRegistryRefText
                    , "registryPolicyId" .= sampleRegistryPolicyId
                    , "treasuryScriptHash"
                        .= ttScriptHashText
                            (draTreasuryTarget registry)
                    , "treasuryAddress"
                        .= renderAddr
                            (ttAddress (draTreasuryTarget registry))
                    ]

        describe "bootstrap artifact writer (#175 Slice 3)" $ do
            it "validates good args into typed inputs" $ do
                case validateBootstrapArgs sampleBootstrapArgs of
                    Right ins -> do
                        dbaiOwnerKeyHash ins
                            `shouldBe` sampleOwnerKeyHash
                        dbaiNetwork ins `shouldBe` Testnet
                    Left e ->
                        expectationFailure
                            ("expected Right, got Left: " <> e)

            it "rejects a malformed --seed-split-txid (short hex)" $ do
                let args =
                        sampleBootstrapArgs
                            { baaSeedSplitTxId = "abcd"
                            }
                case validateBootstrapArgs args of
                    Left _ -> pure ()
                    Right _ ->
                        expectationFailure
                            "expected Left for short --seed-split-txid"

            it "rejects a malformed --owner-key-hash (55 hex)" $ do
                let args =
                        sampleBootstrapArgs
                            { baaOwnerKeyHash = T.replicate 55 "a"
                            }
                case validateBootstrapArgs args of
                    Left _ -> pure ()
                    Right _ ->
                        expectationFailure
                            "expected Left for short --owner-key-hash"

            it "rejects a malformed --scopes-seed-txin" $ do
                let args =
                        sampleBootstrapArgs
                            { baaScopesSeedTxIn = "not-a-ref"
                            }
                case validateBootstrapArgs args of
                    Left _ -> pure ()
                    Right _ ->
                        expectationFailure
                            "expected Left for malformed --scopes-seed-txin"

            it
                "maps registry-mint and reference-scripts tx ids to the four anchors"
                $ do
                    ins <-
                        either
                            (error . ("validateBootstrapArgs: " <>))
                            pure
                            (validateBootstrapArgs sampleBootstrapArgs)
                    publication <- bootstrapDevnetPublication ins
                    let anchors = drpAnchors publication
                    txInOutputIx (draScopesRef anchors) `shouldBe` 0
                    txIdOf (draScopesRef anchors)
                        `shouldBe` dbaiRegistryMintTxId ins
                    txInOutputIx (draRegistryRef anchors) `shouldBe` 1
                    txIdOf (draRegistryRef anchors)
                        `shouldBe` dbaiRegistryMintTxId ins
                    txInOutputIx (draPermissionsRef anchors) `shouldBe` 0
                    txIdOf (draPermissionsRef anchors)
                        `shouldBe` dbaiReferenceScriptsTxId ins
                    txInOutputIx (draTreasuryRef anchors) `shouldBe` 1
                    txIdOf (draTreasuryRef anchors)
                        `shouldBe` dbaiReferenceScriptsTxId ins
                    draOwnerKeyHash anchors `shouldBe` sampleOwnerKeyHash

            it
                "writes summary/registry/provenance and a top-level summary on devnet"
                $ withScratchDir "regwiz-write-ok-"
                $ \dir -> do
                    res <-
                        runBootstrapWriter
                            "devnet"
                            42
                            dir
                            sampleBootstrapArgs
                    res `shouldBe` Right ()
                    doesFileExist (registryInitSummaryPath dir)
                        >>= (`shouldBe` True)
                    doesFileExist (registryInitRegistryPath dir)
                        >>= (`shouldBe` True)
                    doesFileExist (registryInitProvenancePath dir)
                        >>= (`shouldBe` True)
                    doesFileExist (dir </> "summary.json")
                        >>= (`shouldBe` True)

            it "refuses non-devnet networks and leaves no registry-init dir" $
                withScratchDir "regwiz-write-mainnet-" $ \dir -> do
                    res <-
                        runBootstrapWriter
                            "mainnet"
                            764824073
                            dir
                            sampleBootstrapArgs
                    case res of
                        Left _ -> pure ()
                        Right () ->
                            expectationFailure
                                "expected Left for non-devnet network"
                    doesDirectoryExist (registryInitDirectory dir)
                        >>= (`shouldBe` False)

            it "refuses malformed inputs and leaves no registry-init dir" $
                withScratchDir "regwiz-write-badargs-" $ \dir -> do
                    res <-
                        runBootstrapWriter
                            "devnet"
                            42
                            dir
                            sampleBootstrapArgs
                                { baaOwnerKeyHash = "deadbeef"
                                }
                    case res of
                        Left _ -> pure ()
                        Right () ->
                            expectationFailure
                                "expected Left for malformed owner key hash"
                    doesDirectoryExist (registryInitDirectory dir)
                        >>= (`shouldBe` False)

        it "projects registry anchors into the withdraw registry view" $ do
            registry <- sampleRegistryAnchors
            let target =
                    draTreasuryTarget registry
                treasuryRefs =
                    Withdraw.TreasuryRefs
                        { Withdraw.trAddress =
                            renderAddr (ttAddress target)
                        , Withdraw.trScriptHash =
                            ttScriptHashText target
                        , Withdraw.trPermissionsRewardAccount =
                            samplePermissionsHashText
                        }
                owners =
                    ScopeOwners
                        { soCore = sampleOwnerKeyHash
                        , soOps = sampleOwnerKeyHash
                        , soNetworkCompliance = sampleOwnerKeyHash
                        , soMiddleware = sampleOwnerKeyHash
                        }
            devnetRegistryView registry
                `shouldBe` Withdraw.RegistryView
                    { Withdraw.rvScopesDeployedAt = sampleScopesRefText
                    , Withdraw.rvPermissionsDeployedAt =
                        samplePermissionsRefText
                    , Withdraw.rvTreasuryDeployedAt =
                        sampleTreasuryRefText
                    , Withdraw.rvRegistryDeployedAt =
                        sampleRegistryRefText
                    , Withdraw.rvRegistryPolicyId =
                        sampleRegistryPolicyId
                    , Withdraw.rvOwners = owners
                    , Withdraw.rvTreasuryByScope =
                        Map.singleton CoreDevelopment treasuryRefs
                    }

sampleRunDir :: FilePath
sampleRunDir =
    "runs/devnet/sample"

sampleScopesRefText :: T.Text
sampleScopesRefText =
    "0000000000000000000000000000000000000000000000000000000000000001#0"

samplePermissionsRefText :: T.Text
samplePermissionsRefText =
    "0000000000000000000000000000000000000000000000000000000000000002#1"

sampleTreasuryRefText :: T.Text
sampleTreasuryRefText =
    "0000000000000000000000000000000000000000000000000000000000000003#2"

sampleRegistryRefText :: T.Text
sampleRegistryRefText =
    "0000000000000000000000000000000000000000000000000000000000000004#3"

sampleSeedSplitTxId :: T.Text
sampleSeedSplitTxId =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

sampleRegistryMintTxId :: T.Text
sampleRegistryMintTxId =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

sampleReferenceScriptsTxId :: T.Text
sampleReferenceScriptsTxId =
    "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"

samplePermissionsHashText :: T.Text
samplePermissionsHashText =
    "11111111111111111111111111111111111111111111111111111111"

sampleScopesPolicyId :: T.Text
sampleScopesPolicyId =
    "44444444444444444444444444444444444444444444444444444444"

sampleRegistryPolicyId :: T.Text
sampleRegistryPolicyId =
    "22222222222222222222222222222222222222222222222222222222"

sampleOwnerKeyHash :: T.Text
sampleOwnerKeyHash =
    "33333333333333333333333333333333333333333333333333333333"

sampleRegistryPublication :: IO DevnetRegistryPublication
sampleRegistryPublication = do
    registry <- sampleRegistryAnchors
    seedSplitTxId <- parseTxId sampleSeedSplitTxId
    registryMintTxId <- parseTxId sampleRegistryMintTxId
    referenceScriptsTxId <- parseTxId sampleReferenceScriptsTxId
    pure
        DevnetRegistryPublication
            { drpSeedSplitTxId = seedSplitTxId
            , drpRegistryMintTxId = registryMintTxId
            , drpReferenceScriptsTxId = referenceScriptsTxId
            , drpAnchors = registry
            }

sampleRegistryAnchors :: IO DevnetRegistryAnchors
sampleRegistryAnchors = do
    target <- treasuryTargetFromBlob Testnet treasuryValidatorBlob
    scopesRef <- parse "scopes ref" txInFromText sampleScopesRefText
    permissionsRef <-
        parse "permissions ref" txInFromText samplePermissionsRefText
    treasuryRef <- parse "treasury ref" txInFromText sampleTreasuryRefText
    registryRef <- parse "registry ref" txInFromText sampleRegistryRefText
    permissionsHash <-
        parse "permissions hash" scriptHashFromHex samplePermissionsHashText
    pure
        DevnetRegistryAnchors
            { draScopesRef = scopesRef
            , draPermissionsRef = permissionsRef
            , draTreasuryRef = treasuryRef
            , draRegistryRef = registryRef
            , draScopesPolicyId = sampleScopesPolicyId
            , draRegistryPolicyId = sampleRegistryPolicyId
            , draPermissionsHash = permissionsHash
            , draOwnerKeyHash = sampleOwnerKeyHash
            , draTreasuryTarget = target
            }

parseTxId :: T.Text -> IO TxId
parseTxId txIdText = do
    TxIn txId _ <- parse "tx id" txInFromText (txIdText <> "#0")
    pure txId

parse :: String -> (T.Text -> Either String a) -> T.Text -> IO a
parse label parser input =
    case parser input of
        Left err ->
            expectationFailure (label <> ": " <> err)
                *> error "unreachable"
        Right ok -> pure ok

renderAddr :: Addr -> T.Text
renderAddr addr =
    Bech32.encodeLenient
        hrp
        (Bech32.dataPartFromBytes (serialiseAddr addr))
  where
    hrp =
        either
            (error . ("renderAddr: " <>) . show)
            id
            (Bech32.humanReadablePartFromText (addressHrp addr))
    addressHrp target =
        case getNetwork target of
            Mainnet -> "addr"
            Testnet -> "addr_test"

-- ----------------------------------------------------
-- Slice 3 (#175) — bootstrap artifact writer fixtures
-- ----------------------------------------------------

{- | Two distinct 64-hex tx ids used so the anchor mapping is
  pin-tested per submitted transaction.
-}
sampleSeedSplitArtifactTxId :: T.Text
sampleSeedSplitArtifactTxId = T.replicate 64 "1"

sampleRegistryMintArtifactTxId :: T.Text
sampleRegistryMintArtifactTxId = T.replicate 64 "2"

sampleReferenceScriptsArtifactTxId :: T.Text
sampleReferenceScriptsArtifactTxId = T.replicate 64 "3"

sampleScopesSeedRefText :: T.Text
sampleScopesSeedRefText =
    T.replicate 64 "4" <> "#0"

sampleRegistrySeedRefText :: T.Text
sampleRegistrySeedRefText =
    T.replicate 64 "5" <> "#1"

sampleBootstrapArgs :: BootstrapArtifactArgs
sampleBootstrapArgs =
    BootstrapArtifactArgs
        { baaSeedSplitTxId = sampleSeedSplitArtifactTxId
        , baaRegistryMintTxId = sampleRegistryMintArtifactTxId
        , baaReferenceScriptsTxId =
            sampleReferenceScriptsArtifactTxId
        , baaScopesSeedTxIn = sampleScopesSeedRefText
        , baaRegistrySeedTxIn = sampleRegistrySeedRefText
        , baaOwnerKeyHash = sampleOwnerKeyHash
        , baaNetwork = Testnet
        }

txIdOf :: TxIn -> TxId
txIdOf (TxIn tid _) = tid

txInOutputIx :: TxIn -> Int
txInOutputIx (TxIn _ ix) = txIxToInt ix

withScratchDir :: String -> (FilePath -> IO a) -> IO a
withScratchDir prefix action = do
    sysTmp <- getTemporaryDirectory
    let scratch = sysTmp </> (prefix <> "0")
    bracket (mkFresh scratch) removeDirectoryRecursive action
  where
    mkFresh d = do
        exists <- doesDirectoryExist d
        if exists
            then do
                removeDirectoryRecursive d
                createDirectory d
                pure d
            else do
                createDirectory d
                pure d
