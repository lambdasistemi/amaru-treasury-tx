{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.Devnet.RegistryInit
Description : DevNet registry publication and projections
License     : Apache-2.0

Production-backed construction for the local DevNet registry anchors.
The smoke suite supplies the live node, funding address, and signer;
this module owns the reusable transaction construction and artifact
projection.
-}
module Amaru.Treasury.Devnet.RegistryInit
    ( -- * Configuration
      DevnetRegistryInitConfig (..)

      -- * Published anchors
    , TreasuryTarget (..)
    , DevnetScriptSet (..)
    , DevnetRegistryAnchors (..)
    , DevnetRegistryPublication (..)

      -- * Publication
    , prepareDevnetWithdrawalRegistry
    , deployDevnetWithdrawalRegistry
    , publishDevnetRegistryInit
    , deriveDevnetScripts
    , treasuryTargetFromBlob

      -- * Bootstrap artifact writer (#175 Slice 3)
    , BootstrapArtifactArgs (..)
    , DevnetBootstrapArtifactInputs (..)
    , validateBootstrapArgs
    , bootstrapDevnetPublication
    , runBootstrapWriter
    , registryInitDirectory

      -- * Construction cores

    --
    -- \^ Pure-IO transaction builders extracted from the
    -- submitters so the @tx-build@ dispatcher and the live
    -- submitters share one source of truth for the
    -- per-sub-action 'TxBuild' programs. Each returns the
    -- raw unsigned 'ConwayTx' produced by
    -- 'Cardano.Tx.Build.build'; signing, submission, and
    -- waiting remain in the submitters.
    , CoreEvaluator
    , buildSeedSplitCore
    , buildRegistryNftsCore
    , buildReferenceScriptsCore

      -- * Artifacts
    , registryInitSummaryPath
    , registryInitRegistryPath
    , registryInitProvenancePath
    , registryInitSummaryValue
    , registryInitRegistryValue
    , registryInitProvenanceValue
    , registryInitLines
    , registryInitLinesWithPrefix
    , writeRegistryInitArtifacts
    , writeRegistryInitArtifactsWithPrefix
    , writeRegistryInitArtifactsWithLines
    , verifyRegistryInitPublication
    , withdrawalRegistryPath
    , withdrawalRegistryValue
    , writeWithdrawalRegistryArtifacts
    , devnetRegistryView
    ) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address
    ( Addr (..)
    , getNetwork
    , serialiseAddr
    )
import Cardano.Ledger.Alonzo.Scripts
    ( AsIx
    , fromPlutusScript
    , mkPlutusScript
    )
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Inject (..)
    , Network (..)
    , StrictMaybe (..)
    , mkTxIxPartial
    , txIxToInt
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core (PParams, Script)
import Cardano.Ledger.Core qualified as Core
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    , extractHash
    )
import Cardano.Ledger.Keys
    ( KeyRole (Payment)
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    , multiAssetFromList
    )
import Cardano.Ledger.Plutus.Data (mkInlineDatum)
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV3)
    , Plutus (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))
import Cardano.Node.Client.Provider
    ( LedgerSnapshot (..)
    , Provider (..)
    )
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Build
    ( InterpretIO (..)
    , TxBuild
    , attachScript
    , build
    , checkMinUtxo
    , collateral
    , mint
    , mkPParamsBound
    , output
    , payTo
    , spend
    , validTo
    )
import Cardano.Tx.Build qualified as TxBuild
import Cardano.Tx.Ledger (ConwayTx)
import Codec.Binary.Bech32 qualified as Bech32
import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Control.Monad (unless)
import Data.Aeson
    ( Value
    , encode
    , object
    , (.=)
    )
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Function ((&))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Void (Void)
import Data.Word (Word64)
import Lens.Micro
    ( (.~)
    , (^.)
    )
