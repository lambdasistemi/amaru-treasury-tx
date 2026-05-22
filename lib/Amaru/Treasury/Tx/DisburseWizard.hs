{-# LANGUAGE DataKinds #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Tx.DisburseWizard
Description : Typed-Q&A wizard for the disburse subcommand
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Sister of
[`Amaru.Treasury.Tx.SwapWizard`](Amaru.Treasury.Tx.SwapWizard.html)
for the disburse action: typed operator answers + a
chain-resolved environment, fed into a pure translation
to 'TreasuryIntent' @'Disburse@.

The public pure translation is 'disburseToTreasuryIntent', which
emits the unified @schema@ / @action@ JSON shape consumed by
@tx-build@. The older 'disburseToIntentJSON' entry point remains as
branch-local compatibility while the feature is rebased on top of
the unified dispatcher.

Shared registry/network types
('NetworkConstants', 'RegistryView', 'ScopeOwners',
'TreasuryRefs', 'ScopeView', 'WalletSelection',
'RationaleAnswers') are imported and re-exported from
'Amaru.Treasury.Tx.SwapWizard' so both wizards share one
schema for the chain side; see research §R7.
-}
module Amaru.Treasury.Tx.DisburseWizard
    ( -- * Answers
      DisburseAnswers (..)
    , RationaleAnswers (..)

      -- * Resolved environment
    , DisburseEnv (..)
    , DisburseTreasurySelection (..)
    , NetworkConstants (..)
    , RegistryView (..)
    , ScopeOwners (..)
    , TreasuryRefs (..)
    , ScopeView (..)
    , WalletSelection (..)

      -- * Local-translation errors
    , DisburseError (..)

      -- * Treasury selection
    , selectDisburseAda
    , selectDisburseUsdm

      -- * Resolution
    , ResolverInput (..)
    , ResolverEnv (..)
    , ResolverError (..)
    , registryViewFromVerified
    , resolveDisburseEnv

      -- * Input control (#184 — Slice 3)
    , PoolHit (..)
    , InputControlOutcome (..)
    , OutRef
    , resolveDisburseEnvIC
    , renderDisburseExclusionLogLine
    , renderDisburseWalletShortfallWithExcludes

      -- * Pure translation
    , disburseToIntentJSON
    , disburseToTreasuryIntent
    ) where

import Cardano.Ledger.BaseTypes (Network (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value
    ( AssetName (..)
    , MaryValue (..)
    , MultiAsset (..)
    , PolicyID (..)
    )
import Cardano.Ledger.TxIn (TxIn)
import Control.Monad (when)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Char (isDigit)
import Data.List qualified as L
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word16, Word64)

import Cardano.Node.Client.Validity qualified as Validity

import Amaru.Treasury.Constants
    ( Unit (..)
    , minUtxoDepositLovelace
    )
import Amaru.Treasury.IntentJSON
    ( Action (..)
    , DisburseInputs (..)
    , RationaleJSON (..)
    , RationaleReferenceJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    )
import Amaru.Treasury.IntentJSON.Common
    ( decodeHexBytes
    , decodeHexBytesAny
    , mkHash28
    )
import Amaru.Treasury.Registry.Derive (scriptHashToHex)
import Amaru.Treasury.Scope
    ( ScopeId
        ( Contingency
        , CoreDevelopment
        , Middleware
        , NetworkCompliance
        , OpsAndUseCases
        )
    , scopeText
    )
import Amaru.Treasury.Tx.DisburseIntentJSON
    ( DisburseInputsJSON (..)
    , DisburseIntentJSON (..)
    , DisburseRationaleJSON (..)
    , DisburseScopeJSON (..)
    , DisburseWalletJSON (..)
    )
import Amaru.Treasury.Tx.SwapWizard
    ( InputControlOutcome (..)
    , NetworkConstants (..)
    , PoolHit (..)
    , RationaleAnswers (..)
    , RegistryView (..)
    , ScopeOwners (..)
    , ScopeView (..)
    , TreasuryRefs (..)
    , WalletSelection (..)
    , WalletSelectionError (..)
    , addrNetwork
    , networkConstants
    , registryViewFromVerified
    , selectWallet
    , txInToText
    , walletFeeSlackLovelace
    )
import Amaru.Treasury.Wizard.InputControl
    ( ExclusionSet (..)
    , ForcedInclusionSet (..)
    , OutRef
    , filterPool
    , outRefText
    , parseOutRef
    , renderShortfallWithExcludes
    )
import Data.Either (lefts, rights)

-- ----------------------------------------------------
-- Answers
-- ----------------------------------------------------

{- | Typed operator answers for the disburse wizard.
Mirrors
[`SwapWizardQ`](Amaru.Treasury.Tx.SwapWizard.html#t:SwapWizardQ)
but for the disburse action.
-}
data DisburseAnswers = DisburseAnswers
    { daScope :: !ScopeId
    , daUnit :: !Unit
    -- ^ ADA or USDM (from
    --     'Amaru.Treasury.Constants').
    , daAmount :: !Integer
    -- ^ For 'ADA': lovelace.
    --   For 'USDM': smallest USDM unit (USDM has 6
    --   decimal places).
    , daBeneficiaryAddrBech32 :: !Text
    -- ^ Validated bech32 @addr…@ string. Parsed once
    --   by the resolver; carried verbatim into
    --   the JSON intent.
    , daValidityHours :: !(Maybe Word16)
    -- ^ Optional signing window in hours. 'Nothing' = the
    --   resolver asks the chain horizon helper for
    --   'Validity.AutoLongest'. 'Just 0' is rejected.
    , daRationale :: !RationaleAnswers
    , daRationaleReferences :: ![RationaleReferenceJSON]
    -- ^ Optional external-document references for the emitted
    --   rationale body.
    , daExtraSigners :: ![Text]
    -- ^ Each token is either a scope name (lowercased,
    --   e.g. @"ops_and_use_cases"@) resolved through
    --   the registry owners, or a raw 28-byte hex
    --   keyhash. Owned scopes infer and prepend the
    --   selected scope owner. 'Contingency' has no owner
    --   key, so it infers all four owned scope owners.
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Resolved environment
-- ----------------------------------------------------

{- | Treasury-side selection for disburse. Adds the
unit-aware leftover quantities to the swap-side
[`TreasurySelection`](Amaru.Treasury.Tx.SwapWizard.html#t:TreasurySelection):
disburse must preserve every asset that appears on the
selected inputs, including USDM and any other native
assets, on the leftover output.
-}
data DisburseTreasurySelection = DisburseTreasurySelection
    { dtsInputs :: ![Text]
    -- ^ @"<txid>#<ix>"@
    , dtsLeftoverLovelace :: !Integer
    -- ^ Σ lovelace on inputs − beneficiary lovelace.
    , dtsLeftoverUsdm :: !Integer
    -- ^ Σ USDM on inputs − beneficiary USDM. For
    --   @daUnit = ADA@ the beneficiary takes 0 USDM,
    --   so this is exactly Σ USDM on inputs.
    , dtsLeftoverOtherAssets
        :: !(Map Text (Map Text Integer))
    -- ^ All non-ADA, non-USDM assets present on the
    --   selected inputs, forwarded verbatim onto the
    --   leftover output. Outer key: policy hex; inner
    --   key: asset-name hex.
    }
    deriving stock (Eq, Show)

{- | Everything the resolver hands the pure translation.
Pure 'disburseToIntentJSON' reads only this record + a
'DisburseAnswers'; it never performs IO.
-}
data DisburseEnv = DisburseEnv
    { deNetwork :: !Text
    -- ^ @"mainnet"@ / @"preprod"@ / @"preview"@
    , deUpperBoundSlot :: !Word64
    -- ^ Resolver-supplied @invalid-hereafter@ slot. Already
    --   horizon-validated; the pure translator just stamps it.
    , deNetworkConstants :: !NetworkConstants
    -- ^ shared with the swap wizard; the disburse
    --   path reads only the USDM rows
    , deRegistry :: !RegistryView
    , deScopeView :: !ScopeView
    , deTreasurySelection :: !DisburseTreasurySelection
    , deWalletSelection :: !WalletSelection
    , deBeneficiaryAddrBech32 :: !Text
    -- ^ The bech32 string the operator passed; parsed
    --   and network-checked by the resolver before this
    --   record is built. Carried verbatim into the
    --   JSON intent.
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Local-translation errors
-- ----------------------------------------------------

{- | Failure modes the pure translation can detect from
a typed @(DisburseEnv, DisburseAnswers)@ pair.

Resolver-level failures (empty UTxO set, address parse
failure, network mismatch) live in a sibling
@ResolverError@ type owned by the resolver and never
reach this enum.
-}
data DisburseError
    = -- | @daAmount@ is 0 or negative.
      DisburseAmountNotPositive
    | -- | @daValidityHours = Just 0@.
      DisburseValidityHoursZero
    | -- | @daValidityHours = Just n@ overshoots the chain
      --   horizon. Carries the typed
      --   'Validity.HorizonError' so the CLI can render a
      --   one-line diagnostic.
      DisburseValidityOvershoot !Validity.HorizonError
    | -- | An entry of @daExtraSigners@ is neither a
      -- known scope name nor a 28-byte hex keyhash.
      DisburseSignerNotScopeOrHex28 !Text
    | -- | Selected treasury inputs do not cover the
      -- requested ADA amount + min-ADA on leftover.
      DisburseInsufficientTreasuryAda
    | -- | Selected treasury inputs do not cover the
      -- requested USDM amount.
      DisburseInsufficientTreasuryUsdm
    | -- | @daUnit = USDM@ but the selected scope has
      -- no USDM holdings on chain.
      DisburseUsdmRequestedOnAdaOnlyScope
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- FromJSON (for fixtures)
-- ----------------------------------------------------

instance FromJSON DisburseAnswers where
    parseJSON = withObject "DisburseAnswers" $ \o -> do
        scope <- o .: "scope"
        DisburseAnswers scope
            <$> o .: "unit"
            <*> o .: "amount"
            <*> o .: "beneficiaryAddrBech32"
            <*> o .:? "validityHours"
            <*> o .: "rationale"
            <*> (fromMaybe [] <$> o .:? "rationaleReferences")
            <*> (fromMaybe [] <$> o .:? "extraSigners")

instance FromJSON DisburseTreasurySelection where
    parseJSON =
        withObject "DisburseTreasurySelection" $ \o ->
            DisburseTreasurySelection
                <$> o .: "inputs"
                <*> o .: "leftoverLovelace"
                <*> o .: "leftoverUsdm"
                <*> (fromMaybe mempty <$> o .:? "leftoverOtherAssets")

instance FromJSON DisburseEnv where
    parseJSON = withObject "DisburseEnv" $ \o ->
        DisburseEnv
            <$> o .: "network"
            <*> o .: "upperBoundSlot"
            <*> o .: "networkConstants"
            <*> o .: "registry"
            <*> o .: "scopeView"
            <*> o .: "treasurySelection"
            <*> o .: "walletSelection"
            <*> o .: "beneficiaryAddrBech32"

-- ----------------------------------------------------
-- Pure translation
-- ----------------------------------------------------

{- | Pure, total translation from a 'DisburseEnv' and a
'DisburseAnswers' to a 'DisburseIntentJSON'.

The mapping is the contract documented in
@specs\/004-disburse-wizard\/data-model.md §7.1@. Local
validation produces a 'DisburseError'; resolver-level
failures (empty UTxOs, address parse, network mismatch)
are caught by the resolver and live in a sibling
@ResolverError@ type.
-}
disburseToIntentJSON
    :: DisburseEnv
    -> DisburseAnswers
    -> Either DisburseError DisburseIntentJSON
disburseToIntentJSON env ans = do
    validate env ans
    signers <- resolveSigners env ans
    pure
        DisburseIntentJSON
            { dijNetwork = deNetwork env
            , dijWallet =
                mkWallet (deWalletSelection env)
            , dijScope = mkScope env ans
            , dijDisburse = mkDisburse env ans
            , dijSigners = signers
            , dijValidityUpperBoundSlot = deUpperBoundSlot env
            , dijRationale = mkRationale ans
            }

{- | Pure translation to the unified feature-005
'TreasuryIntent' shape. This is the JSON contract the
wizard emits after feature 005: top-level @schema@ and
@action@ fields plus the action-keyed @disburse@ block.
-}
disburseToTreasuryIntent
    :: DisburseEnv
    -> DisburseAnswers
    -> Either DisburseError (TreasuryIntent 'Disburse)
disburseToTreasuryIntent env ans = do
    validate env ans
    signers <- resolveSigners env ans
    pure
        TreasuryIntent
            { tiSAction = SDisburse
            , tiSchema = 1
            , tiNetwork = deNetwork env
            , tiWallet =
                mkTreasuryWallet (deWalletSelection env)
            , tiScope = mkTreasuryScope env ans
            , tiSigners = signers
            , tiValidityUpperBoundSlot = deUpperBoundSlot env
            , tiRationale = mkTreasuryRationale ans
            , tiPayload = mkTreasuryDisburse env ans
            }

-- ----------------------------------------------------
-- Validation
-- ----------------------------------------------------

validate
    :: DisburseEnv -> DisburseAnswers -> Either DisburseError ()
validate env ans = do
    when
        (daAmount ans <= 0)
        (Left DisburseAmountNotPositive)
    case daValidityHours ans of
        Just 0 -> Left DisburseValidityHoursZero
        _ -> pure ()
    let sel = deTreasurySelection env
    case daUnit ans of
        ADA ->
            when
                (dtsLeftoverLovelace sel < 0)
                (Left DisburseInsufficientTreasuryAda)
        USDM -> do
            when
                (dtsLeftoverUsdm sel < 0)
                (Left DisburseInsufficientTreasuryUsdm)

-- ----------------------------------------------------
-- Treasury selection
-- ----------------------------------------------------

{- | Select treasury inputs for an ADA disbursement,
largest-first by lovelace. USDM and every other native
asset on the selected inputs stay on the treasury
leftover output; only the beneficiary lovelace is
subtracted.
-}
selectDisburseAda
    :: PolicyID
    -- ^ USDM policy, excluded from @leftoverOtherAssets@
    -> AssetName
    -- ^ USDM token name, excluded from @leftoverOtherAssets@
    -> [(TxIn, MaryValue)]
    -> Integer
    -- ^ beneficiary lovelace
    -> Maybe DisburseTreasurySelection
selectDisburseAda usdmPolicy usdmAsset inputs amount =
    selectedToDisburseSelection
        usdmPolicy
        usdmAsset
        amount
        0
        =<< selectByKey lovelaceOf inputs amount

{- | Select treasury inputs for a USDM disbursement,
largest-first by USDM quantity. For USDM disburses the
on-chain treasury validator enforces strict lovelace
conservation (the redeemer's @amount.lovelace@ is 0), so
the FULL treasury-input lovelace remains on the leftover
output. The beneficiary's own min-UTxO deposit is
wallet-funded; the caller still supplies a floor so the
selected inputs can satisfy the leftover output's
min-UTxO requirement. See #215.
-}
selectDisburseUsdm
    :: PolicyID
    -- ^ USDM policy
    -> AssetName
    -- ^ USDM token name
    -> Integer
    -- ^ minimum lovelace the selected inputs must provide
    --   so the leftover output meets its own min-UTxO
    --   floor (the beneficiary's deposit is wallet-funded,
    --   not debited here).
    -> [(TxIn, MaryValue)]
    -> Integer
    -- ^ beneficiary USDM quantity
    -> Maybe DisburseTreasurySelection
selectDisburseUsdm
    usdmPolicy
    usdmAsset
    leftoverLovelaceFloor
    inputs
    amount =
        selectedToDisburseSelection
            usdmPolicy
            usdmAsset
            0
            amount
            =<< selectByKeyUntil
                (assetQuantity usdmPolicy usdmAsset)
                coversBeneficiary
                inputs
      where
        coversBeneficiary selected =
            sum (assetQuantity usdmPolicy usdmAsset . snd <$> selected)
                >= amount
                && sum (lovelaceOf . snd <$> selected)
                    >= leftoverLovelaceFloor

selectByKeyUntil
    :: (MaryValue -> Integer)
    -> ([(TxIn, MaryValue)] -> Bool)
    -> [(TxIn, MaryValue)]
    -> Maybe [(TxIn, MaryValue)]
selectByKeyUntil key covers inputs =
    go [] sorted
  where
    sorted = L.sortOn (Down . key . snd) inputs
    go picked rest
        | covers picked = Just picked
        | otherwise = case rest of
            [] -> Nothing
            x : xs -> go (picked <> [x]) xs

selectByKey
    :: (MaryValue -> Integer)
    -> [(TxIn, MaryValue)]
    -> Integer
    -> Maybe [(TxIn, MaryValue)]
selectByKey key inputs target
    | target <= 0 = Just []
    | total < target = Nothing
    | otherwise = Just (go 0 [] sorted)
  where
    sorted = L.sortOn (Down . key . snd) inputs
    total = sum (key . snd <$> inputs)
    go _ picked [] = reverse picked
    go acc picked (x@(_, value) : xs)
        | acc >= target = reverse picked
        | otherwise = go (acc + key value) (x : picked) xs

selectedToDisburseSelection
    :: PolicyID
    -> AssetName
    -> Integer
    -- ^ lovelace debited to the beneficiary
    -> Integer
    -- ^ USDM debited to the beneficiary
    -> [(TxIn, MaryValue)]
    -> Maybe DisburseTreasurySelection
selectedToDisburseSelection
    usdmPolicy
    usdmAsset
    beneficiaryLovelace
    beneficiaryUsdm
    selected
        | totalLovelace < beneficiaryLovelace = Nothing
        | totalUsdm < beneficiaryUsdm = Nothing
        | otherwise =
            Just
                DisburseTreasurySelection
                    { dtsInputs = txInToText . fst <$> selected
                    , dtsLeftoverLovelace =
                        totalLovelace - beneficiaryLovelace
                    , dtsLeftoverUsdm =
                        totalUsdm - beneficiaryUsdm
                    , dtsLeftoverOtherAssets =
                        nativeAssetsExcept
                            usdmPolicy
                            usdmAsset
                            (snd <$> selected)
                    }
      where
        totalLovelace = sum (lovelaceOf . snd <$> selected)
        totalUsdm =
            sum
                ( assetQuantity usdmPolicy usdmAsset
                    . snd
                    <$> selected
                )

lovelaceOf :: MaryValue -> Integer
lovelaceOf (MaryValue (Coin lovelace) _) = lovelace

assetQuantity :: PolicyID -> AssetName -> MaryValue -> Integer
assetQuantity policy asset (MaryValue _ (MultiAsset assets)) =
    maybe
        0
        (Map.findWithDefault 0 asset)
        (Map.lookup policy assets)

nativeAssetsExcept
    :: PolicyID
    -> AssetName
    -> [MaryValue]
    -> Map Text (Map Text Integer)
nativeAssetsExcept usdmPolicy usdmAsset values =
    Map.filter (not . Map.null) $
        Map.fromListWith
            (Map.unionWith (+))
            [ ( policyIdToText policy
              , Map.singleton (assetNameToText asset) quantity
              )
            | MaryValue _ (MultiAsset policies) <- values
            , (policy, assets) <- Map.toList policies
            , (asset, quantity) <- Map.toList assets
            , quantity /= 0
            , (policy, asset) /= (usdmPolicy, usdmAsset)
            ]

policyIdToText :: PolicyID -> Text
policyIdToText (PolicyID scriptHash) = scriptHashToHex scriptHash

assetNameToText :: AssetName -> Text
assetNameToText (AssetName raw) =
    TE.decodeUtf8Lenient (B16.encode (SBS.fromShort raw))

-- ----------------------------------------------------
-- Resolution
-- ----------------------------------------------------

{- | Inputs the disburse resolver needs from the CLI and
verified registry projection.
-}
data ResolverInput = ResolverInput
    { riNetwork :: !Text
    , riWalletAddrBech32 :: !Text
    , riBeneficiaryAddrBech32 :: !Text
    , riScope :: !ScopeId
    , riUnit :: !Unit
    , riAmount :: !Integer
    , riRegistry :: !RegistryView
    , riValidityHours :: !(Maybe Word16)
    -- ^ Operator-supplied @--validity-hours@; 'Nothing' = use
    --   the chain horizon ('Validity.AutoLongest').
    , riTreasuryTxIns :: ![TxIn]
    -- ^ Optional treasury TxIn allow-list. Empty means select from
    --   every UTxO currently found at the treasury address.
    }
    deriving stock (Eq, Show)

{- | Effects the resolver pulls from the provider boundary.
Wallet UTxOs use the shared pure-ADA summary required by
'selectWallet'; treasury UTxOs carry full values because
USDM disbursement selection and leftover preservation need
native assets.
-}
data ResolverEnv m = ResolverEnv
    { reEnvQueryWalletUtxos
        :: !(Text -> m [(Text, Integer, Bool)])
    , reEnvQueryTreasuryUtxos
        :: !(Text -> m [(TxIn, MaryValue)])
    , reEnvComputeUpperBound
        :: !( Validity.ValidityChoice
              -> m (Either Validity.HorizonError Word64)
            )
    -- ^ Horizon helper. 'Left' surfaces chain-horizon overshoot.
    }

data ResolverError
    = ResolverNetworkUnsupported !Text
    | ResolverWalletNetworkMismatch !Text !Text
    | ResolverBeneficiaryNetworkMismatch !Text !Text
    | ResolverAddressUnparseable !Text
    | ResolverScopeUnsupported !ScopeId
    | ResolverEmptyTreasuryUtxos
    | ResolverEmptyWalletUtxos
    | ResolverShortfall !Integer !Integer
    | ResolverWalletShortfall !Integer !Integer
    | ResolverUsdmConstantDecodeFailed !Text !String
    | -- | @riValidityHours = Just 0@.
      ResolverValidityHoursZero
    | -- | @riValidityHours = Just n@ overshoots chain horizon.
      ResolverValidityOvershoot !Validity.HorizonError
    | -- | One or more @--extra-tx-in@ refs were not returned
      --   by the wallet-address query (FR-009).
      ResolverExtraTxInNotOnWallet ![OutRef]
    | -- | @ResolverWalletShortfallWithExcludes available
      --   target refs@. Wallet-side shortfall after the
      --   operator's @--exclude-utxo@ set was applied
      --   (FR-008).
      ResolverWalletShortfallWithExcludes
        !Integer
        !Integer
        ![OutRef]
    | -- | @ResolverTreasuryShortfallWithExcludes available
      --   target refs@. Treasury-side shortfall after the
      --   operator's @--exclude-utxo@ set was applied to
      --   the per-unit treasury candidate pool (FR-008).
      ResolverTreasuryShortfallWithExcludes
        !Integer
        !Integer
        ![OutRef]
    deriving stock (Eq, Show)

{- | Drive the resolver's @reEnvComputeUpperBound@ effect with
the operator's optional @--validity-hours@.

* 'Nothing' → 'Validity.AutoLongest'.
* 'Just 0' → 'ResolverValidityHoursZero'.
* 'Just n', n > 0 → 'Validity.ExactlyHours n'; overshoot maps
  to 'ResolverValidityOvershoot'.
-}
resolveUpperBound
    :: (Monad m)
    => (Validity.ValidityChoice -> m (Either Validity.HorizonError Word64))
    -> Maybe Word16
    -> m (Either ResolverError Word64)
resolveUpperBound askUpperBound hours = case hours of
    Just 0 -> pure (Left ResolverValidityHoursZero)
    other -> do
        let choice =
                maybe Validity.AutoLongest Validity.ExactlyHours other
        result <- askUpperBound choice
        pure $ case result of
            Left horizonErr ->
                Left (ResolverValidityOvershoot horizonErr)
            Right slot -> Right slot

{- | Resolve chain-derived disburse inputs. Business
arithmetic stays in the pure selection helpers; this
function only validates address networks, queries the
provider boundary, selects wallet/treasury inputs, reads
the current tip, and projects the result into
'DisburseEnv'.
-}
resolveDisburseEnv
    :: (Monad m)
    => ResolverEnv m
    -> ResolverInput
    -> m (Either ResolverError DisburseEnv)
resolveDisburseEnv renv ri = do
    r <-
        resolveDisburseEnvIC
            renv
            (ExclusionSet [])
            (ForcedInclusionSet [])
            ri
    pure (fmap fst r)

{- | Variant of 'resolveDisburseEnv' that threads the
operator's @--exclude-utxo@ and @--extra-tx-in@ sets through
the disburse resolver (#184 Slice 3). Returns the resolved
'DisburseEnv' alongside the 'InputControlOutcome' the caller
uses to emit per-ref log lines.
-}
resolveDisburseEnvIC
    :: (Monad m)
    => ResolverEnv m
    -> ExclusionSet
    -> ForcedInclusionSet
    -> ResolverInput
    -> m (Either ResolverError (DisburseEnv, InputControlOutcome))
resolveDisburseEnvIC ResolverEnv{..} excl forced ri =
    case disburseNetworkConstants (riNetwork ri) of
        Left _ ->
            pure (Left (ResolverNetworkUnsupported (riNetwork ri)))
        Right nc ->
            case resolveConstants nc of
                Left err -> pure (Left err)
                Right (usdmPolicy, usdmAsset) ->
                    case validateResolverAddresses ri of
                        Left err -> pure (Left err)
                        Right () ->
                            resolveWith nc usdmPolicy usdmAsset
  where
    ExclusionSet exclRefs = excl
    ForcedInclusionSet forcedRefs = forced

    resolveWith nc usdmPolicy usdmAsset =
        case Map.lookup (riScope ri) (rvTreasuryByScope (riRegistry ri)) of
            Nothing ->
                pure (Left (ResolverScopeUnsupported (riScope ri)))
            Just refs -> do
                walletUtxos <- reEnvQueryWalletUtxos (riWalletAddrBech32 ri)
                if null walletUtxos
                    then pure (Left ResolverEmptyWalletUtxos)
                    else
                        let walletRefSet =
                                map walletCandidateRef walletUtxos
                            missing =
                                filter
                                    (`notElem` walletRefSet)
                                    forcedRefs
                        in  if not (null missing)
                                then
                                    pure
                                        ( Left
                                            ( ResolverExtraTxInNotOnWallet
                                                missing
                                            )
                                        )
                                else
                                    continueAfterWallet
                                        nc
                                        refs
                                        usdmPolicy
                                        usdmAsset
                                        walletUtxos
                                        walletRefSet

    continueAfterWallet nc refs usdmPolicy usdmAsset walletUtxos walletRefSet = do
        treasuryUtxos <- reEnvQueryTreasuryUtxos (trAddress refs)
        let selectableTreasuryUtxos =
                filterRequestedTreasuryUtxos
                    (riTreasuryTxIns ri)
                    treasuryUtxos
        if null selectableTreasuryUtxos
            then pure (Left ResolverEmptyTreasuryUtxos)
            else
                let (filteredWallet, _, _, _) =
                        filterPool
                            walletCandidateRef
                            excl
                            forced
                            walletUtxos
                    (filteredTreasury, _, _, _) =
                        filterPool
                            treasuryCandidateRef
                            excl
                            (ForcedInclusionSet [])
                            selectableTreasuryUtxos
                    treasuryRefSet =
                        map treasuryCandidateRef selectableTreasuryUtxos
                    outcome =
                        buildDisburseOutcome
                            exclRefs
                            walletRefSet
                            treasuryRefSet
                in  selectAndAssemble
                        nc
                        refs
                        usdmPolicy
                        usdmAsset
                        filteredWallet
                        filteredTreasury
                        outcome

    selectAndAssemble nc refs usdmPolicy usdmAsset walletUtxos treasuryUtxos outcome =
        case selectTreasuryForUnit usdmPolicy usdmAsset treasuryUtxos of
            Nothing ->
                pure
                    ( Left
                        ( treasuryShortfallError
                            (selectionShortfall usdmPolicy usdmAsset treasuryUtxos)
                        )
                    )
            Just treasurySelection ->
                case selectWallet walletFeeSlackLovelace walletUtxos of
                    Left WalletNoPureAda ->
                        pure
                            ( Left
                                ( walletShortfallError
                                    0
                                    walletFeeSlackLovelace
                                )
                            )
                    Left (WalletShortfall available required) ->
                        pure
                            ( Left
                                (walletShortfallError available required)
                            )
                    Right ([], _) ->
                        pure
                            ( Left
                                ( walletShortfallError
                                    0
                                    walletFeeSlackLovelace
                                )
                            )
                    Right (walletHead : walletTail, _) -> do
                        upper <-
                            resolveUpperBound
                                reEnvComputeUpperBound
                                (riValidityHours ri)
                        case upper of
                            Left e -> pure (Left e)
                            Right upperBound ->
                                let forcedTexts =
                                        map outRefText forcedRefs
                                    env =
                                        DisburseEnv
                                            { deNetwork = riNetwork ri
                                            , deUpperBoundSlot = upperBound
                                            , deNetworkConstants = nc
                                            , deRegistry = riRegistry ri
                                            , deScopeView =
                                                ScopeView
                                                    { svScope = riScope ri
                                                    , svRefs = refs
                                                    , svDefaultSigners =
                                                        defaultSignersForScope
                                                            ( rvOwners
                                                                ( riRegistry
                                                                    ri
                                                                )
                                                            )
                                                            (riScope ri)
                                                    }
                                            , deTreasurySelection =
                                                treasurySelection
                                            , deWalletSelection =
                                                WalletSelection
                                                    { wsTxIn = walletHead
                                                    , wsAddress =
                                                        riWalletAddrBech32 ri
                                                    , wsExtraTxIns =
                                                        forcedTexts
                                                            <> walletTail
                                                    }
                                            , deBeneficiaryAddrBech32 =
                                                riBeneficiaryAddrBech32 ri
                                            }
                                in  pure (Right (env, outcome))

    selectTreasuryForUnit usdmPolicy usdmAsset treasuryUtxos =
        case riUnit ri of
            ADA ->
                selectDisburseAda
                    usdmPolicy
                    usdmAsset
                    treasuryUtxos
                    (riAmount ri)
            USDM ->
                selectDisburseUsdm
                    usdmPolicy
                    usdmAsset
                    minUtxoDepositLovelace
                    treasuryUtxos
                    (riAmount ri)

    selectionShortfall usdmPolicy usdmAsset treasuryUtxos =
        case riUnit ri of
            ADA ->
                ResolverShortfall
                    (sum (lovelaceOf . snd <$> treasuryUtxos))
                    (riAmount ri)
            USDM ->
                let availableUsdm =
                        sum
                            ( assetQuantity usdmPolicy usdmAsset
                                . snd
                                <$> treasuryUtxos
                            )
                    availableLovelace =
                        sum (lovelaceOf . snd <$> treasuryUtxos)
                in  if availableUsdm < riAmount ri
                        then
                            ResolverShortfall
                                availableUsdm
                                (riAmount ri)
                        else
                            ResolverShortfall
                                availableLovelace
                                minUtxoDepositLovelace

    walletShortfallError avail target
        | null exclRefs =
            ResolverWalletShortfall avail target
        | otherwise =
            ResolverWalletShortfallWithExcludes
                avail
                target
                exclRefs

    treasuryShortfallError base
        | null exclRefs = base
        | otherwise = case base of
            ResolverShortfall avail target ->
                ResolverTreasuryShortfallWithExcludes
                    avail
                    target
                    exclRefs
            other -> other

walletCandidateRef :: (Text, Integer, Bool) -> OutRef
walletCandidateRef (ref, _, _) =
    case parseOutRef ref of
        Right r -> r
        Left e ->
            error
                ( "disburse-wizard: wallet candidate ref not parseable: "
                    <> T.unpack ref
                    <> ": "
                    <> T.unpack e
                )

treasuryCandidateRef :: (TxIn, MaryValue) -> OutRef
treasuryCandidateRef (txin, _) =
    case parseOutRef (txInToText txin) of
        Right r -> r
        Left e ->
            error
                ( "disburse-wizard: treasury candidate ref not parseable: "
                    <> T.unpack (txInToText txin)
                    <> ": "
                    <> T.unpack e
                )

{- | Build the per-ref pool-attribution outcome from an
exclusion list and the two candidate-pool reference sets.
Preserves exclusion-set input order so the wizard's log
lines stay deterministic.
-}
buildDisburseOutcome
    :: [OutRef]
    -> [OutRef]
    -> [OutRef]
    -> InputControlOutcome
buildDisburseOutcome excluded walletRefs treasuryRefs =
    let classify ref
            | ref `elem` walletRefs
            , ref `elem` treasuryRefs =
                Right (ref, Both)
            | ref `elem` walletRefs =
                Right (ref, WalletOnly)
            | ref `elem` treasuryRefs =
                Right (ref, TreasuryOnly)
            | otherwise = Left ref
        classified = map classify excluded
    in  InputControlOutcome
            { icoHits = rights classified
            , icoInert = lefts classified
            }

{- | Render the per-ref exclusion log line emitted by the
disburse wizards when @--exclude-utxo@ matches at least one
candidate. The prefix is wizard-specific
(@disburse-wizard:@ or @contingency-disburse-wizard:@); pool
attribution is rendered as @[wallet]@, @[treasury]@, or
@[both]@.
-}
renderDisburseExclusionLogLine
    :: Text -> OutRef -> PoolHit -> Text
renderDisburseExclusionLogLine prefix ref pool =
    prefix
        <> ": excluded utxo "
        <> outRefText ref
        <> " (operator-supplied) ["
        <> poolText
        <> "]"
  where
    poolText = case pool of
        WalletOnly -> "wallet"
        TreasuryOnly -> "treasury"
        Both -> "both"

{- | Append the operator's excluded refs to a base
shortfall message. Wizard-side shim that DELEGATES to the
shared 'renderShortfallWithExcludes' from
'Amaru.Treasury.Wizard.InputControl'; exposed so callers do
not have to thread the shared module's import through
every error site.
-}
renderDisburseWalletShortfallWithExcludes
    :: Text -> [OutRef] -> Text
renderDisburseWalletShortfallWithExcludes =
    renderShortfallWithExcludes

filterRequestedTreasuryUtxos
    :: [TxIn] -> [(TxIn, MaryValue)] -> [(TxIn, MaryValue)]
filterRequestedTreasuryUtxos requested utxos =
    case requested of
        [] -> utxos
        _ ->
            let requestedSet = Set.fromList requested
            in  filter ((`Set.member` requestedSet) . fst) utxos

validateResolverAddresses
    :: ResolverInput -> Either ResolverError ()
validateResolverAddresses ri = do
    checkAddressNetwork
        (riNetwork ri)
        (riWalletAddrBech32 ri)
        ResolverWalletNetworkMismatch
    checkAddressNetwork
        (riNetwork ri)
        (riBeneficiaryAddrBech32 ri)
        ResolverBeneficiaryNetworkMismatch

checkAddressNetwork
    :: Text
    -> Text
    -> (Text -> Text -> ResolverError)
    -> Either ResolverError ()
checkAddressNetwork requested address mismatch =
    case (networkFamily requested, addrNetwork address) of
        (Nothing, _) ->
            Left (ResolverNetworkUnsupported requested)
        (_, Nothing) ->
            Left (ResolverAddressUnparseable address)
        (Just want, Just observed)
            | observed /= want ->
                Left (mismatch requested (networkText observed))
        _ -> Right ()

networkFamily :: Text -> Maybe Network
networkFamily n = case T.toLower n of
    "mainnet" -> Just Mainnet
    "preprod" -> Just Testnet
    "preview" -> Just Testnet
    "devnet" -> Just Testnet
    _ -> Nothing

networkText :: Network -> Text
networkText = \case
    Mainnet -> "mainnet"
    Testnet -> "testnet"

disburseNetworkConstants :: Text -> Either String NetworkConstants
disburseNetworkConstants network =
    case T.toLower network of
        "devnet" -> networkConstants "mainnet"
        _ -> networkConstants network

resolveConstants
    :: NetworkConstants
    -> Either ResolverError (PolicyID, AssetName)
resolveConstants nc = do
    policy <- parsePolicyId (ncUsdmPolicy nc)
    asset <- parseAssetName (ncUsdmToken nc)
    pure (policy, asset)

parsePolicyId :: Text -> Either ResolverError PolicyID
parsePolicyId text = case decodeHexBytes 28 text of
    Left err -> Left (ResolverUsdmConstantDecodeFailed text err)
    Right bytes ->
        Right (PolicyID (ScriptHash (mkHash28 bytes)))

parseAssetName :: Text -> Either ResolverError AssetName
parseAssetName text = case decodeHexBytesAny text of
    Left err -> Left (ResolverUsdmConstantDecodeFailed text err)
    Right bytes -> Right (AssetName (SBS.toShort bytes))

-- ----------------------------------------------------
-- Signer resolution (mirrors SwapWizard)
-- ----------------------------------------------------

{- | Required signers always start with the selected scope
owner. Extra tokens add witnesses; each token is either a
known scope name/alias or a raw 28-byte hex keyhash.
Duplicates are removed after resolution while preserving
the first occurrence.
-}
resolveSigners
    :: DisburseEnv
    -> DisburseAnswers
    -> Either DisburseError [Text]
resolveSigners env ans = do
    let owners = rvOwners (deRegistry env)
    selectedOwners <-
        requiredSignersForScope owners (daScope ans)
    extraOwners <-
        traverse
            (resolveExtraSigner owners)
            (daExtraSigners ans)
    pure (L.nub (selectedOwners <> extraOwners))

requiredSignersForScope
    :: ScopeOwners -> ScopeId -> Either DisburseError [Text]
requiredSignersForScope owners scope =
    case scope of
        Contingency -> Right (allOwnedScopeSigners owners)
        _ -> (: []) <$> ownerForScope owners scope

defaultSignersForScope :: ScopeOwners -> ScopeId -> [Text]
defaultSignersForScope owners scope =
    case requiredSignersForScope owners scope of
        Right signers -> signers
        Left _ -> []

allOwnedScopeSigners :: ScopeOwners -> [Text]
allOwnedScopeSigners ScopeOwners{..} =
    [ soCore
    , soOps
    , soNetworkCompliance
    , soMiddleware
    ]

resolveExtraSigner
    :: ScopeOwners -> Text -> Either DisburseError Text
resolveExtraSigner owners t
    | isHex28 t = Right t
    | otherwise = case signerScopeFromText t of
        Just scope -> ownerForScope owners scope
        Nothing ->
            Left (DisburseSignerNotScopeOrHex28 t)

ownerForScope
    :: ScopeOwners -> ScopeId -> Either DisburseError Text
ownerForScope ScopeOwners{..} = \case
    CoreDevelopment -> Right soCore
    OpsAndUseCases -> Right soOps
    NetworkCompliance -> Right soNetworkCompliance
    Middleware -> Right soMiddleware
    Contingency ->
        -- Contingency has no on-chain owner key. When it is
        -- the selected disburse scope, 'requiredSignersForScope'
        -- expands it to all owned scope signers; as an explicit
        -- extra signer token, "contingency" remains invalid.
        Left
            ( DisburseSignerNotScopeOrHex28
                "contingency"
            )

signerScopeFromText :: Text -> Maybe ScopeId
signerScopeFromText t = case normaliseSignerToken t of
    "core" -> Just CoreDevelopment
    "core_development" -> Just CoreDevelopment
    "coredevelopment" -> Just CoreDevelopment
    "ops" -> Just OpsAndUseCases
    "ops_and_use_cases" -> Just OpsAndUseCases
    "opsandusecases" -> Just OpsAndUseCases
    "network" -> Just NetworkCompliance
    "network_compliance" -> Just NetworkCompliance
    "networkcompliance" -> Just NetworkCompliance
    "middleware" -> Just Middleware
    "contingency" -> Just Contingency
    _ -> Nothing

normaliseSignerToken :: Text -> Text
normaliseSignerToken =
    T.map dashToUnderscore . T.toLower
  where
    dashToUnderscore '-' = '_'
    dashToUnderscore c = c

isHex28 :: Text -> Bool
isHex28 t = T.length t == 56 && T.all isHexChar t
  where
    isHexChar c =
        isDigit c
            || (c >= 'a' && c <= 'f')
            || (c >= 'A' && c <= 'F')

-- ----------------------------------------------------
-- Field projection (data-model §7.1)
-- ----------------------------------------------------

mkWallet :: WalletSelection -> DisburseWalletJSON
mkWallet ws =
    DisburseWalletJSON
        { dwjTxIn = wsTxIn ws
        , dwjAddress = wsAddress ws
        }

mkScope :: DisburseEnv -> DisburseAnswers -> DisburseScopeJSON
mkScope env ans =
    let r = deRegistry env
        s = svRefs (deScopeView env)
        sel = deTreasurySelection env
    in  DisburseScopeJSON
            { dsjId = scopeText (daScope ans)
            , dsjTreasuryAddress = trAddress s
            , dsjTreasuryUtxos = dtsInputs sel
            , dsjTreasuryLeftoverLovelace =
                dtsLeftoverLovelace sel
            , dsjTreasuryLeftoverUsdm =
                dtsLeftoverUsdm sel
            , dsjTreasuryLeftoverOtherAssets =
                dtsLeftoverOtherAssets sel
            , dsjTreasuryScriptHash = trScriptHash s
            , dsjPermissionsRewardAccount =
                trPermissionsRewardAccount s
            , dsjScopesDeployedAt = rvScopesDeployedAt r
            , dsjPermissionsDeployedAt =
                rvPermissionsDeployedAt r
            , dsjTreasuryDeployedAt =
                rvTreasuryDeployedAt r
            , dsjRegistryDeployedAt =
                rvRegistryDeployedAt r
            , dsjRegistryPolicyId = rvRegistryPolicyId r
            }

mkDisburse
    :: DisburseEnv -> DisburseAnswers -> DisburseInputsJSON
mkDisburse env ans =
    let nc = deNetworkConstants env
    in  DisburseInputsJSON
            { dijUnit = unitText (daUnit ans)
            , dijAmount = daAmount ans
            , dijBeneficiaryAddress =
                deBeneficiaryAddrBech32 env
            , dijUsdmPolicy = ncUsdmPolicy nc
            , dijUsdmToken = ncUsdmToken nc
            }

mkRationale :: DisburseAnswers -> DisburseRationaleJSON
mkRationale ans =
    let r = daRationale ans
        labelDefault = case daUnit ans of
            ADA -> "Disburse ADA"
            USDM -> "Disburse USDM"
    in  DisburseRationaleJSON
            { drjEvent =
                fromMaybe "disburse" (raEvent r)
            , drjLabel =
                fromMaybe labelDefault (raLabel r)
            , drjDescription = raDescription r
            , drjJustification = raJustification r
            , drjDestinationLabel = raDestinationLabel r
            , drjReferences = daRationaleReferences ans
            }

unitText :: Unit -> Text
unitText = \case
    ADA -> "ada"
    USDM -> "usdm"

mkTreasuryWallet :: WalletSelection -> WalletJSON
mkTreasuryWallet ws =
    WalletJSON
        { wjTxIn = wsTxIn ws
        , wjAddress = wsAddress ws
        , wjExtraTxIns = wsExtraTxIns ws
        }

mkTreasuryScope :: DisburseEnv -> DisburseAnswers -> ScopeJSON
mkTreasuryScope env ans =
    let r = deRegistry env
        s = svRefs (deScopeView env)
        sel = deTreasurySelection env
    in  ScopeJSON
            { sjId = scopeText (daScope ans)
            , sjTreasuryAddress = trAddress s
            , sjTreasuryUtxos = dtsInputs sel
            , sjTreasuryLeftoverLovelace =
                dtsLeftoverLovelace sel
            , sjTreasuryLeftoverUsdm =
                dtsLeftoverUsdm sel
            , sjTreasuryLeftoverOtherAssets =
                dtsLeftoverOtherAssets sel
            , sjTreasuryScriptHash = trScriptHash s
            , sjPermissionsRewardAccount =
                trPermissionsRewardAccount s
            , sjScopesDeployedAt = rvScopesDeployedAt r
            , sjPermissionsDeployedAt =
                rvPermissionsDeployedAt r
            , sjTreasuryDeployedAt =
                rvTreasuryDeployedAt r
            , sjRegistryDeployedAt =
                rvRegistryDeployedAt r
            , sjRegistryPolicyId = rvRegistryPolicyId r
            }

mkTreasuryDisburse
    :: DisburseEnv -> DisburseAnswers -> DisburseInputs
mkTreasuryDisburse env ans =
    let nc = deNetworkConstants env
    in  DisburseInputs
            { diUnit = unitText (daUnit ans)
            , diAmount = daAmount ans
            , diBeneficiaryAddress =
                deBeneficiaryAddrBech32 env
            , diUsdmPolicy = ncUsdmPolicy nc
            , diUsdmToken = ncUsdmToken nc
            }

mkTreasuryRationale :: DisburseAnswers -> RationaleJSON
mkTreasuryRationale ans =
    let r = daRationale ans
        labelDefault = case daUnit ans of
            ADA -> "Disburse ADA"
            USDM -> "Disburse USDM"
    in  RationaleJSON
            { rjEvent =
                fromMaybe "disburse" (raEvent r)
            , rjLabel =
                fromMaybe labelDefault (raLabel r)
            , rjDescription = raDescription r
            , rjJustification = raJustification r
            , rjDestinationLabel = raDestinationLabel r
            , rjReferences = daRationaleReferences ans
            }
