{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Cli.SwapRerate
Description : CLI parser and branch helpers for swap-rerate
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The @swap-rerate@ command surface selects pending SundaeSwap orders for
one treasury scope and records the new ADA/USDM rate. Slice 1 stops at
the parser and pure branch-decision layer; later slices resolve orders
and build unsigned transaction artifacts.
-}
module Amaru.Treasury.Cli.SwapRerate
    ( SwapRerateOpts (..)
    , SwapRerateSelectionMode (..)
    , SwapRerateOrderCandidate (..)
    , SwapReratePassthroughReason (..)
    , SwapRerateDecision (..)
    , swapRerateOptsP
    , decideSwapRerateBranch
    , runSwapRerate
    ) where

import Control.Applicative
    ( some
    , (<|>)
    )
import Data.Aeson
    ( Value
    , encode
    , object
    , (.=)
    )
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy qualified as BSL
import Data.ByteString.Short qualified as SBS
import Data.Char (toLower)
import Data.Foldable
    ( toList
    , traverse_
    )
import Data.List qualified as List
import Data.Map.Strict qualified as Map
import Data.Maybe
    ( fromMaybe
    , mapMaybe
    )
import Data.Ratio
    ( approxRational
    , denominator
    , numerator
    )
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word16, Word64)
import Lens.Micro ((&), (.~), (^.))
import Options.Applicative
    ( Parser
    , ReadM
    , auto
    , eitherReader
    , flag'
    , help
    , long
    , metavar
    , option
    , optional
    , short
    , strOption
    )
import PlutusCore.Data (Data)
import System.Exit qualified as Exit
import System.FilePath
    ( takeDirectory
    , (</>)
    )

import Amaru.Treasury.Backend
    ( Provider (..)
    )
import Amaru.Treasury.Backend.N2C
    ( withLocalNodeBackend
    )
import Amaru.Treasury.Build.Result
    ( BuildResult (..)
    )
import Amaru.Treasury.Build.SwapRerate qualified as Build
import Amaru.Treasury.ChainContext
    ( ChainContext (..)
    , networkFromMagic
    , withLiveContext
    )
import Amaru.Treasury.ChainContext.Fixture
    ( readSwapFixture
    , toFrozenContext
    )
import Amaru.Treasury.Cli.Common
    ( GlobalOpts (..)
    , nowTip
    )
import Amaru.Treasury.Constants
    ( sundaeOrderScriptRefMainnet
    , sundaeProtocolFeeLovelace
    , sundaeUsdmPoolHex
    , usdmAssetHex
    , usdmPolicyHex
    )
import Amaru.Treasury.Inspect.SwapOrderDatum qualified as InspectDatum
import Amaru.Treasury.Inspect.Types
    ( ParsedSwapOrder (..)
    )
import Amaru.Treasury.IntentJSON
    ( SAction (..)
    , SomeTreasuryIntent (..)
    , decodeTreasuryIntentFile
    , translateIntent
    )
import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytes
    , decodeHexBytesAny
    , parseGuardKeyHash
    , parseRewardAccountForNetwork
    , parseTxIn
    )
import Amaru.Treasury.LedgerParse
    ( addrFromText
    , scriptHashFromHex
    , txInToText
    )
import Amaru.Treasury.Metadata
    ( ScopeMetadata (..)
    , ScriptRef (..)
    , TreasuryMetadata (..)
    , readMetadataFile
    )
import Amaru.Treasury.Scope
    ( ScopeId (..)
    , allScopes
    , scopeFromText
    , scopeText
    )
import Amaru.Treasury.Sundae.Contracts
    ( sundaeOrderValidatorBlob
    )
import Amaru.Treasury.Swap.Rerate
    ( RerateProgramInputs (..)
    )
import Amaru.Treasury.Swap.Rerate.Budget qualified as Budget
import Amaru.Treasury.Swap.Rerate.Plan qualified as Plan
import Amaru.Treasury.Swap.Rerate.Types
    ( PlannedRerate (..)
    , PlannedRerateOrder (..)
    , RerateBudgetEstimate (..)
    , RerateIntent (..)
    , RerateOrder (..)
    , ReratePlan (..)
    , ReratePlanReason
    , RerateScopeContext (..)
    , RerateSplit (..)
    )
import Amaru.Treasury.Tx.Swap
    ( SwapIntent (..)
    , SwapOrderDatumParams (..)
    )
import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Alonzo.Scripts
    ( fromPlutusScript
    , mkPlutusScript
    )
