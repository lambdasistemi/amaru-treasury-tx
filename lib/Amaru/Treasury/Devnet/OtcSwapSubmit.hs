{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Amaru.Treasury.Devnet.OtcSwapSubmit
Description : DevNet OTC-swap submit proof (issue #499, slice F)
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The phase-2 proof of the atomic OTC swap: on a local DevNet with the
treasury contracts deployed by @registry-init@, a named test asset is
minted onto a counterparty UTxO and a pre-existing asset onto a
treasury UTxO, the slice-D @otc-swap-wizard@ builds the intent,
@tx-build@ emits the body, and the transaction is signed with all
three keys — two scope owners and the counterparty — and submitted.

The assertions are the load-bearing ones (spec AC-005a):

* signing with the two scope owners alone is rejected by the ledger —
  the counterparty's spent UTxO demands their witness although they
  are not in @requiredSigners@ (T-F03);
* the submitted transaction leaves the treasury holding the incoming
  asset with its pre-existing assets intact, and the counterparty
  holding exactly @adaOut@ with no fee deducted (T-F04, T-F05);
* the same swap built with a __positive__ incoming redeemer leg is
  rejected by the validator (T-F06). The twin is driven from the same
  decoded intent — every resolved field is shared, only the redeemer
  sign differs — and encodes its leg with 'disburseUsdmRedeemer', the
  positive-leg encoder ('otcSwapRedeemer' is 'disburseUsdmRedeemer'
  of the negated quantity, T-A05). The twin carries the accepted
  transaction's per-script budgets, so the node's rejection is the
  validator's phase-2 verdict, not an ex-units artifact. The node's
  own evaluation of the twin is captured first: at least one script
  purpose must come back a failure before the twin may be submitted.

Honest limits: devnet skips Byron, and its protocol parameters and
cost models need not equal mainnet's. A devnet acceptance is strong
evidence the redeemer shape is valid; it is not proof the mainnet
validator instance accepts an equivalent transaction.

Composes existing capabilities, per the slice mandate: the mint is
the mixed-UTxO phase's path (an always-true V3 policy minted in a
plain payment transaction), the intent comes from the shipped
wizard, and the build\/sign\/submit path mirrors
"Amaru.Treasury.Devnet.DisburseSubmit".
-}
module Amaru.Treasury.Devnet.OtcSwapSubmit
    ( -- * Configuration
      DevnetOtcSwapSubmitConfig (..)

      -- * Result and failure types
    , OtcSwapSubmitResult (..)
    , OtcSwapSubmitFailure (..)
    , OtcSwapSubmitFailureStep (..)

      -- * Runner
    , runDevnetOtcSwapSubmit
    , defaultAdaOutLovelace
    , defaultIncomingQuantity
    , preexistingQuantity

      -- * Artifacts
    , otcSwapSubmitDirectory
    , otcSwapSubmitIntentPath
    , otcSwapSubmitCommandLines
    , otcSwapSubmitWizardLogPath
    , otcSwapSubmitMetadataPath
    , otcSwapSubmitTxBodyPath
    , otcSwapSubmitReportJsonPath
    , otcSwapSubmitSignedTxPath
    , otcSwapSubmitSubmitLogPath
    , otcSwapSubmitTwinPath
    , otcSwapSubmitEvidencePath
    , otcSwapSubmitSummaryPath
    , otcSwapSubmitFailurePath
    , otcSwapSubmitSummaryValue
    , otcSwapSubmitEvidenceValue
    ) where

import Cardano.Crypto.DSIGN.Class
    ( SignKeyDSIGN
    , deriveVerKeyDSIGN
    , genKeyDSIGN
    )
import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Crypto.Seed (mkSeedFromBytes)
import Cardano.Ledger.Address
    ( Addr (..)
    , getNetwork
    )
import Cardano.Ledger.Alonzo.Scripts
    ( AsIx
    , fromPlutusScript
    , mkPlutusScript
    )
import Cardano.Ledger.Api.Tx (txIdTx)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (Testnet)
    , mkTxIxPartial
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core
    ( PParams
    , Script
    )
import Cardano.Ledger.Core qualified as Core
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , ScriptHash (..)
    )
import Cardano.Ledger.Keys
    ( DSIGN
    , KeyRole (Payment)
    , VKey (..)
    , hashKey
    )
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    , multiAssetFromList
    )
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV3)
    , Plutus (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))
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
    , collateral
    , mint
    , mkPParamsBound
    , payTo
    , payTo'
    , reference
    , requireSignature
    , setMetadata
    , spend
    , spendScript
    , validFrom
    , validTo
    , withdrawScript
    )
import Cardano.Tx.Ledger (ConwayTx)
import Control.Concurrent (threadDelay)
import Control.Exception
    ( Exception
    , SomeException
    , fromException
    , throwIO
    , try
    )
import Control.Monad (forM_, unless, void, when)
import Data.Aeson
    ( Value
    , eitherDecodeFileStrict
    , encode
    , object
    , (.=)
    )
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Function (on)
import Data.IORef
    ( modifyIORef'
    , newIORef
    , readIORef
    )
import Data.List (maximumBy, nub)
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Data.Void (Void)
import Data.Word (Word64)
import Lens.Micro ((^.))
import Ouroboros.Network.Magic (NetworkMagic (..))
import PlutusCore.Data (Data (..))
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode)
import System.FilePath ((</>))

import Amaru.Treasury.AuxData (label1694)
import Amaru.Treasury.Cli.Common (GlobalOpts (..))
import Amaru.Treasury.Cli.OtcSwapWizard
    ( OtcSwapWizardOpts (..)
    , runOtcSwapWizard
    )
import Amaru.Treasury.Cli.TxBuild qualified as TxBuild
import Amaru.Treasury.Devnet.GovernanceWithdrawalInit
    ( DevnetGovernanceWithdrawalRegistry (..)
    , readDevnetGovernanceWithdrawalRegistry
    , renderAddr
    )
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , TranslatedShared (..)
    , decodeTreasuryIntentFile
    , translateIntent
    )
import Amaru.Treasury.Redeemer
    ( RawPlutusData (..)
    , disburseUsdmRedeemer
    , emptyListRedeemer
    )
import Amaru.Treasury.Report qualified as Report
import Amaru.Treasury.Scope
    ( ScopeId (CoreDevelopment)
    )
import Amaru.Treasury.Trace (Severity (..))
import Amaru.Treasury.Tx.AttachWitness
    ( decodeUnsignedTxHex
    , encodeSignedTxHex
    , renderAttachError
    )
import Amaru.Treasury.Tx.Disburse (DisburseIntentFields (..))
import Amaru.Treasury.Tx.OtcSwap
    ( OtcSwapIntent (..)
    , OtcSwapPayload (..)
    )
import Amaru.Treasury.Tx.OtcSwapWizard (assetNameHexText)
import Amaru.Treasury.Tx.Submit (renderTxId)
import Amaru.Treasury.Tx.SwapWizard (txInToText)
import Amaru.Treasury.Tx.Witness
    ( addCardanoCliPaymentKeyWitness
    )

-- ----------------------------------------------------
-- Configuration
-- ----------------------------------------------------

