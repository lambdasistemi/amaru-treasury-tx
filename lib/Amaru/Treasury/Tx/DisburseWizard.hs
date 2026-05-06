{- |
Module      : Amaru.Treasury.Tx.DisburseWizard
Description : Typed-Q&A wizard for the disburse subcommand
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Sister of
[`Amaru.Treasury.Tx.SwapWizard`](Amaru.Treasury.Tx.SwapWizard.html)
for the disburse action: typed operator answers + a
chain-resolved environment, fed into a pure translation
to 'DisburseIntentJSON'.

This phase 2 cut wires the answer + environment types
plus the local validation enum. The pure translation
('disburseToIntentJSON') and IO resolver
('resolveDisburseEnv') land in phases 3 and 4.

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
    ) where

import Data.Map.Strict (Map)
import Data.Text (Text)
import Data.Word (Word64, Word8)

import Amaru.Treasury.Constants (Unit (..))
import Amaru.Treasury.Scope (ScopeId)
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