import Cardano.Ledger.Api.Era (eraProtVerLow)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( TxOut
    , addrTxOutL
    , datumTxOutL
    , mkBasicTxOut
    , referenceScriptTxOutL
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Binary
    ( DecCBOR (..)
    , decodeFullAnnotator
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Core
    ( Script
    , bodyTxL
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
import Cardano.Ledger.Keys (KeyRole (..))
import Cardano.Ledger.Mary.Value
    ( MaryValue (..)
    , MultiAsset (..)
    )
import Cardano.Ledger.Plutus.Data
    ( Datum (..)
    , binaryDataToData
    , getPlutusData
    )
import Cardano.Ledger.Plutus.Language
    ( Language (PlutusV2)
    , Plutus (..)
    , PlutusBinary (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo (..))
import Cardano.Tx.Ledger (ConwayTx)

-- | Flags for the @swap-rerate@ subcommand.
data SwapRerateOpts = SwapRerateOpts
    { sroMetadataPath :: !FilePath
    -- ^ Path to local @journal/2026/metadata.json@.
    , sroScope :: !ScopeId
    -- ^ Treasury scope whose pending orders may be re-rated.
    , sroWalletTxIn :: !Text
    -- ^ Wallet fuel input.
    , sroCollateralTxIn :: !(Maybe Text)
    -- ^ Optional collateral input; later slices may default to the
    -- wallet input.
    , sroSelectionMode :: !SwapRerateSelectionMode
    -- ^ Operator selection mode for pending order retraction.
    , sroNewRate :: !Double
    -- ^ New ADA/USDM rate.
    , sroValidityHours :: !(Maybe Word16)
    -- ^ Optional validity horizon in hours.
    , sroOutPath :: !(Maybe FilePath)
    -- ^ Where to write unsigned CBOR hex; 'Nothing' means stdout.
    , sroReportPath :: !(Maybe FilePath)
    -- ^ Where to write the re-rate report JSON.
    , sroLog :: !(Maybe FilePath)
    -- ^ Where to write step logs; 'Nothing' means stderr.
    }
    deriving stock (Eq, Show)

-- | Operator choice for pending-order retraction.
data SwapRerateSelectionMode
    = -- | Retract exactly these order TxIns.
      SwapRerateSelectExplicit ![Text]
    | -- | Retract every pending order that belongs to the selected scope.
      SwapRerateSelectAll
    | -- | Continue through the plain swap path without retraction.
      SwapRerateDeclineRetract
    deriving stock (Eq, Show)

-- | Minimal pending-order fact used by the CLI branch helper.
data SwapRerateOrderCandidate = SwapRerateOrderCandidate
    { srocTxIn :: !Text
    -- ^ Pending order identifier rendered as @TXHASH#IX@.
    , srocScope :: !ScopeId
    -- ^ Scope attributed to the pending order.
    }
    deriving stock (Eq, Show)

-- | Why @swap-rerate@ should continue as a plain swap.
data SwapReratePassthroughReason
    = -- | The operator explicitly selected @--no-retract@.
      SwapRerateRetractDeclined
    | -- | No pending order is available for the selected scope.
      SwapRerateNoPendingOrders
    | -- | Selection was empty after CLI-level resolution.
      SwapRerateNoOrdersSelected
    deriving stock (Eq, Show)

-- | Branch decision reported by the CLI layer before transaction build.
data SwapRerateDecision
    = -- | The selected orders fit in one transaction.
      SwapRerateSingleTx
        !ReratePlanReason
        !RerateBudgetEstimate
        ![Text]
    | -- | The selected orders need the split fallback plan.
      SwapRerateSplitPlan
        !ReratePlanReason
        !RerateBudgetEstimate
        ![RerateSplit Text]
    | -- | No re-rate transaction should be built by this command path.
      SwapReratePassthrough !SwapReratePassthroughReason
    deriving stock (Eq, Show)

-- | Parse @swap-rerate@ options.
swapRerateOptsP :: Parser SwapRerateOpts
swapRerateOptsP =
    SwapRerateOpts
        <$> strOption
            ( long "metadata"
                <> metavar "PATH"
                <> help "Path to local journal/2026 metadata.json"
            )
        <*> option
            scopeReader
            ( long "scope"
                <> metavar "NAME"
                <> help
                    "core_development|ops_and_use_cases|network_compliance|middleware"
            )
        <*> strOption
            ( long "wallet-txin"
                <> metavar "TXHASH#IX"
                <> help "Wallet fuel input"
            )
        <*> optional
            ( strOption
                ( long "collateral-txin"
                    <> metavar "TXHASH#IX"
                    <> help "Optional collateral input"
                )
            )
        <*> selectionModeP
        <*> option
            auto
            ( long "new-rate"
                <> metavar "ADA_USDM"
                <> help "New ADA/USDM rate for replacement orders"
            )
        <*> optional
            ( option
                auto
                ( long "validity-hours"
                    <> metavar "HOURS"
                    <> help
                        "Optional. Omit to use the chain's current horizon."
                )
            )
        <*> optional
            ( strOption
                ( long "out"
                    <> short 'o'
                    <> metavar "PATH"
                    <> help "Write unsigned CBOR hex here (defaults to stdout)"
                )
            )
        <*> optional
            ( strOption
                ( long "report"
                    <> metavar "PATH"
                    <> help "Write re-rate report JSON; '-' means stdout"
                )
            )
        <*> optional
            ( strOption
                ( long "log"
                    <> metavar "PATH"
                    <> help "Where to write step lines (defaults to stderr)"
                )
            )

selectionModeP :: Parser SwapRerateSelectionMode
selectionModeP =
    noRetractP <|> allOrdersP <|> explicitOrdersP
  where
    noRetractP =
        flag'
            SwapRerateDeclineRetract
            ( long "no-retract"
                <> help
                    "Decline pending-order retraction and use the plain swap path"
            )
    allOrdersP =
        flag'
            SwapRerateSelectAll
            ( long "all-orders"
                <> help "Select every pending order for the requested scope"
            )
    explicitOrdersP =
        SwapRerateSelectExplicit
            <$> some
                ( strOption
                    ( long "order-txin"
                        <> metavar "TXHASH#IX"
                        <> help
                            "Pending SundaeSwap order UTxO to re-rate; repeat to select more than one"
                    )
                )

scopeReader :: ReadM ScopeId
scopeReader =
    eitherReader $
        scopeFromText . T.pack . map toLower

{- | Decide whether the CLI should build one re-rate transaction, report
a split fallback, or continue through the plain swap path.

This helper intentionally works with rendered order TxIns so parser and
selection behavior can be tested before later slices resolve full ledger
UTxOs.
-}
decideSwapRerateBranch
    :: ScopeId
    -- ^ Requested scope.
    -> SwapRerateSelectionMode
    -- ^ Operator selection mode.
    -> [SwapRerateOrderCandidate]
    -- ^ Pending orders visible to the CLI layer.
    -> Maybe (ReratePlan Text)
    -- ^ Budget decision for the selected orders.
    -> Either Text SwapRerateDecision
decideSwapRerateBranch scope mode candidates plan =
    case mode of
        SwapRerateDeclineRetract ->
            Right $
                SwapReratePassthrough SwapRerateRetractDeclined
        _
            | null candidates ->
                Right $
                    SwapReratePassthrough SwapRerateNoPendingOrders
        SwapRerateSelectExplicit selected ->
            selectedDecision scope selected candidates plan
        SwapRerateSelectAll ->
            let selected =
                    filter
                        ((== scope) . srocScope)
                        candidates
            in  if null selected
                    then
                        Right $
                            SwapReratePassthrough
                                SwapRerateNoPendingOrders
                    else decisionFromPlan plan

selectedDecision
    :: ScopeId
    -> [Text]
    -> [SwapRerateOrderCandidate]
    -> Maybe (ReratePlan Text)
    -> Either Text SwapRerateDecision
selectedDecision scope selected candidates plan
    | null selected =
        Right $
            SwapReratePassthrough SwapRerateNoOrdersSelected
    | otherwise = do
        resolved <- traverse (resolveSelected candidates) selected
        traverse_ (ensureCandidateScope scope) resolved
        decisionFromPlan plan

resolveSelected
    :: [SwapRerateOrderCandidate]
    -> Text
    -> Either Text SwapRerateOrderCandidate
resolveSelected candidates txIn =
    case List.find ((== txIn) . srocTxIn) candidates of
        Just candidate -> Right candidate
        Nothing ->
            Left ("selected order " <> txIn <> " is not pending")

ensureCandidateScope
    :: ScopeId -> SwapRerateOrderCandidate -> Either Text ()
ensureCandidateScope expected SwapRerateOrderCandidate{..}
    | srocScope == expected = Right ()
    | otherwise =
        Left $
            "selected order "
                <> srocTxIn
                <> " belongs to "
                <> scopeText srocScope
                <> "; expected "
                <> scopeText expected

decisionFromPlan
    :: Maybe (ReratePlan Text) -> Either Text SwapRerateDecision
decisionFromPlan = \case
    Nothing ->
        Left "re-rate plan is required when orders are selected"
    Just (SingleTx reason estimate orders) ->
        Right (SwapRerateSingleTx reason estimate orders)
    Just (Split reason estimate groups) ->
        Right (SwapRerateSplitPlan reason estimate groups)

-- | Run @swap-rerate@.
runSwapRerate :: GlobalOpts -> SwapRerateOpts -> IO ()
runSwapRerate g@GlobalOpts{..} opts =
    case goSocketPath of
        Just socket ->
            runSwapRerateLive g socket opts
        Nothing ->
            runSwapRerateOffline opts

data LiveRerate = LiveRerate
    { lrOrderScriptRef :: !TxIn
    , lrOrderAddress :: !Addr
    , lrCollateralTxIn :: !TxIn
    , lrInputs :: !RerateProgramInputs
    , lrIntent :: !RerateIntent
    , lrSelectedTxIns :: ![TxIn]
    }

data LiveOrderCandidate = LiveOrderCandidate
    { locTxIn :: !TxIn
    , locScope :: !ScopeId
    , locValue :: !MaryValue
    , locDatum :: !Data
    }

runSwapRerateLive :: GlobalOpts -> FilePath -> SwapRerateOpts -> IO ()
runSwapRerateLive g socket opts@SwapRerateOpts{..} = do
    metadata <- readMetadataFile sroMetadataPath
    withLocalNodeBackend (goNetworkMagic g) socket $ \provider -> do
        resolveLiveRerate g provider metadata opts >>= \case
            LivePassthrough reason ->
                writeRerateReport sroReportPath (passthroughReport opts reason)
            LiveRejected code message -> do
                writeRerateReport
                    sroReportPath
                    (rejectedReport opts code message)
                Exit.exitFailure
            LiveBuild resolved -> do
                let needed =
                        Set.fromList $
                            lrCollateralTxIn resolved
                                : rpiWalletTxIn (lrInputs resolved)
                                : rpiOrderScriptRef (lrInputs resolved)
                                : rpiScopesDeployedAt (lrInputs resolved)
                                : rpiPermissionsDeployedAt (lrInputs resolved)
                                : rpiTreasuryDeployedAt (lrInputs resolved)
                                : rpiRegistryDeployedAt (lrInputs resolved)
                                : lrSelectedTxIns resolved
                withLiveContext
                    (networkFromMagic (goNetworkMagic g))
                    provider
                    needed
                    $ \ctx -> do
                        planned <- case Plan.planRerate (lrIntent resolved) of
                            Left err -> do
                                writeRerateReport
                                    sroReportPath
                                    ( rejectedReport
                                        opts
                                        "invalid_order"
                                        (T.pack (show err))
                                    )
                                Exit.exitFailure
                            Right ok -> pure ok
                        case Budget.planRerate
                            (prOrders planned)
                            (ccPParams ctx) of
                            SingleTx reason estimate _ -> do
                                result <-
                                    Build.runSwapRerate
                                        ctx
                                        (lrInputs resolved)
                                        (lrIntent resolved)
                                writeBuildCbor sroOutPath result
                                writeRerateReport
                                    sroReportPath
                                    ( singleTxReport
                                        opts
                                        reason
                                        estimate
                                        (prOrders planned)
                                        result
                                    )
                            Split reason estimate groups ->
                                writeRerateReport
                                    sroReportPath
                                    ( splitReport
                                        opts
                                        reason
                                        estimate
                                        groups
                                        (prOrders planned)
                                    )

data LiveResolution
    = LivePassthrough !SwapReratePassthroughReason
    | LiveRejected !Text !Text
    | LiveBuild !LiveRerate

resolveLiveRerate
    :: GlobalOpts
    -> Provider IO
    -> TreasuryMetadata
    -> SwapRerateOpts
    -> IO LiveResolution
resolveLiveRerate g provider metadata SwapRerateOpts{..} = do
    orderScript <- orderScriptFromBlob sundaeOrderValidatorBlob
    let network = networkFromMagic (goNetworkMagic g)
        orderAddress =
            scriptAddr network (Core.hashScript @ConwayEra orderScript)
    orders <- queryLiveOrderCandidates provider metadata orderAddress
    selected <- selectLiveOrders sroScope sroSelectionMode orders
    case selected of
        Left reason -> pure (LivePassthrough reason)
        Right (Left message) -> pure (LiveRejected "wrong_scope" message)
        Right (Right []) ->
            pure (LivePassthrough SwapRerateNoOrdersSelected)
        Right (Right chosen) -> do
            scopeMeta <- case Map.lookup sroScope (tmTreasuries metadata) of
                Nothing ->
                    Exit.die $
                        "swap-rerate: scope not in metadata: "
                            <> T.unpack (scopeText sroScope)
                Just sm -> pure sm
            let networkName =
                    fromMaybe
                        (case network of Mainnet -> "mainnet"; Testnet -> "devnet")
                        (goNetworkName g)
            ownerKeys <- ownerKeysFromMetadata metadata
            treasuryHash <-
                expectRightIO $
                    scriptHashFromHex (srHash (smTreasury scopeMeta))
            treasuryAddress <-
                expectRightIO $
                    addrFromText (smAddress scopeMeta)
            datumParams <- datumParamsFromMetadata metadata sroScope
            permissionsReward <-
                expectRightIO $
                    parseRewardAccountForNetwork
                        networkName
                        (srHash (smPermissions scopeMeta))
            scopesRef <- parseTxInOrDie (tmScopeOwners metadata)
            permissionsRef <-
                parseTxInOrDie (srDeployedAt (smPermissions scopeMeta))
            treasuryRef <-
                parseTxInOrDie (srDeployedAt (smTreasury scopeMeta))
            registryRef <-
                parseTxInOrDie (srDeployedAt (smRegistry scopeMeta))
            walletTxIn <- parseTxInOrDie sroWalletTxIn
            collateralTxIn <-
                parseTxInOrDie (fromMaybe sroWalletTxIn sroCollateralTxIn)
            orderScriptRef <-
                resolveOrderScriptRef
                    provider
                    network
                    orderAddress
                    orderScript
            tip <- nowTip provider
            let (rateNumerator, rateDenominator) = rateParts sroNewRate
                upperBound =
                    addValiditySlots
                        (defaultValiditySlots network)
                        sroValidityHours
                        (SlotNo tip)
                intent =
                    RerateIntent
                        { riScopeContext =
                            RerateScopeContext
                                { rscScope = sroScope
                                , rscExpectedOwners = ownerKeys
                                , rscTreasuryScriptHash = treasuryHash
                                , rscOrderExtraLovelace =
                                    Coin
                                        ( fromInteger $
                                            sundaeProtocolFeeLovelace
                                                + 2_000_000
                                        )
                                , rscDatumParams = datumParams
                                }
                        , riOrders =
                            [ RerateOrder
                                { rroTxIn = locTxIn order
                                , rroScope = locScope order
                                , rroValue = locValue order
                                , rroDatum = locDatum order
                                }
                            | order <- chosen
                            ]
                        , riRateNumerator = rateNumerator
                        , riRateDenominator = rateDenominator
                        }
                inputs =
                    RerateProgramInputs
                        { rpiWalletTxIn = walletTxIn
                        , rpiOrderScriptRef = orderScriptRef
                        , rpiSwapOrderAddress = orderAddress
                        , rpiTreasuryAddress = treasuryAddress
                        , rpiPermissionsRewardAccount = permissionsReward
                        , rpiScopesDeployedAt = scopesRef
                        , rpiPermissionsDeployedAt = permissionsRef
                        , rpiTreasuryDeployedAt = treasuryRef
                        , rpiRegistryDeployedAt = registryRef
                        , rpiUpperBound = upperBound
                        }
            pure $
                LiveBuild
                    LiveRerate
                        { lrOrderScriptRef = orderScriptRef
                        , lrOrderAddress = orderAddress
                        , lrCollateralTxIn = collateralTxIn
                        , lrInputs = inputs
                        , lrIntent = intent
                        , lrSelectedTxIns = locTxIn <$> chosen
                        }

queryLiveOrderCandidates
    :: Provider IO
    -> TreasuryMetadata
    -> Addr
    -> IO [LiveOrderCandidate]
queryLiveOrderCandidates provider metadata orderAddress = do
    utxos <- queryUTxOs provider orderAddress
    pure $
        mapMaybe
            ( \(txIn, txOut) -> do
                datum <- inlineDatumMaybe txOut
                parsed <- InspectDatum.parseSwapOrderDatum datum
                scope <-
                    scopeForTreasuryHash
                        metadata
                        (posDestinationTreasuryHash parsed)
                pure
                    LiveOrderCandidate
                        { locTxIn = txIn
                        , locScope = scope
                        , locValue = txOut ^. valueTxOutL
                        , locDatum = datum
                        }
            )
            utxos

selectLiveOrders
    :: ScopeId
    -> SwapRerateSelectionMode
    -> [LiveOrderCandidate]
    -> IO
        ( Either SwapReratePassthroughReason (Either Text [LiveOrderCandidate])
        )
selectLiveOrders scope mode candidates =
    pure $ case mode of
        SwapRerateDeclineRetract ->
            Left SwapRerateRetractDeclined
        SwapRerateSelectAll ->
            let selected =
                    filter ((== scope) . locScope) candidates
            in  if null selected
                    then Left SwapRerateNoPendingOrders
                    else Right (Right selected)
        SwapRerateSelectExplicit [] ->
            Left SwapRerateNoOrdersSelected
        SwapRerateSelectExplicit selected ->
            Right $ do
                resolved <- traverse (resolveLiveSelected candidates) selected
                traverse_ (ensureLiveCandidateScope scope) resolved
                Right resolved

resolveLiveSelected
    :: [LiveOrderCandidate] -> Text -> Either Text LiveOrderCandidate
resolveLiveSelected candidates txIn =
    case List.find ((== txIn) . txInToText . locTxIn) candidates of
        Just candidate -> Right candidate
        Nothing ->
            Left ("selected order " <> txIn <> " is not pending")

ensureLiveCandidateScope
    :: ScopeId -> LiveOrderCandidate -> Either Text ()
ensureLiveCandidateScope expected candidate
    | locScope candidate == expected = Right ()
    | otherwise =
        Left $
            "selected order "
                <> txInToText (locTxIn candidate)
                <> " belongs to "
                <> scopeText (locScope candidate)
                <> "; expected "
                <> scopeText expected

resolveOrderScriptRef
    :: Provider IO
    -> Network
    -> Addr
    -> Script ConwayEra
    -> IO TxIn
resolveOrderScriptRef provider network orderAddress orderScript =
    case network of
        Mainnet -> parseTxInOrDie sundaeOrderScriptRefMainnet
        Testnet -> do
            utxos <- queryUTxOs provider orderAddress
            case [ txIn
                 | (txIn, txOut) <- utxos
                 , referenceMatches orderScript txOut
                 ] of
                txIn : _ -> pure txIn
                [] ->
                    Exit.die
                        "swap-rerate: no order script reference UTxO found"

referenceMatches :: Script ConwayEra -> TxOut ConwayEra -> Bool
referenceMatches expected txOut =
    case txOut ^. referenceScriptTxOutL of
        SJust script ->
            Core.hashScript @ConwayEra script
                == Core.hashScript @ConwayEra expected
        SNothing -> False

inlineDatumMaybe :: TxOut ConwayEra -> Maybe Data
inlineDatumMaybe txOut =
    case txOut ^. datumTxOutL of
        Datum datum -> Just (getPlutusData (binaryDataToData datum))
        _ -> Nothing

scopeForTreasuryHash
    :: TreasuryMetadata -> BS.ByteString -> Maybe ScopeId
scopeForTreasuryHash metadata hashBytes =
    List.find matches allScopes
  where
    rendered = TE.decodeUtf8 (B16.encode hashBytes)
    matches scope =
        case Map.lookup scope (tmTreasuries metadata) of
            Just sm -> srHash (smTreasury sm) == rendered
            Nothing -> False

ownerKeysFromMetadata :: TreasuryMetadata -> IO [KeyHash Guard]
ownerKeysFromMetadata metadata =
    traverse
        parseOwner
        [ owner
        | scope <-
            [CoreDevelopment, OpsAndUseCases, NetworkCompliance, Middleware]
        , Just scopeMeta <- [Map.lookup scope (tmTreasuries metadata)]
        , Just owner <- [smOwner scopeMeta]
        ]
  where
    parseOwner =
        expectRightIO . parseGuardKeyHash

datumParamsFromMetadata
    :: TreasuryMetadata -> ScopeId -> IO SwapOrderDatumParams
datumParamsFromMetadata metadata scope = do
    coreOwner <- ownerBytes CoreDevelopment
    opsOwner <- ownerBytes OpsAndUseCases
    networkOwner <- ownerBytes NetworkCompliance
    middlewareOwner <- ownerBytes Middleware
    scopeMeta <- case Map.lookup scope (tmTreasuries metadata) of
        Just sm -> pure sm
        Nothing ->
            Exit.die $
                "swap-rerate: scope not in metadata: "
                    <> T.unpack (scopeText scope)
    treasuryBytes <-
        expectRightIO $ decodeHexBytes 28 (srHash (smTreasury scopeMeta))
    poolId <- expectRightIO $ decodeHexBytes 28 sundaeUsdmPoolHex
    usdmPolicy <- expectRightIO $ decodeHexBytesAny usdmPolicyHex
    usdmToken <- expectRightIO $ decodeHexBytesAny usdmAssetHex
    pure
        SwapOrderDatumParams
            { sodPoolId = poolId
            , sodCoreOwner = coreOwner
            , sodOpsOwner = opsOwner
            , sodNetworkComplianceOwner = networkOwner
            , sodMiddlewareOwner = middlewareOwner
            , sodSundaeProtocolFeeLovelace = sundaeProtocolFeeLovelace
            , sodTreasuryScriptHash = treasuryBytes
            , sodUsdmPolicy = usdmPolicy
            , sodUsdmToken = usdmToken
            }
  where
    ownerBytes ownerScope =
        case Map.lookup ownerScope (tmTreasuries metadata) >>= smOwner of
            Just owner -> expectRightIO $ decodeHexBytes 28 owner
            Nothing ->
                Exit.die $
                    "swap-rerate: missing owner for "
                        <> T.unpack (scopeText ownerScope)

defaultValiditySlots :: Network -> Word64
defaultValiditySlots = \case
    Mainnet -> 2_000
    Testnet -> 20

addValiditySlots :: Word64 -> Maybe Word16 -> SlotNo -> SlotNo
addValiditySlots defaultSlots hours (SlotNo base) =
    SlotNo (base + maybe defaultSlots (fromIntegral . (* 3_600)) hours)

data OfflineRerate = OfflineRerate
    { orContext :: !ChainContext
    , orInputs :: !RerateProgramInputs
    , orIntent :: !RerateIntent
    , orPlanned :: !PlannedRerate
    }

runSwapRerateOffline :: SwapRerateOpts -> IO ()
runSwapRerateOffline opts@SwapRerateOpts{..} =
    case selectedOfflineOrders sroScope sroSelectionMode of
        Left reason ->
            writeRerateReport
                sroReportPath
                (passthroughReport opts reason)
        Right (Left message) -> do
            writeRerateReport
                sroReportPath
                (rejectedReport opts "wrong_scope" message)
            Exit.exitFailure
        Right (Right selected) -> do
            resolved <- loadOfflineRerate opts selected
            case Budget.planRerate
                (prOrders (orPlanned resolved))
                (ccPParams (orContext resolved)) of
                SingleTx reason estimate _ -> do
                    result <-
                        Build.runSwapRerate
                            (orContext resolved)
                            (orInputs resolved)
                            (orIntent resolved)
                    writeBuildCbor sroOutPath result
                    writeRerateReport
                        sroReportPath
                        ( singleTxReport
                            opts
                            reason
                            estimate
                            (prOrders (orPlanned resolved))
                            result
                        )
                Split reason estimate groups ->
                    writeRerateReport
                        sroReportPath
                        ( splitReport
                            opts
                            reason
                            estimate
                            groups
                            (prOrders (orPlanned resolved))
                        )

selectedOfflineOrders
    :: ScopeId
    -> SwapRerateSelectionMode
    -> Either
        SwapReratePassthroughReason
        (Either Text [Text])
selectedOfflineOrders scope = \case
    SwapRerateDeclineRetract ->
        Left SwapRerateRetractDeclined
    SwapRerateSelectAll
        | scope == NetworkCompliance ->
            Right (Right [syntheticOrderTxIn])
        | otherwise ->
            Left SwapRerateNoPendingOrders
    SwapRerateSelectExplicit [] ->
        Left SwapRerateNoOrdersSelected
    SwapRerateSelectExplicit selected
        | scope == NetworkCompliance ->
            Right (Right selected)
        | otherwise ->
            Right . Left $
                "selected order "
                    <> T.intercalate "," selected
                    <> " belongs to network_compliance; expected "
                    <> scopeText scope

loadOfflineRerate
    :: SwapRerateOpts
    -> [Text]
    -> IO OfflineRerate
loadOfflineRerate SwapRerateOpts{..} selected = do
    swapIntent <- fixtureSwapIntent fixtureDir
    base <- toFrozenContext <$> readSwapFixture fixtureDir
    orderTxIns <- traverse parseTxInOrDie selected
    orderOut0 <- firstSwapOrderOutput fixtureDir
    orderDatum <- inlineDatumOrDie orderOut0
    orderScriptRef <- parseTxInOrDie syntheticOrderScriptRef
    orderScript <- orderScriptFromBlob sundaeOrderValidatorBlob
    let orderAddress =
            scriptAddr Mainnet (Core.hashScript @ConwayEra orderScript)
        orderOut = orderOut0 & addrTxOutL .~ orderAddress
        (rateNumerator, rateDenominator) = rateParts sroNewRate
        intent =
            RerateIntent
                { riScopeContext = scopeContext swapIntent sroScope
                , riOrders =
                    [ RerateOrder
                        { rroTxIn = txIn
                        , rroScope = sroScope
                        , rroValue = orderOut ^. valueTxOutL
                        , rroDatum = orderDatum
                        }
                    | txIn <- orderTxIns
                    ]
                , riRateNumerator = rateNumerator
                , riRateDenominator = rateDenominator
                }
    planned <- case Plan.planRerate intent of
        Left err -> do
            writeRerateReport
                sroReportPath
                ( rejectedReport
                    SwapRerateOpts{..}
                    "invalid_order"
                    (T.pack (show err))
                )
            Exit.exitFailure
        Right ok -> pure ok
    let ctx =
            base
                { ccUtxos =
                    Map.insert
                        orderScriptRef
                        (refScriptTxOut orderAddress orderScript)
                        ( foldr
                            (`Map.insert` orderOut)
                            (ccUtxos base)
                            orderTxIns
                        )
                }
        inputs =
            RerateProgramInputs
                { rpiWalletTxIn = siWalletUtxo swapIntent
                , rpiOrderScriptRef = orderScriptRef
                , rpiSwapOrderAddress = orderAddress
                , rpiTreasuryAddress = siTreasuryAddress swapIntent
                , rpiPermissionsRewardAccount =
                    siPermissionsRewardAccount swapIntent
                , rpiScopesDeployedAt = siScopesDeployedAt swapIntent
                , rpiPermissionsDeployedAt =
                    siPermissionsDeployedAt swapIntent
                , rpiTreasuryDeployedAt = siTreasuryDeployedAt swapIntent
                , rpiRegistryDeployedAt = siRegistryDeployedAt swapIntent
                , rpiUpperBound = siUpperBound swapIntent
                }
    pure
        OfflineRerate
            { orContext = ctx
            , orInputs = inputs
            , orIntent = intent
            , orPlanned = planned
            }
  where
    fixtureDir =
        takeDirectory sroMetadataPath </> "swap"

writeBuildCbor :: Maybe FilePath -> BuildResult -> IO ()
writeBuildCbor outPath result = do
    let hexed = B16.encode (BSL.toStrict (brCborBytes result))
    case outPath of
        Just path -> BS.writeFile path hexed
        Nothing -> do
            BS.putStr hexed
            putStrLn ""

writeRerateReport :: Maybe FilePath -> BSL.ByteString -> IO ()
writeRerateReport Nothing _ =
    pure ()
writeRerateReport (Just "-") report = do
    BSL.putStr report
    putStrLn ""
writeRerateReport (Just path) report =
    BSL.writeFile path report

passthroughReport
    :: SwapRerateOpts -> SwapReratePassthroughReason -> BSL.ByteString
passthroughReport opts reason =
    encode $
        object
            [ "status" .= ("passthrough" :: Text)
            , "scope" .= scopeText (sroScope opts)
            , "reason" .= passthroughReasonText reason
            , "newRate" .= sroNewRate opts
            , "nextSigningSteps"
                .= [ "plain swap path remains unchanged" :: Text
                   ]
            ]

rejectedReport :: SwapRerateOpts -> Text -> Text -> BSL.ByteString
rejectedReport opts code message =
    encode $
        object
            [ "status" .= ("rejected" :: Text)
            , "scope" .= scopeText (sroScope opts)
            , "code" .= code
            , "message" .= message
            , "newRate" .= sroNewRate opts
            ]

singleTxReport
    :: SwapRerateOpts
    -> ReratePlanReason
    -> RerateBudgetEstimate
    -> [PlannedRerateOrder]
    -> BuildResult
    -> BSL.ByteString
singleTxReport opts reason estimate orders result =
    encode $
        object
            [ "status" .= ("single_tx" :: Text)
            , "scope" .= scopeText (sroScope opts)
            , "reason" .= T.pack (show reason)
            , "estimate" .= estimateReport estimate
            , "newRate" .= sroNewRate opts
            , "selectedOrders" .= fmap plannedOrderReport orders
            , "feeLovelace" .= showCoin (brFeeLovelace result)
            , "nextSigningSteps"
                .= [ "run witness on the unsigned CBOR hex" :: Text
                   , "attach witnesses before submit"
                   ]
            ]

splitReport
    :: SwapRerateOpts
    -> ReratePlanReason
    -> RerateBudgetEstimate
    -> [RerateSplit PlannedRerateOrder]
    -> [PlannedRerateOrder]
    -> BSL.ByteString
splitReport opts reason estimate groups orders =
    encode $
        object
            [ "status" .= ("split" :: Text)
            , "scope" .= scopeText (sroScope opts)
            , "reason" .= T.pack (show reason)
            , "estimate" .= estimateReport estimate
            , "newRate" .= sroNewRate opts
            , "selectedOrders" .= fmap plannedOrderReport orders
            , "groups" .= fmap splitGroupReport groups
            , "nextSigningSteps"
                .= [ "build, witness, and submit each split group in order" :: Text
                   ]
            ]

plannedOrderReport :: PlannedRerateOrder -> Value
plannedOrderReport PlannedRerateOrder{..} =
    object
        [ "txIn" .= renderTxIn proTxIn
        , "returned" .= showValue proOriginalValue
        , "reOffered" .= showValue proReplacementValue
        , "requestedUsdm" .= proRequestedUsdm
        ]

splitGroupReport
    :: RerateSplit PlannedRerateOrder -> Value
splitGroupReport RerateSplit{..} =
    object
        [ "orders" .= fmap (renderTxIn . proTxIn) rsOrders
        , "createsReplacement" .= rsCreatesReplacement
        ]

estimateReport :: RerateBudgetEstimate -> Value
estimateReport estimate =
    object
        [ "memory" .= rbeMemory estimate
        , "steps" .= rbeSteps estimate
        , "size" .= rbeSize estimate
        ]

passthroughReasonText :: SwapReratePassthroughReason -> Text
passthroughReasonText = \case
    SwapRerateRetractDeclined -> "declined retraction"
    SwapRerateNoPendingOrders -> "no pending orders"
    SwapRerateNoOrdersSelected -> "no orders selected"

rateParts :: Double -> (Integer, Integer)
rateParts rate =
    let rational = approxRational rate 0.000000001
    in  (numerator rational, denominator rational)

fixtureSwapIntent :: FilePath -> IO SwapIntent
fixtureSwapIntent fixtureDir = do
    parsed <- expectRightIO =<< decodeTreasuryIntentFile path
    case parsed of
        SomeTreasuryIntent SSwap typed -> do
            (_, swapIntent) <- expectRightIO $ translateIntent SSwap typed
            pure swapIntent
        other ->
            Exit.die ("swap-rerate: expected swap intent, got " <> show other)
  where
    path = fixtureDir </> "intent.json"

firstSwapOrderOutput :: FilePath -> IO (TxOut ConwayEra)
firstSwapOrderOutput fixtureDir = do
    tx <-
        expectRightIO . decodeHexConwayTx
            =<< BS.readFile (fixtureDir </> "expected.cbor")
    case toList (tx ^. bodyTxL . outputsTxBodyL) of
        out : _ -> pure out
        [] -> Exit.die "swap-rerate: fixture swap transaction has no outputs"

decodeHexConwayTx :: BS.ByteString -> Either String ConwayTx
decodeHexConwayTx rawHex = do
    raw <- case B16.decode (BS.filter (/= 10) rawHex) of
        Right bytes -> Right (BSL.fromStrict bytes)
        Left err -> Left err
    case decodeFullAnnotator
        (eraProtVerLow @ConwayEra)
        "ConwayTx"
        decCBOR
        raw of
        Right tx -> Right tx
        Left err -> Left (show err)

scopeContext :: SwapIntent -> ScopeId -> RerateScopeContext
scopeContext swapIntent scope =
    RerateScopeContext
        { rscScope = scope
        , rscExpectedOwners = expectRight fixtureOwnerKeys
        , rscTreasuryScriptHash = expectRight fixtureTreasuryScriptHash
        , rscOrderExtraLovelace = siSwapOrderExtraLovelace swapIntent
        , rscDatumParams = fixtureDatumParams
        }

fixtureDatumParams :: SwapOrderDatumParams
fixtureDatumParams =
    SwapOrderDatumParams
        { sodPoolId =
            "64f35d26b237ad58e099041bc14c687ea7fdc58969d7d5b66e2540ef"
        , sodCoreOwner =
            expectRight $
                hexBytes
                    "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
        , sodOpsOwner =
            expectRight $
                hexBytes
                    "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
        , sodNetworkComplianceOwner =
            expectRight $
                hexBytes
                    "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
        , sodMiddlewareOwner =
            expectRight $
                hexBytes
                    "97e0f6d6c86dbebf15cc8fdf0981f939b2f2b70928a46511edd49df2"
        , sodSundaeProtocolFeeLovelace = 1_280_000
        , sodTreasuryScriptHash =
            expectRight $
                hexBytes
                    "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"
        , sodUsdmPolicy =
            "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad"
        , sodUsdmToken = "0014df105553444d"
        }

fixtureOwnerKeys :: Either String [KeyHash Guard]
fixtureOwnerKeys =
    traverse
        parseGuardKeyHash
        [ "7095faf3d48d582fbae8b3f2e726670d7a35e2400c783d992bbdeffb"
        , "f3ab64b0f97dcf0f91232754603283df5d75a1201337432c04d23e2e"
        , "8bd03209d227956aaf9670751e0aa2057b51c1537a43f155b24fb1c1"
        , "97e0f6d6c86dbebf15cc8fdf0981f939b2f2b70928a46511edd49df2"
        ]

fixtureTreasuryScriptHash :: Either String ScriptHash
fixtureTreasuryScriptHash =
    scriptHashFromHex
        "32201dc1e82708364c6c42a53f89f675314bb9ad5da2734aa10baa0d"

hexBytes :: Text -> Either String BS.ByteString
hexBytes t =
    case B16.decode (TE.encodeUtf8 t) of
        Right bytes -> Right bytes
        Left err -> Left err

inlineDatumOrDie :: TxOut ConwayEra -> IO Data
inlineDatumOrDie out =
    case out ^. datumTxOutL of
        Datum datum -> pure $ getPlutusData (binaryDataToData datum)
        _ -> Exit.die "swap-rerate: fixture swap order has no inline datum"

orderScriptFromBlob :: BS.ByteString -> IO (Script ConwayEra)
orderScriptFromBlob blob =
    case mkPlutusScript plutus of
        Just script -> pure (fromPlutusScript script)
        Nothing -> Exit.die "swap-rerate: failed to build order script"
  where
    plutus =
        Plutus @PlutusV2 (PlutusBinary (SBS.toShort blob))

refScriptTxOut :: Addr -> Script ConwayEra -> TxOut ConwayEra
refScriptTxOut addr script =
    mkBasicTxOut addr (MaryValue (Coin 2_000_000) (MultiAsset Map.empty))
        & referenceScriptTxOutL .~ SJust script

scriptAddr :: Network -> ScriptHash -> Addr
scriptAddr network scriptHash =
    Addr
        network
        (ScriptHashObj scriptHash)
        (StakeRefBase (ScriptHashObj scriptHash))

parseTxInOrDie :: Text -> IO TxIn
parseTxInOrDie text =
    case parseTxIn text of
        Right txIn -> pure txIn
        Left err -> Exit.die ("swap-rerate: invalid tx-in: " <> err)

renderTxIn :: TxIn -> Text
renderTxIn =
    txInToText

showCoin :: Coin -> Integer
showCoin (Coin lovelace) =
    lovelace

showValue :: MaryValue -> Text
showValue =
    T.pack . show

expectRightIO :: (Show e) => Either e a -> IO a
expectRightIO =
    either
        (errorWithoutStackTrace . ("unexpected Left: " <>) . show)
        pure

expectRight :: (Show e) => Either e a -> a
expectRight =
    either
        (errorWithoutStackTrace . ("unexpected Left: " <>) . show)
        id

syntheticOrderTxIn :: Text
syntheticOrderTxIn =
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa#0"

syntheticOrderScriptRef :: Text
syntheticOrderScriptRef =
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb#0"