{- | Live inputs for the DevNet OTC-swap submit proof. The funding
address and signing key are the DevNet genesis wallet that funded
@registry-init@; the registry artifact comes from that phase.
-}
data DevnetOtcSwapSubmitConfig = DevnetOtcSwapSubmitConfig
    { doscNetworkMagic :: !Int
    , doscSocketPath :: !FilePath
    , doscFundingAddress :: !Addr
    , doscFundingSignKey :: !(SignKeyDSIGN DSIGN)
    , doscRunDir :: !FilePath
    , doscRegistryPath :: !FilePath
    , doscAdaOutLovelace :: !Integer
    -- ^ ADA leaving the treasury: the trade's outgoing leg
    , doscIncomingQuantity :: !Integer
    -- ^ incoming asset base units (6-decimal convention)
    }
    deriving stock (Eq, Show)

{- | The trade's fixed devnet parameters: the minted stablecoin, the
treasury's pre-existing asset, and the two freshly derived keys.
Deterministic seeds keep the phase reproducible.
-}
data OtcSwapTestAssets = OtcSwapTestAssets
    { otaPolicyId :: !PolicyID
    , otaPolicyHex :: !T.Text
    , otaStablecoin :: !AssetName
    -- ^ the minted incoming asset, @STB@
    , otaPreexisting :: !AssetName
    -- ^ the treasury's pre-existing asset, @TRE@ — INV-3's teeth
    , otaCounterparty :: !(SignKeyDSIGN DSIGN)
    , otaSecondOwner :: !(SignKeyDSIGN DSIGN)
    }

-- | Failure with the step that produced it.
data OtcSwapSubmitFailure = OtcSwapSubmitFailure
    { osfCode :: !T.Text
    , osfMessage :: !T.Text
    , osfFailedStep :: !OtcSwapSubmitFailureStep
    }
    deriving stock (Eq, Show)

data OtcSwapSubmitFailureStep
    = OtcSwapSubmitRegistry
    | OtcSwapSubmitFund
    | OtcSwapSubmitWizard
    | OtcSwapSubmitBuild
    | OtcSwapSubmitTwin
    | OtcSwapSubmitWitness
    | OtcSwapSubmitSubmit
    | OtcSwapSubmitVerify
    deriving stock (Eq, Show)

{- | Exception carrying a named failure through the flow so the
top-level recorder sees both the step and the diagnostic.
-}
newtype OtcSwapSubmitException = OtcSwapSubmitException
    { unOtcSwapSubmitException :: OtcSwapSubmitFailure
    }
    deriving stock (Show)

instance Exception OtcSwapSubmitException

{- | Recorded outcome of the phase: txids, the two rejections, and
the observed post-submission balances.
-}
data OtcSwapSubmitResult = OtcSwapSubmitResult
    { osrFundTxId :: !T.Text
    , osrSwapTxId :: !T.Text
    , osrTwinRejection :: !T.Text
    -- ^ why the positive-leg twin was rejected (T-F06)
    , osrTwinEvaluationFailures :: !Int
    -- ^ script purposes the node's evaluator failed on the twin
    , osrTwoKeyRejection :: !T.Text
    -- ^ why the two-owner-only signing was rejected (T-F03)
    , osrTreasuryStb :: !Integer
    , osrTreasuryTre :: !Integer
    , osrTreasuryLovelace :: !Integer
    , osrCounterpartyLovelace :: !Integer
    , osrFeeLovelace :: !Integer
    , osrCollateralPosted :: !Bool
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Trade parameters
-- ----------------------------------------------------

{- | 20 ADA out for 10 STB: implied price 0.5 USD\/ADA, exactly the
stated price, inside INV-9's tolerance.
-}
defaultAdaOutLovelace :: Integer
defaultAdaOutLovelace = 20_000_000

defaultIncomingQuantity :: Integer
defaultIncomingQuantity = 10_000_000

{- | ADA placed on the counterparty UTxO alongside the stablecoin.
It rides balancing back to the operator's change (the shipped
singular payload carries no counterparty leftover), so the
counterparty's output is exactly @adaOut@ (INV-4, INV-5) and the
operator's post-swap delta is @+this − fee@ (T-F05).
-}
counterpartyFundingLovelace :: Integer
counterpartyFundingLovelace = 5_000_000

{- | ADA on the funded treasury UTxO: covers @adaOut@ with margin
while the continuing output keeps the rest plus both assets.
-}
treasuryFundingLovelace :: Integer
treasuryFundingLovelace = 60_000_000

-- | Base units of @TRE@ minted onto the treasury UTxO.
preexistingQuantity :: Integer
preexistingQuantity = 25_000_000

-- | Slots past the tip used as the funding tx's validity bound.
fundingValiditySlots :: Word64
fundingValiditySlots = 100

-- | One-second poll cadence and attempt budget for chain waits.
pollAttempts :: Int
pollAttempts = 120

-- | The stated trade price, USD per ADA.
statedPrice :: T.Text
statedPrice = "0.5"

-- ----------------------------------------------------
-- Artifacts
-- ----------------------------------------------------

otcSwapSubmitDirectory :: FilePath -> FilePath
otcSwapSubmitDirectory runDir = runDir </> "otc-swap-submit"

otcSwapSubmitIntentPath :: FilePath -> FilePath
otcSwapSubmitIntentPath runDir =
    otcSwapSubmitDirectory runDir </> "intent.json"

otcSwapSubmitWizardLogPath :: FilePath -> FilePath
otcSwapSubmitWizardLogPath runDir =
    otcSwapSubmitDirectory runDir </> "wizard.log"

{- | The fabricated devnet journal the wizard verifies against —
the same shape the CLI smoke assembles with jq for
@disburse-wizard@, here built from the live registry artifact.
-}
otcSwapSubmitMetadataPath :: FilePath -> FilePath
otcSwapSubmitMetadataPath runDir =
    otcSwapSubmitDirectory runDir </> "metadata.json"

otcSwapSubmitTxBodyPath :: FilePath -> FilePath
otcSwapSubmitTxBodyPath runDir =
    otcSwapSubmitDirectory runDir </> "tx.cbor.hex"

otcSwapSubmitReportJsonPath :: FilePath -> FilePath
otcSwapSubmitReportJsonPath runDir =
    otcSwapSubmitDirectory runDir </> "report.json"

otcSwapSubmitSignedTxPath :: FilePath -> FilePath
otcSwapSubmitSignedTxPath runDir =
    otcSwapSubmitDirectory runDir </> "signed.cbor.hex"

otcSwapSubmitSubmitLogPath :: FilePath -> FilePath
otcSwapSubmitSubmitLogPath runDir =
    otcSwapSubmitDirectory runDir </> "submit.log"

otcSwapSubmitTwinPath :: FilePath -> FilePath
otcSwapSubmitTwinPath runDir =
    otcSwapSubmitDirectory runDir </> "twin-positive-leg.cbor.hex"

otcSwapSubmitEvidencePath :: FilePath -> FilePath
otcSwapSubmitEvidencePath runDir =
    otcSwapSubmitDirectory runDir </> "evidence.json"

otcSwapSubmitSummaryPath :: FilePath -> FilePath
otcSwapSubmitSummaryPath runDir =
    otcSwapSubmitDirectory runDir </> "summary.json"