import PlutusCore.Data (Data (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

import Amaru.Treasury.LedgerParse
    ( keyHashFromHex
    , txInFromText
    )
import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , emptyListRedeemer
    )
import Amaru.Treasury.Registry.Constants
    ( payoutUpperbound
    , permissionsValidatorBlob
    , registryTokenName
    , scopesTokenName
    , scopesValidatorBlob
    , treasuryExpirationMs
    , treasuryRegistryValidatorBlob
    , treasuryValidatorBlob
    )
import Amaru.Treasury.Registry.Derive
    ( ScriptParam (..)
    , applyParams
    , applyScriptParams
    , scriptHashOfBlob
    , scriptHashToHex
    )
import Amaru.Treasury.Scope
    ( ScopeId (..)
    )
import Amaru.Treasury.Tx.Submit (renderTxId)
import Amaru.Treasury.Tx.SwapWizard
    ( ScopeOwners (..)
    , txInToText
    )
import Amaru.Treasury.Tx.WithdrawWizard qualified as Withdraw

data NoCtx a

-- | Live DevNet inputs needed to sign and fund registry transactions.
data DevnetRegistryInitConfig = DevnetRegistryInitConfig
    { dricNetwork :: !Network
    , dricFundingAddress :: !Addr
    , dricOwnerKeyHash :: !(KeyHash Payment)
    , dricSignTx :: !(ConwayTx -> ConwayTx)
    }

-- | Treasury script material derived for the DevNet registry.
data TreasuryTarget = TreasuryTarget
    { ttScript :: !(Script ConwayEra)
    , ttScriptHash :: !ScriptHash
    , ttScriptHashText :: !T.Text
    , ttAddress :: !Addr
    }

-- | Derived policy and script set for one registry publication.
data DevnetScriptSet = DevnetScriptSet
    { dssScopesScript :: !(Script ConwayEra)
    , dssScopesHash :: !ScriptHash
    , dssRegistryScript :: !(Script ConwayEra)
    , dssRegistryHash :: !ScriptHash
    , dssPermissionsScript :: !(Script ConwayEra)
    , dssPermissionsHash :: !ScriptHash
    , dssTreasuryTarget :: !TreasuryTarget
    }

-- | On-chain anchors consumed by withdraw and later DevNet phases.
data DevnetRegistryAnchors = DevnetRegistryAnchors
    { draScopesRef :: !TxIn
    , draPermissionsRef :: !TxIn
    , draTreasuryRef :: !TxIn
    , draRegistryRef :: !TxIn
    , draScopesPolicyId :: !T.Text
    , draRegistryPolicyId :: !T.Text
    , draPermissionsHash :: !ScriptHash
    , draOwnerKeyHash :: !T.Text
    , draTreasuryTarget :: !TreasuryTarget
    }

-- | Submitted transaction ids plus the resulting registry anchors.
data DevnetRegistryPublication = DevnetRegistryPublication
    { drpSeedSplitTxId :: !TxId
    , drpRegistryMintTxId :: !TxId
    , drpReferenceScriptsTxId :: !TxId
    , drpAnchors :: !DevnetRegistryAnchors
    }

{- | Raw operator inputs for materializing registry-init artifacts
after the three bootstrap intent transactions have been submitted.
-}
data BootstrapArtifactArgs = BootstrapArtifactArgs
    { baaSeedSplitTxId :: !T.Text
    , baaRegistryMintTxId :: !T.Text
    , baaReferenceScriptsTxId :: !T.Text
    , baaScopesSeedTxIn :: !T.Text
    , baaRegistrySeedTxIn :: !T.Text
    , baaOwnerKeyHash :: !T.Text
    , baaNetwork :: !Network
    }
    deriving stock (Eq, Show)

-- | Validated bootstrap artifact inputs.
data DevnetBootstrapArtifactInputs = DevnetBootstrapArtifactInputs
    { dbaiSeedSplitTxId :: !TxId
    , dbaiRegistryMintTxId :: !TxId
    , dbaiReferenceScriptsTxId :: !TxId
    , dbaiScopesSeedTxIn :: !TxIn
    , dbaiRegistrySeedTxIn :: !TxIn
    , dbaiOwnerKeyHash :: !T.Text
    , dbaiNetwork :: !Network
    }
    deriving stock (Eq, Show)

{- | Validate the textual write-artifacts arguments before any files
are created.
-}
validateBootstrapArgs
    :: BootstrapArtifactArgs
    -> Either String DevnetBootstrapArtifactInputs
validateBootstrapArgs args = do
    seedSplitTxId <-
        txIdText "seed-split-txid" (baaSeedSplitTxId args)
    registryMintTxId <-
        txIdText "registry-mint-txid" (baaRegistryMintTxId args)
    referenceScriptsTxId <-
        txIdText "reference-scripts-txid" (baaReferenceScriptsTxId args)
    scopesSeedTxIn <-
        parseText "scopes-seed-txin" txInFromText (baaScopesSeedTxIn args)
    registrySeedTxIn <-
        parseText
            "registry-seed-txin"
            txInFromText
            (baaRegistrySeedTxIn args)
    ownerKeyHash <-
        parseText "owner-key-hash" keyHashFromHex (baaOwnerKeyHash args)
    pure
        DevnetBootstrapArtifactInputs
            { dbaiSeedSplitTxId = seedSplitTxId
            , dbaiRegistryMintTxId = registryMintTxId
            , dbaiReferenceScriptsTxId = referenceScriptsTxId
            , dbaiScopesSeedTxIn = scopesSeedTxIn
            , dbaiRegistrySeedTxIn = registrySeedTxIn
            , dbaiOwnerKeyHash = keyHashToText ownerKeyHash
            , dbaiNetwork = baaNetwork args
            }
  where
    txIdText label value = do
        TxIn txId _ <- parseText label txInFromText (value <> "#0")
        pure txId
    parseText label parser value =
        case parser value of
            Left err -> Left (label <> ": " <> err)
            Right ok -> Right ok

{- | Build the registry-init publication projection from submitted tx ids
and seed references. This does not query chain, sign, submit, or build
transactions.
-}
bootstrapDevnetPublication
    :: DevnetBootstrapArtifactInputs -> IO DevnetRegistryPublication
bootstrapDevnetPublication inputs = do
    scripts <-
        deriveDevnetScripts
            (dbaiNetwork inputs)
            (dbaiScopesSeedTxIn inputs)
            (dbaiRegistrySeedTxIn inputs)
    let anchors =
            DevnetRegistryAnchors
                { draScopesRef =
                    txOutRef (dbaiRegistryMintTxId inputs) 0
                , draPermissionsRef =
                    txOutRef (dbaiReferenceScriptsTxId inputs) 0
                , draTreasuryRef =
                    txOutRef (dbaiReferenceScriptsTxId inputs) 1
                , draRegistryRef =
                    txOutRef (dbaiRegistryMintTxId inputs) 1
                , draScopesPolicyId =
                    scriptHashToHex (dssScopesHash scripts)
                , draRegistryPolicyId =
                    scriptHashToHex (dssRegistryHash scripts)
                , draPermissionsHash =
                    dssPermissionsHash scripts
                , draOwnerKeyHash =
                    dbaiOwnerKeyHash inputs
                , draTreasuryTarget =
                    dssTreasuryTarget scripts
                }
    pure
        DevnetRegistryPublication
            { drpSeedSplitTxId = dbaiSeedSplitTxId inputs
            , drpRegistryMintTxId = dbaiRegistryMintTxId inputs
            , drpReferenceScriptsTxId =
                dbaiReferenceScriptsTxId inputs
            , drpAnchors = anchors
            }

{- | Validate, derive, and write the shipped registry-init artifact set.
The DevNet guard and all validation happen before any filesystem write.
-}
runBootstrapWriter
    :: T.Text
    -> Int
    -> FilePath
    -> BootstrapArtifactArgs
    -> IO (Either String ())
runBootstrapWriter networkName networkMagic runDir args =
    if networkName /= "devnet"
        then
            pure
                ( Left
                    ( "write-artifacts is devnet-only, got "
                        <> T.unpack networkName
                    )
                )
        else case validateBootstrapArgs args of
            Left err ->
                pure (Left err)
            Right inputs -> do
                publication <- bootstrapDevnetPublication inputs
                Right
                    <$> writeRegistryInitArtifactsWithPrefix
                        "registry-init-wizard"
                        networkMagic
                        runDir
                        publication

-- | Publish the registry and return the treasury target plus anchors.
prepareDevnetWithdrawalRegistry
    :: DevnetRegistryInitConfig
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (TreasuryTarget, DevnetRegistryAnchors)
prepareDevnetWithdrawalRegistry config provider submitter pp utxos = do
    publication <-
        publishDevnetRegistryInit config provider submitter pp utxos
    let registry =
            drpAnchors publication
    pure (draTreasuryTarget registry, registry)

-- | Publish registry NFTs and reference scripts from live DevNet UTxOs.
deployDevnetWithdrawalRegistry
    :: DevnetRegistryInitConfig
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> IO DevnetRegistryAnchors
deployDevnetWithdrawalRegistry config provider submitter pp utxos =
    drpAnchors
        <$> publishDevnetRegistryInit config provider submitter pp utxos

-- | Publish DevNet registry state and retain submitted transaction ids.
publishDevnetRegistryInit
    :: DevnetRegistryInitConfig
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> [(TxIn, TxOut ConwayEra)]
    -> IO DevnetRegistryPublication
publishDevnetRegistryInit config provider submitter pp utxos = do
    seed <- selectLargestAdaUtxo "registry deployment" utxos
    (seedSplitTxId, scopesSeedRef, registrySeedRef) <-
        submitSeedSplit config provider submitter pp seed
    seedOuts <-
        waitForTxIns provider [scopesSeedRef, registrySeedRef] 60
    scripts <-
        deriveDevnetScripts
            (dricNetwork config)
            scopesSeedRef
            registrySeedRef
    (registryMintTxId, scopesRef, registryRef) <-
        submitRegistryNfts
            config
            provider
            submitter
            pp
            scripts
            seedOuts
    publishUtxos <-
        queryUTxOs provider (dricFundingAddress config)
    publishSeed <-
        selectLargestAdaUtxo "reference script publishing" publishUtxos
    (referenceScriptsTxId, permissionsRef, treasuryRef) <-
        submitReferenceScripts
            config
            provider
            submitter
            pp
            scripts
            publishSeed
    let treasuryTarget =
            dssTreasuryTarget scripts
        anchors =
            DevnetRegistryAnchors
                { draScopesRef = scopesRef
                , draPermissionsRef = permissionsRef
                , draTreasuryRef = treasuryRef
                , draRegistryRef = registryRef
                , draScopesPolicyId =
                    scriptHashToHex (dssScopesHash scripts)
                , draRegistryPolicyId =
                    scriptHashToHex (dssRegistryHash scripts)
                , draPermissionsHash =
                    dssPermissionsHash scripts
                , draOwnerKeyHash =
                    keyHashToText (dricOwnerKeyHash config)
                , draTreasuryTarget = treasuryTarget
                }
    pure
        DevnetRegistryPublication
            { drpSeedSplitTxId = seedSplitTxId
            , drpRegistryMintTxId = registryMintTxId
            , drpReferenceScriptsTxId = referenceScriptsTxId
            , drpAnchors = anchors
            }

submitSeedSplit
    :: DevnetRegistryInitConfig
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> (TxIn, TxOut ConwayEra)
    -> IO (TxId, TxIn, TxIn)
submitSeedSplit config provider submitter pp seed = do
    snapshot <- queryLedgerSnapshot provider
    let upperSlot = addSlots 20 (ledgerTipSlot snapshot)
        eval = providerCoreEvaluator provider
    txId <-
        runCore
            config
            "split registry seed"
            provider
            submitter
            ( buildSeedSplitCore
                pp
                (dricFundingAddress config)
                upperSlot
                seed
                eval
            )
    pure (txId, txOutRef txId 0, txOutRef txId 1)

{- | Pure-IO construction core for the registry seed-split
sub-transaction.

Spends a single funding UTxO and pays two seed outputs back
to the funding address. Returns the unsigned 'ConwayTx' as
balanced by 'Cardano.Tx.Build.build'; the caller is
responsible for signing, submission, and waiting.
-}
buildSeedSplitCore
    :: PParams ConwayEra
    -> Addr
    -- ^ funding address (also the change address)
    -> SlotNo
    -- ^ validity upper bound
    -> (TxIn, TxOut ConwayEra)
    -- ^ funding seed UTxO (must be present in the input
    --     set passed to 'build')
    -> CoreEvaluator
    -> IO (Either (TxBuild.BuildError Void) ConwayTx)
buildSeedSplitCore pp fundingAddress upperSlot seed@(seedIn, _) eval =
    build
        (mkPParamsBound pp)
        emptyInterpret
        eval
        [seed]
        []
        fundingAddress
        prog
  where
    prog :: TxBuild NoCtx Void ()
    prog = do
        _ <- spend seedIn
        _ <- payTo fundingAddress (inject devnetSeedCoin)
        _ <- payTo fundingAddress (inject devnetSeedCoin)
        validTo upperSlot

submitRegistryNfts
    :: DevnetRegistryInitConfig
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> DevnetScriptSet
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (TxId, TxIn, TxIn)
submitRegistryNfts config provider submitter pp scripts seedOuts = do
    snapshot <- queryLedgerSnapshot provider
    let upperSlot = addSlots 20 (ledgerTipSlot snapshot)
        eval = providerCoreEvaluator provider
    txId <-
        runCore
            config
            "mint registry NFTs"
            provider
            submitter
            ( buildRegistryNftsCore
                pp
                (dricFundingAddress config)
                (dricNetwork config)
                (dricOwnerKeyHash config)
                scripts
                upperSlot
                seedOuts
                eval
            )
    pure (txId, txOutRef txId 0, txOutRef txId 1)

{- | Pure-IO construction core for the registry-NFT mint
sub-transaction.

Spends the two seed outputs produced by 'buildSeedSplitCore',
attaches the parameterised scopes and registry scripts, mints
one NFT under each policy, and emits two anchored UTxOs
(scopes-owners datum and registry datum). Returns the unsigned
'ConwayTx' as balanced by 'Cardano.Tx.Build.build'.

Fails when the seed list does not have exactly two entries.
-}
buildRegistryNftsCore
    :: PParams ConwayEra
    -> Addr
    -- ^ funding/change address
    -> Network
    -- ^ ledger network used to derive the script address
    --     for each NFT anchor
    -> KeyHash Payment
    -- ^ scope owner key hash baked into the scopes datum
    -> DevnetScriptSet
    -- ^ scripts derived from the two seed TxIns
    -> SlotNo
    -- ^ validity upper bound
    -> [(TxIn, TxOut ConwayEra)]
    -- ^ exactly two seed UTxOs: scopes seed then registry seed
    -> CoreEvaluator
    -> IO (Either (TxBuild.BuildError Void) ConwayTx)
buildRegistryNftsCore
    pp
    fundingAddress
    network
    ownerKeyHash
    scripts
    upperSlot
    seedOuts
    eval = do
        (scopesSeed@(scopesSeedRef, _), registrySeed@(registrySeedRef, _)) <-
            case seedOuts of
                [scopesSeed, registrySeed] ->
                    pure (scopesSeed, registrySeed)
                _ ->
                    fail "expected exactly two registry seed UTxOs"
        let scopesOut =
                nftTxOut
                    (scriptAddr network (dssScopesHash scripts))
                    (dssScopesHash scripts)
                    scopesTokenName
                    (ownersDatum ownerKeyHash)
            registryOut =
                nftTxOut
                    (scriptAddr network (dssRegistryHash scripts))
                    (dssRegistryHash scripts)
                    registryTokenName
                    (registryDatum (ttScriptHash (dssTreasuryTarget scripts)))
            prog :: TxBuild NoCtx Void ()
            prog = do
                _ <- spend scopesSeedRef
                _ <- spend registrySeedRef
                collateral scopesSeedRef
                attachScript (dssScopesScript scripts)
                attachScript (dssRegistryScript scripts)
                mint
                    (PolicyID (dssScopesHash scripts))
                    (Map.singleton (assetName scopesTokenName) 1)
                    (RawPlutusData emptyListRedeemer)
                mint
                    (PolicyID (dssRegistryHash scripts))
                    (Map.singleton (assetName registryTokenName) 1)
                    (RawPlutusData emptyListRedeemer)
                scopesIx <- output scopesOut
                registryIx <- output registryOut
                checkMinUtxo pp scopesIx
                checkMinUtxo pp registryIx
                validTo upperSlot
        build
            (mkPParamsBound pp)
            emptyInterpret
            eval
            [scopesSeed, registrySeed]
            []
            fundingAddress
            prog

submitReferenceScripts
    :: DevnetRegistryInitConfig
    -> Provider IO
    -> Submitter IO
    -> PParams ConwayEra
    -> DevnetScriptSet
    -> (TxIn, TxOut ConwayEra)
    -> IO (TxId, TxIn, TxIn)
submitReferenceScripts config provider submitter pp scripts seed = do
    snapshot <- queryLedgerSnapshot provider
    let upperSlot = addSlots 20 (ledgerTipSlot snapshot)
        eval = providerCoreEvaluator provider
    txId <-
        runCore
            config
            "publish reference scripts"
            provider
            submitter
            ( buildReferenceScriptsCore
                pp
                (dricFundingAddress config)
                scripts
                upperSlot
                seed
                eval
            )
    pure (txId, txOutRef txId 0, txOutRef txId 1)

{- | Pure-IO construction core for the reference-script
publication sub-transaction.

Spends a single funding UTxO and publishes the permissions
and treasury reference scripts at the derived treasury
address. Returns the unsigned 'ConwayTx' as balanced by
'Cardano.Tx.Build.build'.
-}
buildReferenceScriptsCore
    :: PParams ConwayEra
    -> Addr
    -- ^ funding/change address
    -> DevnetScriptSet
    -- ^ scripts derived from the two seed TxIns; supplies
    --     the permissions and treasury scripts plus the
    --     target reference-script address
    -> SlotNo
    -- ^ validity upper bound
    -> (TxIn, TxOut ConwayEra)
    -- ^ funding seed UTxO
    -> CoreEvaluator
    -> IO (Either (TxBuild.BuildError Void) ConwayTx)
buildReferenceScriptsCore
    pp
    fundingAddress
    scripts
    upperSlot
    seed@(seedIn, _)
    eval = do
        let refAddr = ttAddress (dssTreasuryTarget scripts)
            permissionsOut =
                refScriptTxOut refAddr (dssPermissionsScript scripts)
            treasuryOut =
                refScriptTxOut refAddr (ttScript (dssTreasuryTarget scripts))
            prog :: TxBuild NoCtx Void ()
            prog = do
                _ <- spend seedIn
                permissionsIx <- output permissionsOut
                treasuryIx <- output treasuryOut
                checkMinUtxo pp permissionsIx
                checkMinUtxo pp treasuryIx
                validTo upperSlot
        build
            (mkPParamsBound pp)
            emptyInterpret
            eval
            [seed]
            []
            fundingAddress
            prog

{- | Shape of the script evaluator the construction cores
hand to 'Cardano.Tx.Build.build'.

The @tx-build@ infrastructure consumes a per-purpose map
keyed by 'ConwayPlutusPurpose' 'AsIx' and producing either
an error string or the evaluator's 'ExUnits'. The live
'Provider' returns a richer error type ('TransactionScriptFailure');
'providerCoreEvaluator' wraps that into the simpler shape.
-}
type CoreEvaluator =
    ConwayTx
    -> IO
        ( Map.Map
            (ConwayPlutusPurpose AsIx ConwayEra)
            (Either String ExUnits)
        )

-- | Adapt a 'Provider' \'s 'evaluateTx' to the 'CoreEvaluator' shape.
providerCoreEvaluator :: Provider IO -> CoreEvaluator
providerCoreEvaluator provider tx =
    fmap
        (Map.map (either (Left . show) Right))
        (evaluateTx provider tx)

emptyInterpret :: InterpretIO NoCtx
emptyInterpret = InterpretIO $ \case {}

{- | Internal helper shared by the three submitters: invoke
the construction core, then sign, submit, and wait. The
returned 'TxId' is the signed-transaction id from the live
submission.
-}
runCore
    :: DevnetRegistryInitConfig
    -> String
    -> Provider IO
    -> Submitter IO
    -> IO (Either (TxBuild.BuildError Void) ConwayTx)
    -> IO TxId
runCore config label provider submitter buildIO =
    buildIO >>= \case
        Left err ->
            throwIO . userError $
                label <> ": " <> show err
        Right tx -> do
            let signed = dricSignTx config tx
                txId = txIdTx signed
            submitTx submitter signed >>= \case
                Submitted _ -> pure ()
                Rejected reason ->
                    throwIO . userError $
                        label
                            <> " rejected: "
                            <> BS8.unpack reason
            waitForTxChange
                provider
                txId
                (dricFundingAddress config)
                60
            pure txId

-- | Derive the parametrized DevNet scripts from seed references.
deriveDevnetScripts :: Network -> TxIn -> TxIn -> IO DevnetScriptSet
deriveDevnetScripts network scopesSeed registrySeed = do
    scopesBlob <-
        expectEither
            "derive devnet scopes NFT policy"
            (applyParams scopesValidatorBlob [outputReferenceData scopesSeed])
    scopesHash <-
        expectEither
            "hash devnet scopes NFT policy"
            (scriptHashOfBlob scopesBlob)
    scopesScript <- scriptFromBlob scopesBlob
    registryBlob <-
        expectEither
            "derive devnet registry NFT policy"
            ( applyParams
                treasuryRegistryValidatorBlob
                [ outputReferenceData registrySeed
                , scopeData CoreDevelopment
                ]
            )
    registryHash <-
        expectEither
            "hash devnet registry NFT policy"
            (scriptHashOfBlob registryBlob)
    registryScript <- scriptFromBlob registryBlob
    permissionsBlob <-
        expectEither
            "derive devnet permissions script"
            ( applyScriptParams
                permissionsValidatorBlob
                [ ParamData (B (scriptHashBytes scopesHash))
                , ParamData (scopeData CoreDevelopment)
                ]
            )
    permissionsHash <-
        expectEither
            "hash devnet permissions script"
            (scriptHashOfBlob permissionsBlob)
    permissionsScript <- scriptFromBlob permissionsBlob
    treasuryTarget <-
        treasuryTargetFromBlob network
            =<< expectEither
                "derive devnet treasury script"
                ( applyParams
                    treasuryValidatorBlob
                    [ treasuryConfigurationData
                        (scriptHashBytes registryHash)
                        (scriptHashBytes permissionsHash)
                    ]
                )
    pure
        DevnetScriptSet
            { dssScopesScript = scopesScript
            , dssScopesHash = scopesHash
            , dssRegistryScript = registryScript
            , dssRegistryHash = registryHash
            , dssPermissionsScript = permissionsScript
            , dssPermissionsHash = permissionsHash
            , dssTreasuryTarget = treasuryTarget
            }

-- | Build a treasury target from a compiled Plutus script blob.
treasuryTargetFromBlob
    :: Network -> BS.ByteString -> IO TreasuryTarget
treasuryTargetFromBlob network blob = do
    script <- scriptFromBlob blob
    scriptHash <-
        expectEither
            "hash treasury script"
            (scriptHashOfBlob blob)
    pure
        TreasuryTarget
            { ttScript = script
            , ttScriptHash = scriptHash
            , ttScriptHashText = scriptHashToHex scriptHash
            , ttAddress = scriptAddr network scriptHash
            }

scriptFromBlob :: BS.ByteString -> IO (Script ConwayEra)
scriptFromBlob blob =
    case mkPlutusScript plutus of
        Just script -> pure (fromPlutusScript script)
        Nothing ->
            throwIO . userError $
                "failed to build Plutus script"
  where
    plutus =
        Plutus @PlutusV3 (PlutusBinary (SBS.toShort blob))

outputReferenceData :: TxIn -> Data
outputReferenceData (TxIn txId ix) =
    let TxId txIdHash =
            txId
    in  Constr
            0
            [ B (hashToBytes (extractHash txIdHash))
            , I (toInteger (txIxToInt ix))
            ]

scopeData :: ScopeId -> Data
scopeData = \case
    CoreDevelopment -> Constr 0 []
    _ -> error "devnet registry init only derives core_development scripts"

treasuryConfigurationData :: BS.ByteString -> BS.ByteString -> Data
treasuryConfigurationData registryPolicy permissionsHash =
    Constr
        0
        [ B registryPolicy
        , treasuryPermissionsData permissionsHash
        , I treasuryExpirationMs
        , I payoutUpperbound
        ]

treasuryPermissionsData :: BS.ByteString -> Data
treasuryPermissionsData permissionsHash =
    Constr
        0
        [ multisigScriptPermission permissionsHash
        , multisigScriptPermission permissionsHash
        , Constr 2 [List []]
        , multisigScriptPermission permissionsHash
        ]

multisigScriptPermission :: BS.ByteString -> Data
multisigScriptPermission scriptHash =
    Constr 6 [B scriptHash]

ownersDatum :: KeyHash Payment -> Data
ownersDatum owner =
    Constr
        0
        [ ownerSignature
        , ownerSignature
        , ownerSignature
        , ownerSignature
        ]
  where
    ownerSignature =
        Constr 0 [B (keyHashBytes owner)]

registryDatum :: ScriptHash -> Data
registryDatum treasuryHash =
    Constr
        0
        [ scriptCredential treasuryHash
        , Constr 1 [B (BS.replicate 28 0)]
        ]

scriptCredential :: ScriptHash -> Data
scriptCredential =
    Constr 1 . pure . B . scriptHashBytes

nftTxOut
    :: Addr
    -> ScriptHash
    -> BS.ByteString
    -> Data
    -> TxOut ConwayEra
nftTxOut addr policy tokenName datum =
    mkBasicTxOut
        addr
        ( MaryValue
            devnetNftCoin
            ( multiAssetFromList
                [
                    ( PolicyID policy
                    , assetName tokenName
                    , 1
                    )
                ]
            )
        )
        & datumTxOutL .~ mkInlineDatum @ConwayEra datum

refScriptTxOut :: Addr -> Script ConwayEra -> TxOut ConwayEra
refScriptTxOut addr script =
    mkBasicTxOut
        addr
        (MaryValue devnetReferenceScriptCoin (MultiAsset Map.empty))
        & referenceScriptTxOutL .~ SJust script

scriptAddr :: Network -> ScriptHash -> Addr
scriptAddr network scriptHash =
    Addr
        network
        (ScriptHashObj scriptHash)
        (StakeRefBase (ScriptHashObj scriptHash))

assetName :: BS.ByteString -> AssetName
assetName =
    AssetName . SBS.toShort

scriptHashBytes :: ScriptHash -> BS.ByteString
scriptHashBytes (ScriptHash h) =
    hashToBytes h

keyHashBytes :: KeyHash kr -> BS.ByteString
keyHashBytes (KeyHash h) =
    hashToBytes h

keyHashToText :: KeyHash kr -> T.Text
keyHashToText =
    TE.decodeUtf8Lenient . B16.encode . keyHashBytes

txOutRef :: TxId -> Integer -> TxIn
txOutRef txId ix =
    TxIn txId (mkTxIxPartial ix)

selectLargestAdaUtxo
    :: String
    -> [(TxIn, TxOut ConwayEra)]
    -> IO (TxIn, TxOut ConwayEra)
selectLargestAdaUtxo label utxos =
    case foldr choose Nothing utxos of
        Just (_, selected) -> pure selected
        Nothing -> fail ("no pure-ADA UTxO for " <> label)
  where
    choose utxo@(_, txOut) best =
        let MaryValue (Coin lovelace) (MultiAsset assets) =
                txOut ^. valueTxOutL
        in  if Map.null assets
                then case best of
                    Nothing -> Just (lovelace, utxo)
                    Just (bestLovelace, _)
                        | lovelace > bestLovelace ->
                            Just (lovelace, utxo)
                    _ -> best
                else best

waitForTxIns
    :: Provider IO
    -> [TxIn]
    -> Int
    -> IO [(TxIn, TxOut ConwayEra)]
waitForTxIns _ refs attempts
    | attempts <= 0 =
        throwIO . userError $
            "timed out waiting for UTxOs: "
                <> show (txInToText <$> refs)
waitForTxIns provider refs attempts = do
    found <- queryUTxOByTxIn provider (Set.fromList refs)
    if all (`Map.member` found) refs
        then
            pure
                [ (ref, found Map.! ref)
                | ref <- refs
                ]
        else do
            threadDelay 500_000
            waitForTxIns provider refs (attempts - 1)

waitForTxChange :: Provider IO -> TxId -> Addr -> Int -> IO ()
waitForTxChange _ txId _ attempts
    | attempts <= 0 =
        throwIO . userError $
            "timed out waiting for tx change output: " <> show txId
waitForTxChange provider txId addr attempts = do
    utxos <- queryUTxOs provider addr
    if any (hasTxId txId . fst) utxos
        then pure ()
        else do
            threadDelay 500_000
            waitForTxChange provider txId addr (attempts - 1)

hasTxId :: TxId -> TxIn -> Bool
hasTxId txId (TxIn utxoTxId _) =
    txId == utxoTxId

addSlots :: Word64 -> SlotNo -> SlotNo
addSlots delta (SlotNo slot) =
    SlotNo (slot + delta)

devnetSeedCoin :: Coin
devnetSeedCoin = Coin 100_000_000

devnetNftCoin :: Coin
devnetNftCoin = Coin 5_000_000

devnetReferenceScriptCoin :: Coin
devnetReferenceScriptCoin = Coin 100_000_000

registryInitDirectory :: FilePath -> FilePath
registryInitDirectory runDir =
    runDir </> "registry-init"

-- | Path of the registry-init summary artifact.
registryInitSummaryPath :: FilePath -> FilePath
registryInitSummaryPath runDir =
    registryInitDirectory runDir </> "summary.json"

-- | Path of the registry-init registry artifact.
registryInitRegistryPath :: FilePath -> FilePath
registryInitRegistryPath runDir =
    registryInitDirectory runDir </> "registry.json"

-- | Path of the registry-init provenance artifact.
registryInitProvenancePath :: FilePath -> FilePath
registryInitProvenancePath runDir =
    registryInitDirectory runDir </> "provenance.json"

-- | JSON summary for a successful registry-init smoke phase.
registryInitSummaryValue
    :: Int
    -> FilePath
    -> DevnetRegistryPublication
    -> Value
registryInitSummaryValue networkMagic runDir publication =
    object
        [ "phase" .= ("registry-init" :: T.Text)
        , "network" .= ("devnet" :: T.Text)
        , "networkMagic" .= networkMagic
        , "seedSplitTxId" .= renderTxId (drpSeedSplitTxId publication)
        , "registryMintTxId"
            .= renderTxId (drpRegistryMintTxId publication)
        , "referenceScriptsTxId"
            .= renderTxId (drpReferenceScriptsTxId publication)
        , "registryPath" .= registryInitRegistryPath runDir
        , "provenancePath" .= registryInitProvenancePath runDir
        ]

-- | JSON registry handoff consumed by later DevNet slices.
registryInitRegistryValue :: DevnetRegistryPublication -> Value
registryInitRegistryValue publication =
    object
        [ "phase" .= ("registry-init" :: T.Text)
        , "network" .= ("devnet" :: T.Text)
        , "anchors"
            .= object
                [ "scopesDeployedAt"
                    .= txInToText (draScopesRef registry)
                , "registryDeployedAt"
                    .= txInToText (draRegistryRef registry)
                , "permissionsDeployedAt"
                    .= txInToText (draPermissionsRef registry)
                , "treasuryDeployedAt"
                    .= txInToText (draTreasuryRef registry)
                ]
        , "policies"
            .= object
                [ "scopesPolicyId" .= draScopesPolicyId registry
                , "registryPolicyId" .= draRegistryPolicyId registry
                ]
        , "scripts"
            .= object
                [ "permissionsScriptHash"
                    .= scriptHashToHex (draPermissionsHash registry)
                , "treasuryScriptHash"
                    .= ttScriptHashText target
                ]
        , "addresses"
            .= object
                [ "treasuryAddress" .= renderAddr (ttAddress target)
                ]
        , "owners"
            .= object
                [ "scopeOwnerKeyHash" .= draOwnerKeyHash registry
                ]
        , "submittedTxIds"
            .= object
                [ "seedSplit" .= renderTxId (drpSeedSplitTxId publication)
                , "registryMint"
                    .= renderTxId (drpRegistryMintTxId publication)
                , "referenceScripts"
                    .= renderTxId (drpReferenceScriptsTxId publication)
                ]
        ]
  where
    registry =
        drpAnchors publication
    target =
        draTreasuryTarget registry

-- | JSON provenance for the registry-init artifact set.
registryInitProvenanceValue :: Value
registryInitProvenanceValue =
    object
        [ "phase" .= ("registry-init" :: T.Text)
        , "source" .= ("amaru-treasury-tx" :: T.Text)
        , "issue" .= (147 :: Int)
        , "parentIssue" .= (151 :: Int)
        ]

-- | Human-readable success lines printed by the registry-init phase.
registryInitLines
    :: Int
    -> FilePath
    -> DevnetRegistryPublication
    -> [String]
registryInitLines =
    registryInitLinesWithPrefix "devnet-smoke"

-- | Human-readable success lines with a caller-specific command prefix.
registryInitLinesWithPrefix
    :: String
    -> Int
    -> FilePath
    -> DevnetRegistryPublication
    -> [String]
registryInitLinesWithPrefix prefix networkMagic runDir publication =
    [ line "run-dir " <> runDir
    , line "network devnet magic " <> show networkMagic
    , line "phase registry-init passed"
    , line "registry-init-seed-split-tx-id "
        <> T.unpack (renderTxId (drpSeedSplitTxId publication))
    , line "registry-init-registry-mint-tx-id "
        <> T.unpack (renderTxId (drpRegistryMintTxId publication))
    , line "registry-init-reference-scripts-tx-id "
        <> T.unpack (renderTxId (drpReferenceScriptsTxId publication))
    , line "registry-init-summary "
        <> registryInitSummaryPath runDir
    , line "registry-init-registry "
        <> registryInitRegistryPath runDir
    ]
  where
    line message = prefix <> ": " <> message

-- | Write the registry-init artifact set under the run directory.
writeRegistryInitArtifacts
    :: Int
    -> FilePath
    -> DevnetRegistryPublication
    -> IO ()
writeRegistryInitArtifacts networkMagic runDir publication = do
    writeRegistryInitArtifactsWithPrefix
        "devnet-smoke"
        networkMagic
        runDir
        publication

-- | Write the registry-init artifact set with caller-specific log lines.
writeRegistryInitArtifactsWithPrefix
    :: String
    -> Int
    -> FilePath
    -> DevnetRegistryPublication
    -> IO ()
writeRegistryInitArtifactsWithPrefix prefix networkMagic runDir publication = do
    writeRegistryInitArtifactsWithLines
        networkMagic
        runDir
        publication
        ( registryInitLinesWithPrefix
            prefix
            networkMagic
            runDir
            publication
        )

-- | Write the registry-init artifact set with caller-supplied log lines.
writeRegistryInitArtifactsWithLines
    :: Int
    -> FilePath
    -> DevnetRegistryPublication
    -> [String]
    -> IO ()
writeRegistryInitArtifactsWithLines networkMagic runDir publication linesOut = do
    let summary =
            registryInitSummaryValue networkMagic runDir publication
    createDirectoryIfMissing True (registryInitDirectory runDir)
    BSL.writeFile (registryInitSummaryPath runDir) (encode summary)
    BSL.writeFile
        (registryInitRegistryPath runDir)
        (encode (registryInitRegistryValue publication))
    BSL.writeFile
        (registryInitProvenancePath runDir)
        (encode registryInitProvenanceValue)
    BSL.writeFile (runDir </> "summary.json") (encode summary)
    writeFile
        (runDir </> "summary.log")
        (unlines linesOut)

{- | Verify that all registry-init anchors exist and reference-script
anchors carry the expected scripts.
-}
verifyRegistryInitPublication
    :: Provider IO
    -> DevnetRegistryPublication
    -> IO ()
verifyRegistryInitPublication provider publication = do
    let registry =
            drpAnchors publication
        refs =
            [ draScopesRef registry
            , draRegistryRef registry
            , draPermissionsRef registry
            , draTreasuryRef registry
            ]
    found <- queryUTxOByTxIn provider (Set.fromList refs)
    let missing =
            filter (`Map.notMember` found) refs
    unless (null missing) $
        throwIO . userError $
            "registry-init missing anchor UTxOs: "
                <> show (txInToText <$> missing)
    verifyRegistryReferenceScript
        found
        "permissions"
        (draPermissionsRef registry)
        (draPermissionsHash registry)
    verifyRegistryReferenceScript
        found
        "treasury"
        (draTreasuryRef registry)
        (ttScriptHash (draTreasuryTarget registry))

verifyRegistryReferenceScript
    :: Map.Map TxIn (TxOut ConwayEra)
    -> String
    -> TxIn
    -> ScriptHash
    -> IO ()
verifyRegistryReferenceScript found label ref expectedHash =
    case Map.lookup ref found of
        Nothing ->
            throwIO . userError $
                "registry-init missing "
                    <> label
                    <> " reference script UTxO "
                    <> T.unpack (txInToText ref)
        Just txOut ->
            case txOut ^. referenceScriptTxOutL of
                SJust script ->
                    unless
                        ( Core.hashScript @ConwayEra script
                            == expectedHash
                        )
                        $ throwIO
                        $ userError
                            ( "registry-init "
                                <> label
                                <> " reference script hash mismatch"
                            )
                SNothing ->
                    throwIO . userError $
                        "registry-init "
                            <> label
                            <> " UTxO has no reference script"

-- | Path of the withdraw registry artifact in a DevNet run directory.
withdrawalRegistryPath :: FilePath -> FilePath
withdrawalRegistryPath runDir =
    runDir </> "withdraw" </> "registry.json"

-- | JSON projection consumed by DevNet withdraw diagnostics.
withdrawalRegistryValue :: DevnetRegistryAnchors -> Value
withdrawalRegistryValue registry =
    object
        [ "scopesDeployedAt"
            .= txInToText (draScopesRef registry)
        , "permissionsDeployedAt"
            .= txInToText (draPermissionsRef registry)
        , "permissionsScriptHash"
            .= scriptHashToHex (draPermissionsHash registry)
        , "treasuryDeployedAt"
            .= txInToText (draTreasuryRef registry)
        , "registryDeployedAt"
            .= txInToText (draRegistryRef registry)
        , "registryPolicyId"
            .= draRegistryPolicyId registry
        , "treasuryScriptHash"
            .= ttScriptHashText (draTreasuryTarget registry)
        , "treasuryAddress"
            .= renderAddr (ttAddress (draTreasuryTarget registry))
        ]

-- | Write the withdraw registry projection under the run directory.
writeWithdrawalRegistryArtifacts
    :: FilePath
    -> DevnetRegistryAnchors
    -> IO ()
writeWithdrawalRegistryArtifacts runDir registry =
    BSL.writeFile
        (withdrawalRegistryPath runDir)
        (encode (withdrawalRegistryValue registry))

-- | Convert the published anchors into the withdraw wizard registry view.
devnetRegistryView
    :: DevnetRegistryAnchors
    -> Withdraw.RegistryView
devnetRegistryView registry =
    let treasuryHashText =
            ttScriptHashText (draTreasuryTarget registry)
        treasuryAddress =
            renderAddr (ttAddress (draTreasuryTarget registry))
        refs =
            Withdraw.TreasuryRefs
                { Withdraw.trAddress = treasuryAddress
                , Withdraw.trScriptHash = treasuryHashText
                , Withdraw.trPermissionsRewardAccount =
                    scriptHashToHex (draPermissionsHash registry)
                }
        owners =
            ScopeOwners
                { soCore = draOwnerKeyHash registry
                , soOps = draOwnerKeyHash registry
                , soNetworkCompliance = draOwnerKeyHash registry
                , soMiddleware = draOwnerKeyHash registry
                }
    in  Withdraw.RegistryView
            { Withdraw.rvScopesDeployedAt =
                txInToText (draScopesRef registry)
            , Withdraw.rvPermissionsDeployedAt =
                txInToText (draPermissionsRef registry)
            , Withdraw.rvTreasuryDeployedAt =
                txInToText (draTreasuryRef registry)
            , Withdraw.rvRegistryDeployedAt =
                txInToText (draRegistryRef registry)
            , Withdraw.rvRegistryPolicyId =
                draRegistryPolicyId registry
            , Withdraw.rvOwners = owners
            , Withdraw.rvTreasuryByScope =
                Map.singleton CoreDevelopment refs
            }

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

expectEither :: String -> Either String a -> IO a
expectEither label =
    either (throwIO . userError . ((label <> ": ") <>)) pure
