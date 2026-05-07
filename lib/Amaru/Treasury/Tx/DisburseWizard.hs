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

      -- * Pure translation
    , disburseToIntentJSON
    , disburseToTreasuryIntent
    ) where

import Control.Monad (when)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Char (isDigit)
import Data.List qualified as L
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64, Word8)

import Amaru.Treasury.Constants (Unit (..))
import Amaru.Treasury.IntentJSON
    ( Action (..)
    , DisburseInputs (..)
    , RationaleJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    )
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
    ( NetworkConstants (..)
    , RationaleAnswers (..)
    , RegistryView (..)
    , ScopeOwners (..)
    , ScopeView (..)
    , TreasuryRefs (..)
    , WalletSelection (..)
    )

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
    , daValidityHours :: !Word8
    -- ^ Range [1, 48]; enforced by the translation.
    , daRationale :: !RationaleAnswers
    , daExtraSigners :: ![Text]
    -- ^ Each token is either a scope name (lowercased,
    --   e.g. @"ops_and_use_cases"@) resolved through
    --   the registry owners, or a raw 28-byte hex
    --   keyhash. The selected scope's owner is always
    --   inferred and prepended.
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
    , deCurrentTip :: !Word64
    -- ^ chain tip slot at the time of resolution
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
    | -- | @daValidityHours@ outside [1, 48].
      DisburseValidityHoursOutOfRange !Word8
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
            <*> o .: "validityHours"
            <*> o .: "rationale"
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
            <*> o .: "currentTip"
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
            , dijValidityUpperBoundSlot =
                deCurrentTip env
                    + ncSlotsPerHour
                        (deNetworkConstants env)
                        * fromIntegral (daValidityHours ans)
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
            , tiValidityUpperBoundSlot =
                deCurrentTip env
                    + ncSlotsPerHour
                        (deNetworkConstants env)
                        * fromIntegral (daValidityHours ans)
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
    let h = daValidityHours ans
    when
        (h == 0 || h > 48)
        (Left (DisburseValidityHoursOutOfRange h))
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
    selectedOwner <- ownerForScope owners (daScope ans)
    extraOwners <-
        traverse
            (resolveExtraSigner owners)
            (daExtraSigners ans)
    pure (L.nub (selectedOwner : extraOwners))

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
        -- Contingency has no on-chain owner key; the scope
        -- exists but cannot sign disbursements directly.
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
            }