otcSwapSubmitFailurePath :: FilePath -> FilePath
otcSwapSubmitFailurePath runDir =
    otcSwapSubmitDirectory runDir </> "failure.json"

otcSwapSubmitSummaryValue :: OtcSwapSubmitResult -> Value
otcSwapSubmitSummaryValue r =
    object
        [ "phase" .= ("otc-swap-submit" :: T.Text)
        , "network" .= ("devnet" :: T.Text)
        , "fundTxId" .= osrFundTxId r
        , "swapTxId" .= osrSwapTxId r
        , "treasuryIncomingStb" .= osrTreasuryStb r
        , "treasuryPreexistingTre" .= osrTreasuryTre r
        , "treasuryLovelace" .= osrTreasuryLovelace r
        , "counterpartyLovelace" .= osrCounterpartyLovelace r
        , "feeLovelace" .= osrFeeLovelace r
        , "collateralPosted" .= osrCollateralPosted r
        ]

otcSwapSubmitEvidenceValue :: OtcSwapSubmitResult -> Value
otcSwapSubmitEvidenceValue r =
    object
        [ "phase" .= ("otc-swap-submit" :: T.Text)
        , "T-F03_two_owner_signing_rejected" .= osrTwoKeyRejection r
        , "T-F04_treasury_holds_incoming_asset"
            .= (osrTreasuryStb r > 0)
        , "T-F04_preexisting_assets_intact"
            .= (osrTreasuryTre r > 0)
        , "T-F05_counterparty_exactly_ada_out" .= True
        , "T-F05_fee_paid_and_collateral_posted"
            .= osrCollateralPosted r
        , "T-F06_positive_leg_evaluation_failures"
            .= osrTwinEvaluationFailures r
        , "T-F06_positive_leg_rejected" .= osrTwinRejection r
        , "swapTxId" .= osrSwapTxId r
        , "fundTxId" .= osrFundTxId r
        ]

-- ----------------------------------------------------
-- Runner
-- ----------------------------------------------------

{- | Execute the phase and write artifacts. Any failure — named or
exceptional — is recorded at 'otcSwapSubmitFailurePath' before the
'Left' is returned.
-}
runDevnetOtcSwapSubmit
    :: DevnetOtcSwapSubmitConfig
    -> Provider IO
    -> Submitter IO
    -> IO (Either OtcSwapSubmitFailure OtcSwapSubmitResult)
runDevnetOtcSwapSubmit config provider submitter =
    try @SomeException (flow config provider submitter) >>= \case
        Right result -> do
            writeJson
                (otcSwapSubmitSummaryPath runDir)
                (otcSwapSubmitSummaryValue result)
            writeJson
                (otcSwapSubmitEvidencePath runDir)
                (otcSwapSubmitEvidenceValue result)
            pure (Right result)
        Left exc ->
            case fromException exc of
                Just (OtcSwapSubmitException failure) ->
                    Left <$> recordFailure failure
                Nothing ->
                    Left
                        <$> recordFailure
                            OtcSwapSubmitFailure
                                { osfCode =
                                    "otc-swap-submit-exception"
                                , osfMessage =
                                    T.pack (show exc)
                                , osfFailedStep =
                                    OtcSwapSubmitVerify
                                }
  where
    runDir = doscRunDir config

    recordFailure failure = do
        writeJson (otcSwapSubmitFailurePath runDir) $
            object
                [ "phase" .= ("otc-swap-submit" :: T.Text)
                , "code" .= osfCode failure
                , "message" .= osfMessage failure
                , "step" .= show (osfFailedStep failure)
                ]
        pure failure

-- | Named failure: aborts the flow, lands in @failure.json@.
otcFail
    :: OtcSwapSubmitFailureStep
    -> T.Text
    -> T.Text
    -> IO a
otcFail step code message =
    throwIO $
        OtcSwapSubmitException
            OtcSwapSubmitFailure
                { osfCode = code
                , osfMessage = message
                , osfFailedStep = step
                }

{- | The phase, step by step. Order is load-bearing: both negative
controls run while the traded UTxOs are still unspent, so their
rejections are phase-2 verdicts, not double-spend noise.
-}
flow
    :: DevnetOtcSwapSubmitConfig
    -> Provider IO
    -> Submitter IO
    -> IO OtcSwapSubmitResult
flow config@DevnetOtcSwapSubmitConfig{..} provider submitter = do
    createDirectoryIfMissing True (otcSwapSubmitDirectory doscRunDir)
    registry <-
        expectEither "registry artifact"
            =<< readDevnetGovernanceWithdrawalRegistry doscRegistryPath
    unless (getNetwork (dgwrTreasuryAddress registry) == Testnet) $
        otcFail
            OtcSwapSubmitRegistry
            "registry-treasury-not-testnet"
            "registry treasury address is not a testnet address"
    let assets = mintedTestAssets
    writeFabricatedMetadata doscRunDir registry
    (fundTxId, cpUtxo, treasuryUtxo, walletBefore, cpBefore) <-
        fundOtcSwapParties config registry assets provider submitter
    buildViaWizard config registry assets cpUtxo treasuryUtxo
    (tx, success) <- buildTxBody config
    goodBudgets <- evaluateBudgets provider tx
    twoKeyRejection <-
        rejectTwoOwnerSigning config assets submitter tx
    (twinRejection, twinFailures) <-
        rejectPositiveLegTwin
            config
            assets
            provider
            submitter
            goodBudgets
    submitGoodSwap
        config
        registry
        assets
        provider
        submitter
        tx
        success
        fundTxId
        cpUtxo
        treasuryUtxo
        walletBefore
        cpBefore
        twinRejection
        twinFailures
        twoKeyRejection

-- | The 'GlobalOpts' the wizard and tx-build run under.
devnetGlobals :: DevnetOtcSwapSubmitConfig -> GlobalOpts
devnetGlobals config =
    GlobalOpts
        { goSocketPath = Just (doscSocketPath config)
        , goNetworkMagic =
            NetworkMagic (fromIntegral (doscNetworkMagic config))
        , goNetworkName = Just "devnet"
        , goMinimumSeverity = Info
        }

-- ----------------------------------------------------
-- T-F01 — mint and fund the parties
-- ----------------------------------------------------

{- | One payment transaction mints @STB@ onto a fresh counterparty
UTxO and @TRE@ onto a treasury UTxO, then waits for both to be
live. Returns the funding tx id, the two created UTxOs, the
operator wallet's total lovelace before the funding, and the
counterparty's funded lovelace.
-}
fundOtcSwapParties
    :: DevnetOtcSwapSubmitConfig
    -> DevnetGovernanceWithdrawalRegistry
    -> OtcSwapTestAssets
    -> Provider IO
    -> Submitter IO
    -> IO (T.Text, TxIn, TxIn, Integer, Integer)
fundOtcSwapParties DevnetOtcSwapSubmitConfig{..} registry assets provider submitter = do
    pp <- queryProtocolParams provider
    utxos <- queryUTxOs provider doscFundingAddress
    (seedIn, seedOut) <-
        maybe
            ( otcFail
                OtcSwapSubmitFund
                "wallet-utxo-missing"
                "no pure-ADA funding UTxO available"
            )
            pure
            ( selectLargestPureAdaUtxo
                (anchorTxIds registry)
                utxos
            )
    snapshot <- queryLedgerSnapshot provider
    let counterpartyAddr = paymentAddress (otaCounterparty assets)
        treasuryAddr = dgwrTreasuryAddress registry
        policy = otaPolicyId assets
        forbidden = anchorTxIds registry
        dumpUtxos label list =
            logLine
                doscRunDir
                ( label
                    <> " "
                    <> T.intercalate
                        ","
                        [ txInToText i
                            <> "="
                            <> T.pack (show (txOutLovelace o))
                            <> (if txOutHasAssets o then "+a" else "")
                        | (i, o) <- list
                        ]
                )
        minted =
            Map.fromList
                [ (otaStablecoin assets, doscIncomingQuantity)
                , (otaPreexisting assets, preexistingQuantity)
                ]
        singleValue lovelace asset qty =
            MaryValue
                (Coin lovelace)
                (multiAssetFromList [(policy, asset, qty)])
        cpValue =
            singleValue
                counterpartyFundingLovelace
                (otaStablecoin assets)
                doscIncomingQuantity
        treasuryValue =
            singleValue
                treasuryFundingLovelace
                (otaPreexisting assets)
                preexistingQuantity
        upperBound =
            addSlots fundingValiditySlots (ledgerTipSlot snapshot)
        prog :: TxBuild q Void ()
        prog = do
            _ <- spend seedIn
            collateral seedIn
            attachScript alwaysTrueScript
            mint policy minted (RawPlutusData emptyListRedeemer)
            _ <- payTo counterpartyAddr cpValue
            _ <- payTo treasuryAddr treasuryValue
            validTo upperBound
    dumpUtxos "genesis-pre:" utxos
    tx <-
        assembleTx
            "mint and fund"
            pp
            doscFundingAddress
            [(seedIn, seedOut)]
            []
            (nodeEvaluator provider)
            prog
    let signed = addCardanoCliPaymentKeyWitness doscFundingSignKey tx
        txId = txIdTx signed
        fundTxIdText = renderTxId txId
        cpUtxo = txOutRef txId 0
        treasuryUtxo = txOutRef txId 1
    expectSubmitted "mint and fund" submitter signed
    logLine doscRunDir ("fund-input " <> txInToText seedIn)
    cpOut <- waitForOutput provider txId 0 counterpartyAddr
    _ <- waitForOutput provider txId 1 treasuryAddr
    postFunding <- queryUTxOs provider doscFundingAddress
    dumpUtxos "genesis-post:" postFunding
    let cpBefore = txOutLovelace cpOut
        walletBefore = walletTotalLovelace postFunding
    logLine doscRunDir ("fund-tx-id " <> fundTxIdText)
    pure
        ( fundTxIdText
        , cpUtxo
        , treasuryUtxo
        , walletBefore
        , cpBefore
        )

-- ----------------------------------------------------
-- T-F02/F03 — wizard intent, tx body, budgets
-- ----------------------------------------------------

{- | Build the intent through the shipped slice-D wizard, pointed at
the fabricated devnet journal, the funded counterparty UTxO and
the funded treasury UTxO. The second scope owner joins the signer
roster as a raw keyhash (RJ-003); the counterparty never does
(INV-7).
-}
buildViaWizard
    :: DevnetOtcSwapSubmitConfig
    -> DevnetGovernanceWithdrawalRegistry
    -> OtcSwapTestAssets
    -> TxIn
    -> TxIn
    -> IO ()
buildViaWizard config@DevnetOtcSwapSubmitConfig{..} _registry assets cpUtxo treasuryUtxo = do
    let counterpartyAddr =
            renderAddr (paymentAddress (otaCounterparty assets))
        secondOwnerHash =
            keyHashHex (paymentKeyHash (otaSecondOwner assets))
        incomingAsset =
            otaPolicyHex assets
                <> "."
                <> assetNameHexText (otaStablecoin assets)
        wizardOpts =
            OtcSwapWizardOpts
                { oswWalletAddr = renderAddr doscFundingAddress
                , oswMetadataPath =
                    otcSwapSubmitMetadataPath doscRunDir
                , oswOut =
                    Just (otcSwapSubmitIntentPath doscRunDir)
                , oswLog =
                    Just (otcSwapSubmitWizardLogPath doscRunDir)
                , oswScope = CoreDevelopment
                , oswCounterpartyAddr = counterpartyAddr
                , oswCounterpartyTxIns = [txInToText cpUtxo]
                , oswAdaOut = renderUnits 6 doscAdaOutLovelace
                , oswIncomingAsset = incomingAsset
                , oswIncomingQuantity =
                    renderUnits 6 doscIncomingQuantity
                , oswPrice = statedPrice
                , oswValidityHours =
                    Nothing
                , -- \^ AutoLongest: on devnet the interpreter horizon
                  -- is ~45 s, so any hour figure overshoots it; take
                  -- the largest translatable window instead
                  oswDescription =
                    "DevNet OTC swap submit proof"
                , oswJustification =
                    "Issue #499 slice F phase-2 proof"
                , oswDestinationLabel = "DevNet counterparty"
                , oswEvent = Just "devnet-otc-swap"
                , oswLabel = Nothing
                , oswSigners = [secondOwnerHash]
                , oswTreasuryTxIns = [txInToText treasuryUtxo]
                }
    try (runOtcSwapWizard (devnetGlobals config) wizardOpts) >>= \case
        Right () -> pure ()
        Left exc ->
            otcFail
                OtcSwapSubmitWizard
                "wizard-failed"
                (T.pack (show (exc :: SomeException)))

-- | Run @tx-build@ over the wizard's intent and decode the body.
buildTxBody
    :: DevnetOtcSwapSubmitConfig
    -> IO (ConwayTx, Report.TxBuildSuccess)
buildTxBody config@DevnetOtcSwapSubmitConfig{..} = do
    buildExit <-
        try $
            TxBuild.runTxBuild
                doscSocketPath
                Info
                TxBuild.TxBuildOpts
                    { TxBuild.tboIntentPath =
                        Just (otcSwapSubmitIntentPath doscRunDir)
                    , TxBuild.tboOutPath =
                        Just (otcSwapSubmitTxBodyPath doscRunDir)
                    , TxBuild.tboLog = Nothing
                    , TxBuild.tboReportPath =
                        Just (otcSwapSubmitReportJsonPath doscRunDir)
                    }
    case buildExit of
        Left exitCode ->
            otcFail
                OtcSwapSubmitBuild
                "tx-build-failed"
                ( "tx-build exited with "
                    <> T.pack (show (exitCode :: ExitCode))
                )
        Right () -> pure ()
    output <-
        eitherDecodeFileStrict @Report.TxBuildOutput
            (otcSwapSubmitReportJsonPath doscRunDir)
            >>= expectEither "tx-build report"
    success <- case Report.txoResult output of
        Report.TxBuildOutputFailure failure ->
            otcFail
                OtcSwapSubmitBuild
                (Report.bfCode failure)
                (Report.bfMessage failure)
        Report.TxBuildOutputSuccess ok -> pure ok
    txHex <- BS.readFile (otcSwapSubmitTxBodyPath doscRunDir)
    tx <-
        expectEither "decode unsigned tx" $
            decodeUnsignedTxHex txHex
    pure (tx, success)

{- | Evaluate the accepted transaction's script budgets. The body
must evaluate clean on the devnet node — that is the happy path's
own phase-2 evidence, and it is what makes the twin's rejection
attributable to the redeemer sign.
-}
evaluateBudgets
    :: Provider IO
    -> ConwayTx
    -> IO (Map.Map (ConwayPlutusPurpose AsIx ConwayEra) ExUnits)
evaluateBudgets provider tx = do
    verdicts <- evaluateTx provider tx
    let budgets = Map.mapMaybe (either (const Nothing) Just) verdicts
        failures = length verdicts - Map.size budgets
    unless (failures == 0) $
        otcFail
            OtcSwapSubmitBuild
            "accepted-tx-evaluation-failed"
            ( "the accepted tx failed script evaluation on "
                <> T.pack (show failures)
                <> " purpose(s)"
            )
    pure budgets

-- ----------------------------------------------------
-- T-F06 — the positive-leg twin
-- ----------------------------------------------------

{- | Build the same swap with a POSITIVE incoming redeemer leg and
require the validator to reject it.

The twin is translated from the wizard's own intent, so every
resolved field is shared; only the redeemer sign differs
('disburseUsdmRedeemer' of the positive quantity versus
'otcSwapRedeemer' of it, which negates). Its script budgets are
the accepted transaction's, so rejection cannot be an ex-units
artifact. The node's own evaluation must fail at least one
purpose before the twin is submitted, and the node must then
reject it in phase 2. A twin that passes either check fails the
phase — that would mean the sign convention is not what makes
the swap valid.
-}
rejectPositiveLegTwin
    :: DevnetOtcSwapSubmitConfig
    -> OtcSwapTestAssets
    -> Provider IO
    -> Submitter IO
    -> Map.Map (ConwayPlutusPurpose AsIx ConwayEra) ExUnits
    -> IO (T.Text, Int)
rejectPositiveLegTwin config@DevnetOtcSwapSubmitConfig{..} assets provider submitter goodBudgets = do
    (shared, fields, payload) <- decodeWizardIntent
    pp <- queryProtocolParams provider
    snapshot <- queryLedgerSnapshot provider
    let refIns =
            [ difScopesDeployedAt fields
            , difPermissionsDeployedAt fields
            , difTreasuryDeployedAt fields
            , difRegistryDeployedAt fields
            ]
        spendIns =
            difWalletUtxo fields
                : ospCounterpartyUtxo payload
                : difTreasuryUtxos fields
    live <- queryUTxOByTxIn provider (Set.fromList (spendIns <> refIns))
    let missing =
            [i | i <- nub (spendIns <> refIns), not (Map.member i live)]
    unless (null missing) $
        otcFail
            OtcSwapSubmitTwin
            "twin-inputs-missing"
            ( "inputs not live for the twin: "
                <> T.intercalate ", " (map txInToText missing)
            )
    let inputUtxos = [(i, live Map.! i) | i <- spendIns]
        refUtxos = [(i, live Map.! i) | i <- refIns]
        positiveRedeemer =
            RawPlutusData $
                disburseUsdmRedeemer
                    (policyBytes (ospIncomingPolicy payload))
                    (assetRawBytes (ospIncomingAsset payload))
                    (ospIncomingQuantity payload)
                    (unCoin (ospAdaOut payload))
        treasuryContinuing =
            addIncoming
                (ospIncomingPolicy payload)
                (ospIncomingAsset payload)
                (ospIncomingQuantity payload)
                (ospLeftoverAssets payload)
        prog :: TxBuild q Void ()
        prog = do
            validFrom (ledgerTipSlot snapshot)
            _ <- spend (difWalletUtxo fields)
            collateral (difWalletUtxo fields)
            _ <- spend (ospCounterpartyUtxo payload)
            forM_ (difTreasuryUtxos fields) $ \txin ->
                void (spendScript txin positiveRedeemer)
            reference (difScopesDeployedAt fields)
            reference (difPermissionsDeployedAt fields)
            reference (difTreasuryDeployedAt fields)
            reference (difRegistryDeployedAt fields)
            withdrawScript
                (difPermissionsRewardAccount fields)
                (Coin 0)
                (RawPlutusData emptyListRedeemer)
            _ <-
                payTo
                    (ospCounterpartyAddress payload)
                    ( MaryValue
                        (ospCounterpartyLovelace payload)
                        (ospCounterpartyLeftover payload)
                    )
            _ <-
                payTo'
                    (difTreasuryAddress fields)
                    ( MaryValue
                        (ospLeftoverLovelace payload)
                        treasuryContinuing
                    )
                    unitDatum
            forM_ (difSigners fields) requireSignature
            validTo (difUpperBound fields)
            setMetadata label1694 (tsRationale shared)
    verdictRef <- newIORef (0 :: Int)
    let eval tx = do
            verdicts <- evaluateTx provider tx
            let failing =
                    length
                        [ ()
                        | (_, Left _) <- Map.toList verdicts
                        ]
            modifyIORef' verdictRef (+ failing)
            pure $
                Map.mapWithKey
                    ( \k _ -> case Map.lookup k goodBudgets of
                        Just units -> Right units
                        Nothing ->
                            Left
                                "no accepted budget for purpose"
                    )
                    verdicts
    twinTx <-
        assembleTx
            "positive-leg twin"
            pp
            (tsWalletAddr shared)
            inputUtxos
            refUtxos
            eval
            prog
    failures <- readIORef verdictRef
    when (failures == 0) $
        otcFail
            OtcSwapSubmitTwin
            "twin-evaluated-green"
            "the positive-leg twin PASSED script evaluation; \
            \the negative control is broken"
    let signed =
            foldl
                (flip addCardanoCliPaymentKeyWitness)
                twinTx
                [ doscFundingSignKey
                , otaSecondOwner assets
                , otaCounterparty assets
                ]
    BS.writeFile
        (otcSwapSubmitTwinPath doscRunDir)
        (encodeSignedTxHex signed)
    submitTx submitter signed >>= \case
        Rejected reason -> do
            logLine doscRunDir "positive-leg twin: rejected"
            failures <- readIORef verdictRef
            pure (decodeUtf8Lenient reason, failures)
        Submitted _ ->
            otcFail
                OtcSwapSubmitTwin
                "twin-accepted"
                "the node ACCEPTED the positive-leg twin; \
                \the sign convention is not what makes the swap \
                \valid"
  where
    decodeWizardIntent = do
        someIntent <-
            decodeTreasuryIntentFile
                (otcSwapSubmitIntentPath doscRunDir)
                >>= expectEither "decode intent"
        case someIntent of
            SomeTreasuryIntent SOtcSwap ti ->
                case translateIntent SOtcSwap ti of
                    Left err ->
                        otcFail
                            OtcSwapSubmitTwin
                            "translate-failed"
                            (T.pack err)
                    Right (shared, OtcSwapIntent fields payload) ->
                        pure (shared, fields, payload)
            _ ->
                otcFail
                    OtcSwapSubmitTwin
                    "not-otc-swap"
                    "decoded intent is not an otc-swap"

-- ----------------------------------------------------
-- T-F03 — the two-owner negative control
-- ----------------------------------------------------

{- | Sign the accepted swap with the two scope owners only and
require the ledger to reject it: the counterparty's UTxO is
spent, so their witness is a ledger requirement even though they
are not in @requiredSigners@ (INV-7).
-}
rejectTwoOwnerSigning
    :: DevnetOtcSwapSubmitConfig
    -> OtcSwapTestAssets
    -> Submitter IO
    -> ConwayTx
    -> IO T.Text
rejectTwoOwnerSigning config assets submitter tx = do
    let signed =
            addCardanoCliPaymentKeyWitness (otaSecondOwner assets)
                . addCardanoCliPaymentKeyWitness
                    (doscFundingSignKey config)
                $ tx
    submitTx submitter signed >>= \case
        Rejected reason -> do
            logLine (doscRunDir config) "two-owner signing: rejected"
            pure (decodeUtf8Lenient reason)
        Submitted _ ->
            otcFail
                OtcSwapSubmitWitness
                "two-owner-accepted"
                "the node ACCEPTED the swap without the \
                \counterparty's witness; the ledger does not \
                \require it"

-- ----------------------------------------------------
-- T-F03/F04/F05 — the three-key submit and assertions
-- ----------------------------------------------------

{- | Sign with all three keys — the genesis scope owner, the derived
second owner, and the counterparty — submit, and assert the
post-submission on-chain state: the treasury holds the incoming
asset with its pre-existing asset intact (INV-2, INV-3), the
counterparty holds exactly @adaOut@ (INV-4, INV-5), the fee comes
out of the operator's fuel and the collateral is posted (T-F05).
-}
submitGoodSwap
    :: DevnetOtcSwapSubmitConfig
    -> DevnetGovernanceWithdrawalRegistry
    -> OtcSwapTestAssets
    -> Provider IO
    -> Submitter IO
    -> ConwayTx
    -> Report.TxBuildSuccess
    -> T.Text
    -> TxIn
    -> TxIn
    -> Integer
    -> Integer
    -> T.Text
    -> Int
    -> T.Text
    -> IO OtcSwapSubmitResult
submitGoodSwap
    config@DevnetOtcSwapSubmitConfig{..}
    registry
    assets
    provider
    submitter
    tx
    success
    fundTxId
    _cpUtxo
    treasuryUtxo
    walletBefore
    cpBefore
    twinRejection
    twinFailures
    twoKeyRejection = do
        let signed =
                foldl
                    (flip addCardanoCliPaymentKeyWitness)
                    tx
                    [ doscFundingSignKey
                    , otaSecondOwner assets
                    , otaCounterparty assets
                    ]
            txId = txIdTx signed
            swapTxIdText = renderTxId txId
            identity =
                Report.trIdentity (Report.tbsReport success)
            expectedTxId = Report.tiTxId identity
            fee = Report.tiFeeLovelace identity
            accounting =
                Report.trWalletAccounting
                    (Report.tbsReport success)
            collateralPosted =
                isJust
                    (Report.waCollateralInput accounting)
                    && Report.tiTotalCollateralLovelace identity > 0
            counterpartyAddr =
                paymentAddress (otaCounterparty assets)
            policy = otaPolicyId assets
        unless (expectedTxId == swapTxIdText) $
            otcFail
                OtcSwapSubmitSubmit
                "swap-tx-id-mismatch"
                ( "signed swap tx id "
                    <> swapTxIdText
                    <> " does not match tx-build report "
                    <> expectedTxId
                )
        BS.writeFile
            (otcSwapSubmitSignedTxPath doscRunDir)
            (encodeSignedTxHex signed)
        expectSubmitted "three-key swap" submitter signed
        _ <- waitForSpent provider treasuryUtxo swapTxIdText
        cpOut <- waitForOutput provider txId 0 counterpartyAddr
        treasuryOut <-
            waitForOutput
                provider
                txId
                1
                (dgwrTreasuryAddress registry)
        -- INV-5: the counterparty's output is exactly adaOut, no
        -- fee deducted; their STB is fully consumed.
        unless (cpBefore == counterpartyFundingLovelace) $
            otcFail
                OtcSwapSubmitVerify
                "counterparty-before-mismatch"
                "the funded counterparty lovelace changed"
        unless (txOutLovelace cpOut == doscAdaOutLovelace) $
            otcFail
                OtcSwapSubmitVerify
                "counterparty-lovelace-mismatch"
                ( "counterparty output is not exactly adaOut: "
                    <> T.pack (show (txOutLovelace cpOut))
                )
        when (txOutHasAssets cpOut) $
            otcFail
                OtcSwapSubmitVerify
                "counterparty-assets-present"
                "the counterparty output carries assets"
        -- The counterparty wallet holds exactly the one output.
        cpAfter <- queryUTxOs provider counterpartyAddr
        unless
            ( walletTotalLovelace cpAfter
                == doscAdaOutLovelace
            )
            $ otcFail
                OtcSwapSubmitVerify
                "counterparty-total-mismatch"
                ( "counterparty wallet total is not adaOut: "
                    <> T.pack
                        (show (walletTotalLovelace cpAfter))
                )
        -- INV-2: the incoming asset is on the continuing output.
        -- INV-3: the pre-existing asset survived in full.
        let stb = valueQty treasuryOut policy (otaStablecoin assets)
            tre = valueQty treasuryOut policy (otaPreexisting assets)
        unless (stb == doscIncomingQuantity) $
            otcFail
                OtcSwapSubmitVerify
                "treasury-incoming-mismatch"
                ( "treasury incoming STB is "
                    <> T.pack (show stb)
                    <> ", expected "
                    <> T.pack (show doscIncomingQuantity)
                )
        unless (tre == preexistingQuantity) $
            otcFail
                OtcSwapSubmitVerify
                "treasury-preexisting-mismatch"
                ( "treasury pre-existing TRE is "
                    <> T.pack (show tre)
                    <> ", expected "
                    <> T.pack (show preexistingQuantity)
                )
        unless
            ( txOutLovelace treasuryOut
                == treasuryFundingLovelace - doscAdaOutLovelace
            )
            $ otcFail
                OtcSwapSubmitVerify
                "treasury-lovelace-mismatch"
                "treasury continuing lovelace is not input - adaOut"
        -- T-F05: the operator paid the fee out of the wallet; the
        -- counterparty's funding lovelace rode balancing back.
        walletAfter <-
            walletTotalLovelace
                <$> queryUTxOs provider doscFundingAddress
        unless
            ( walletAfter
                == walletBefore + counterpartyFundingLovelace - fee
            )
            $ otcFail
                OtcSwapSubmitVerify
                "operator-fee-mismatch"
                ( "operator wallet delta is not +funding - fee: "
                    <> T.pack (show (walletAfter - walletBefore))
                    <> " against fee "
                    <> T.pack (show fee)
                )
        unless collateralPosted $
            otcFail
                OtcSwapSubmitVerify
                "collateral-missing"
                "the build report records no posted collateral"
        logLine doscRunDir ("swap-tx-id " <> swapTxIdText)
        logLine doscRunDir "phase otc-swap-submit passed"
        pure
            OtcSwapSubmitResult
                { osrFundTxId = fundTxId
                , osrSwapTxId = swapTxIdText
                , osrTwinRejection = twinRejection
                , osrTwinEvaluationFailures = twinFailures
                , osrTwoKeyRejection = twoKeyRejection
                , osrTreasuryStb = stb
                , osrTreasuryTre = tre
                , osrTreasuryLovelace =
                    txOutLovelace treasuryOut
                , osrCounterpartyLovelace =
                    txOutLovelace cpOut
                , osrFeeLovelace = fee
                , osrCollateralPosted = collateralPosted
                }

-- ----------------------------------------------------
-- Fabricated devnet journal
-- ----------------------------------------------------

{- | The metadata the wizard's registry verification checks against.
Same mapping the CLI smoke assembles with jq for
@disburse-wizard@; every value comes from the live registry-init
publication, so verification passes against the devnet chain.
-}
writeFabricatedMetadata
    :: FilePath
    -> DevnetGovernanceWithdrawalRegistry
    -> IO ()
writeFabricatedMetadata runDir registry =
    writeJson (otcSwapSubmitMetadataPath runDir) $
        object
            [ "scope_owners" .= txInToText (dgwrScopesRef registry)
            , "treasuries"
                .= object
                    [ "core_development"
                        .= object
                            [ "owner" .= dgwrOwnerKeyHash registry
                            , "budget" .= (2575000 :: Int)
                            , "address" .= dgwrTreasuryAddressText registry
                            , "treasury_script"
                                .= object
                                    [ "hash" .= dgwrTreasuryScriptHashText registry
                                    , "deployed_at"
                                        .= txInToText (dgwrTreasuryRef registry)
                                    ]
                            , "permissions_script"
                                .= object
                                    [ "hash"
                                        .= dgwrPermissionsScriptHashText registry
                                    , "deployed_at"
                                        .= txInToText (dgwrPermissionsRef registry)
                                    ]
                            , "registry_script"
                                .= object
                                    [ "hash" .= dgwrRegistryPolicyId registry
                                    , "deployed_at"
                                        .= txInToText (dgwrRegistryRef registry)
                                    ]
                            ]
                    ]
            ]

-- ----------------------------------------------------
-- Transaction assembly
-- ----------------------------------------------------

{- | Assemble 'prog' into a transaction. 'eval' is the script-budget
source: the plain phases use the node's evaluation, the twin
substitutes the accepted transaction's budgets.
-}
assembleTx
    :: (Show e)
    => String
    -> PParams ConwayEra
    -> Addr
    -> [(TxIn, TxOut ConwayEra)]
    -> [(TxIn, TxOut ConwayEra)]
    -> ( ConwayTx
         -> IO
                ( Map.Map
                    (ConwayPlutusPurpose AsIx ConwayEra)
                    (Either String ExUnits)
                )
       )
    -> TxBuild q e ()
    -> IO ConwayTx
assembleTx label pp change inputs refs eval prog = do
    let noCtx =
            InterpretIO $
                \_ -> error (label <> ": unexpected context request")
    result <- build (mkPParamsBound pp) noCtx eval inputs refs change prog
    case result of
        Left err -> fail (label <> ": " <> show err)
        Right tx -> pure tx

-- | The node's script evaluation, verdicts flattened for 'build'.
nodeEvaluator
    :: Provider IO
    -> ConwayTx
    -> IO
        ( Map.Map
            (ConwayPlutusPurpose AsIx ConwayEra)
            (Either String ExUnits)
        )
nodeEvaluator provider tx =
    Map.map (either (Left . show) Right)
        <$> evaluateTx provider tx

-- ----------------------------------------------------
-- Devnet test assets and derived keys
-- ----------------------------------------------------

{- | The always-true Plutus V3 minting policy — the same blob the
mixed-UTxO phase mints with. Its hash is the trade's policy id,
so the wizard can be pointed at the raw
@\<policyHex\>.\<assetHex\>@ pair with no registry row.
-}
alwaysTrueScript :: Script ConwayEra
alwaysTrueScript =
    let bytes =
            either
                (error . ("alwaysTrueScript: " <>))
                id
                (B16.decode (BS8.filter (/= '\n') alwaysTrueHex))
        plutus = Plutus @PlutusV3 (PlutusBinary (SBS.toShort bytes))
    in  maybe
            (error "alwaysTrueScript: mkPlutusScript")
            fromPlutusScript
            (mkPlutusScript plutus)

alwaysTrueHex :: BS8.ByteString
alwaysTrueHex =
    "58d501010029800aba2aba1aab9eaab9dab9a48888966002646465\
    \300130053754003300700398038012444b30013370e9000001c4c\
    \9289bae300a3009375400915980099b874800800e2646644944c0\
    \2c004c02cc030004c024dd5002456600266e1d200400389925130\
    \0a3009375400915980099b874801800e2646644944dd698058009\
    \805980600098049baa0048acc004cdc3a40100071324a26014601\
    \26ea80122646644944dd698058009805980600098049baa004401\
    \c8039007200e401c3006300700130060013003375400d149a26ca\
    \c8009"

{- | Deterministic trade assets and keys. The counterparty and
second-owner keys come from fixed seeds so a re-run reproduces
the same addresses; neither is the genesis (scope-owner) key.
-}
mintedTestAssets :: OtcSwapTestAssets
mintedTestAssets =
    OtcSwapTestAssets
        { otaPolicyId =
            PolicyID (Core.hashScript @ConwayEra alwaysTrueScript)
        , otaPolicyHex = scriptHashHex policyHash
        , otaStablecoin = AssetName (SBS.toShort "STB")
        , otaPreexisting = AssetName (SBS.toShort "TRE")
        , otaCounterparty =
            genKeyDSIGN
                ( mkSeedFromBytes
                    "otc-swap-counterparty-key-00000000000"
                )
        , otaSecondOwner =
            genKeyDSIGN
                ( mkSeedFromBytes
                    "otc-swap-second-owner-key-000000000000"
                )
        }
  where
    policyHash = Core.hashScript @ConwayEra alwaysTrueScript

scriptHashHex :: ScriptHash -> T.Text
scriptHashHex (ScriptHash h) =
    TE.decodeUtf8Lenient (B16.encode (hashToBytes h))

keyHashHex :: KeyHash kr -> T.Text
keyHashHex (KeyHash h) =
    TE.decodeUtf8Lenient (B16.encode (hashToBytes h))

paymentKeyHash :: SignKeyDSIGN DSIGN -> KeyHash Payment
paymentKeyHash = hashKey . VKey . deriveVerKeyDSIGN

-- | A plain testnet payment address for a derived key.
paymentAddress :: SignKeyDSIGN DSIGN -> Addr
paymentAddress sk =
    Addr
        Testnet
        (KeyHashObj (paymentKeyHash sk))
        StakeRefNull

-- ----------------------------------------------------
-- Twin building blocks
-- ----------------------------------------------------

{- | The inline unit datum (@Constr 0 []@) the treasury continuing
output carries — the same ruling as the accepted body.
-}
unitDatum :: RawPlutusData
unitDatum = RawPlutusData (Constr 0 [])

policyBytes :: PolicyID -> BS.ByteString
policyBytes (PolicyID (ScriptHash h)) = hashToBytes h

assetRawBytes :: AssetName -> BS.ByteString
assetRawBytes (AssetName raw) = SBS.fromShort raw

{- | Add @quantity@ of one asset to an existing bundle, zero rows
dropped — the same canonicalisation the accepted builder applies.
-}
addIncoming
    :: PolicyID -> AssetName -> Integer -> MultiAsset -> MultiAsset
addIncoming policy asset quantity (MultiAsset existing) =
    MultiAsset
        . Map.filter (not . Map.null)
        . Map.map (Map.filter (/= 0))
        $ Map.unionWith
            (Map.unionWith (+))
            existing
            (Map.singleton policy (Map.singleton asset quantity))

-- ----------------------------------------------------
-- Chain waits
-- ----------------------------------------------------

waitForOutput
    :: Provider IO
    -> TxId
    -> Int
    -> Addr
    -> IO (TxOut ConwayEra)
waitForOutput provider txId ix addr = go pollAttempts
  where
    ref = txOutRef txId ix
    go 0 =
        otcFail
            OtcSwapSubmitVerify
            "output-not-observed"
            ( "output "
                <> txInToText ref
                <> " was not observed at its address in time"
            )
    go n = do
        found <- queryUTxOByTxIn provider (Set.singleton ref)
        case Map.lookup ref found of
            Just txOut | txOut ^. addrTxOutL == addr -> pure txOut
            _ -> do
                threadDelay 1_000_000
                go (n - 1)

waitForSpent :: Provider IO -> TxIn -> T.Text -> IO ()
waitForSpent provider txin swapTxIdText = go pollAttempts
  where
    go 0 =
        otcFail
            OtcSwapSubmitVerify
            "input-not-consumed"
            ( "the swap "
                <> swapTxIdText
                <> " did not consume its inputs in time"
            )
    go n = do
        found <- queryUTxOByTxIn provider (Set.singleton txin)
        if Map.null found
            then pure ()
            else do
                threadDelay 1_000_000
                go (n - 1)

expectSubmitted :: String -> Submitter IO -> ConwayTx -> IO ()
expectSubmitted label submitter signed =
    submitTx submitter signed >>= \case
        Submitted _ -> pure ()
        Rejected reason ->
            otcFail
                OtcSwapSubmitSubmit
                (T.pack label <> "-rejected")
                (decodeUtf8Lenient reason)

-- ----------------------------------------------------
-- Small helpers
-- ----------------------------------------------------

expectEither :: (Show e) => String -> Either e a -> IO a
expectEither label = either (\e -> fail (label <> ": " <> show e)) pure

{- | The registry's live anchor refs. The funding input must never
be one of THEM (exact refs, not whole txs — the publication txs'
change outputs are legitimate funds): they are the on-chain state
the wizard's registry verification checks, and spending one is
what failed the first run with @AnchorSpent \"scope_owners\"@.
-}
anchorTxIds
    :: DevnetGovernanceWithdrawalRegistry -> Set.Set TxIn
anchorTxIds registry =
    Set.fromList
        [ dgwrScopesRef registry
        , dgwrRegistryRef registry
        , dgwrPermissionsRef registry
        , dgwrTreasuryRef registry
        ]

selectLargestPureAdaUtxo
    :: Set.Set TxIn
    -> [(TxIn, TxOut ConwayEra)]
    -> Maybe (TxIn, TxOut ConwayEra)
selectLargestPureAdaUtxo forbidden utxos =
    case filter ok utxos of
        [] -> Nothing
        picks ->
            Just
                ( maximumBy
                    (compare `on` (txOutLovelace . snd))
                    picks
                )
  where
    ok (txin, txOut) =
        not (Set.member txin forbidden)
            && not (txOutHasAssets txOut)

multiAssetOf :: TxOut ConwayEra -> MultiAsset
multiAssetOf txOut =
    let MaryValue _ assets = txOut ^. valueTxOutL
    in  assets

walletTotalLovelace :: [(TxIn, TxOut ConwayEra)] -> Integer
walletTotalLovelace = sum . map (txOutLovelace . snd)

txOutLovelace :: TxOut ConwayEra -> Integer
txOutLovelace txOut =
    let MaryValue (Coin lovelace) _ = txOut ^. valueTxOutL
    in  lovelace

txOutHasAssets :: TxOut ConwayEra -> Bool
txOutHasAssets txOut =
    let MaryValue _ (MultiAsset assets) = txOut ^. valueTxOutL
    in  not (Map.null assets)

valueQty :: TxOut ConwayEra -> PolicyID -> AssetName -> Integer
valueQty txOut policy asset =
    let MaryValue _ (MultiAsset assets) = txOut ^. valueTxOutL
    in  Map.findWithDefault
            0
            asset
            (Map.findWithDefault Map.empty policy assets)

txOutRef :: TxId -> Int -> TxIn
txOutRef txId ix = TxIn txId (mkTxIxPartial (fromIntegral ix))

addSlots :: Word64 -> SlotNo -> SlotNo
addSlots delta (SlotNo slot) = SlotNo (slot + delta)

decodeUtf8Lenient :: BS8.ByteString -> T.Text
decodeUtf8Lenient = TE.decodeUtf8With (\_ _ -> Just '?')

{- | Render base units as a fixed-decimals decimal string — the
operator-unit form the wizard parses (FR-007b).
-}
renderUnits :: Int -> Integer -> T.Text
renderUnits decimals base =
    let scale = 10 ^ decimals
        (whole, frac) = base `divMod` scale
    in  T.pack (show whole)
            <> "."
            <> T.justifyRight decimals '0' (T.pack (show frac))

logLine :: FilePath -> T.Text -> IO ()
logLine runDir message =
    TIO.appendFile
        (otcSwapSubmitSubmitLogPath runDir)
        (message <> "\n")

writeJson :: FilePath -> Value -> IO ()
writeJson path value = BSL.writeFile path (encode value)

{- | Human-readable success lines for the shipped @otc-swap-submit@
runner, mirroring the other DevNet phases.
-}
otcSwapSubmitCommandLines
    :: FilePath -> OtcSwapSubmitResult -> [String]
otcSwapSubmitCommandLines runDir result =
    [ "otc-swap-submit: run-dir " <> runDir
    , "otc-swap-submit: fund-tx-id " <> T.unpack (osrFundTxId result)
    , "otc-swap-submit: swap-tx-id "
        <> T.unpack (osrSwapTxId result)
    , "otc-swap-submit: two-owner signing rejected: "
        <> T.unpack (osrTwoKeyRejection result)
    , "otc-swap-submit: positive-leg twin rejected: "
        <> T.unpack (osrTwinRejection result)
    , "otc-swap-submit: twin evaluation failures "
        <> show (osrTwinEvaluationFailures result)
    , "otc-swap-submit: treasury incoming STB "
        <> show (osrTreasuryStb result)
    , "otc-swap-submit: treasury pre-existing TRE "
        <> show (osrTreasuryTre result)
    , "otc-swap-submit: fee lovelace "
        <> show (osrFeeLovelace result)
    , "otc-swap-submit: summary "
        <> otcSwapSubmitSummaryPath runDir
    ]
