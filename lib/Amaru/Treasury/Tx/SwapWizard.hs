{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.SwapWizard
Description : Typed answers + resolved env -> SwapIntentJSON
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The wizard's pure core. 'SwapWizardQ' captures the fields a
human actually decides for a swap; 'WizardEnv' captures
everything the resolver pulled from the registry, the
backend, and the curated 'NetworkConstants' table. Their
combination feeds 'wizardToIntentJSON', which produces the
typed
'Amaru.Treasury.Tx.SwapIntentJSON.SwapIntentJSON' the
existing build path consumes.

The translation here is total and pure — no IO. The
resolver and the prompt loop live elsewhere (see
@app/amaru-treasury-tx/Main.hs@ in a later phase).
-}
module Amaru.Treasury.Tx.SwapWizard
    ( -- * Answers
      SwapWizardQ (..)
    , RationaleAnswers (..)

      -- * Resolved environment
    , WizardEnv (..)
    , NetworkConstants (..)
    , RegistryView (..)
    , ScopeOwners (..)
    , TreasuryRefs (..)
    , ScopeView (..)
    , TreasurySelection (..)
    , WalletSelection (..)

      -- * Translation
    , WizardError (..)
    , wizardToIntentJSON
    , encodeIntentJSON
    ) where

import Control.Monad (when)
import Data.Aeson
    ( FromJSON (..)
    , withObject
    , (.:)
    , (.:?)
    )
import Data.Aeson.Encode.Pretty
    ( Config (..)
    , Indent (..)
    , NumberFormat (..)
    , encodePretty'
    )
import Data.Aeson.Types qualified as A
import Data.ByteString.Lazy (ByteString)
import Data.Char (isDigit)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word64, Word8)

import Amaru.Treasury.Scope (ScopeId, scopeFromText)
import Amaru.Treasury.Tx.SwapIntentJSON
    ( RationaleInputs (..)
    , ScopeInputs (..)
    , SwapInputs (..)
    , SwapIntentJSON (..)
    , Wallet (..)
    )

-- ----------------------------------------------------
-- Answers
-- ----------------------------------------------------

{- | Free-form rationale answers. Mirrors
'Amaru.Treasury.Tx.SwapIntentJSON.RationaleInputs' minus
the optional/default treatment that the JSON layer
already encodes.
-}
data RationaleAnswers = RationaleAnswers
    { raDescription :: !Text
    , raJustification :: !Text
    , raDestinationLabel :: !Text
    , raEvent :: !(Maybe Text)
    -- ^ Defaults to @"disburse"@ when absent.
    , raLabel :: !(Maybe Text)
    -- ^ Defaults to @"Swap ADA<->USDM"@ when absent.
    }
    deriving (Eq, Show)

{- | Real intent — the typed answers a human gives the
wizard. Sister of
'Amaru.Treasury.Tx.SwapIntentJSON.SwapIntentJSON' but
restricted to fields the user actually chooses.
-}
data SwapWizardQ = SwapWizardQ
    { wqScope :: !ScopeId
    , wqAmountLovelace :: !Integer
    , wqChunkSizeLovelace :: !Integer
    , wqRateNumerator :: !Integer
    , wqRateDenominator :: !Integer
    , wqValidityHours :: !Word8
    -- ^ Range [1, 48]; enforced by 'wizardToIntentJSON'.
    , wqRationale :: !RationaleAnswers
    , wqSignersOverride :: !(Maybe [Text])
    -- ^ 28-byte hex strings; @Nothing@ uses the scope's
    --   default owner set (the four-scope-owner list per
    --   @swap_order.sh@).
    }
    deriving (Eq, Show)

-- ----------------------------------------------------
-- Resolved environment
-- ----------------------------------------------------

{- | Per-network constants: SundaeSwap V3 order address,
USDM policy/token, sundae protocol fee, slot conversion,
default pool. The resolver builds this from a curated
table; never queried at run time.
-}
data NetworkConstants = NetworkConstants
    { ncSwapOrderAddress :: !Text
    -- ^ bech32 @addr1...@ of the Sundae V3 order contract
    , ncUsdmPolicy :: !Text
    -- ^ hex policy id of USDM
    , ncUsdmToken :: !Text
    -- ^ hex asset name of USDM
    , ncSundaeProtocolFeeLovelace :: !Integer
    , ncExtraPerChunkLovelace :: !Integer
    -- ^ Sundae protocol fee + min UTxO deposit added
    --   per swap-order chunk
    , ncSlotsPerHour :: !Word64
    , ncDefaultPoolId :: !Text
    -- ^ 28-byte hex of the default ADA<->USDM pool
    }
    deriving (Eq, Show)

-- | Owners pulled from the registry walk. 28-byte hex.
data ScopeOwners = ScopeOwners
    { soCore :: !Text
    , soOps :: !Text
    , soNetworkCompliance :: !Text
    , soMiddleware :: !Text
    }
    deriving (Eq, Show)

{- | Per-scope treasury references (address, script hash,
permissions reward account).
-}
data TreasuryRefs = TreasuryRefs
    { trAddress :: !Text
    -- ^ bech32 address of the treasury contract
    , trScriptHash :: !Text
    -- ^ 28-byte hex of the treasury script
    , trPermissionsRewardAccount :: !Text
    -- ^ 28-byte hex of the permissions reward account
    }
    deriving (Eq, Show)

{- | Registry walk projection. Carries everything pulled
out of the registry NFT lookup. The
'rvTreasuryByScope' map handles the per-scope fields;
the deployed-at refs and policy id are global.
-}
data RegistryView = RegistryView
    { rvScopesDeployedAt :: !Text
    -- ^ @"<txid>#<ix>"@
    , rvPermissionsDeployedAt :: !Text
    , rvTreasuryDeployedAt :: !Text
    , rvRegistryDeployedAt :: !Text
    , rvRegistryPolicyId :: !Text
    , rvOwners :: !ScopeOwners
    , rvTreasuryByScope :: !(Map ScopeId TreasuryRefs)
    }
    deriving (Eq, Show)

{- | The picked-by-scope projection; the fields the
translation actually consumes.
-}
data ScopeView = ScopeView
    { svScope :: !ScopeId
    , svRefs :: !TreasuryRefs
    , svDefaultSigners :: ![Text]
    -- ^ 28-byte hex; defaults to all four scope owners
    --   per @swap_order.sh@
    }
    deriving (Eq, Show)

{- | Pre-selected treasury inputs and the leftover
lovelace returned to the treasury.
-}
data TreasurySelection = TreasurySelection
    { tsInputs :: ![Text]
    -- ^ @"<txid>#<ix>"@
    , tsLeftoverLovelace :: !Integer
    }
    deriving (Eq, Show)

-- | The wallet UTxO used as fuel + collateral.
data WalletSelection = WalletSelection
    { wsTxIn :: !Text
    , wsAddress :: !Text
    }
    deriving (Eq, Show)

{- | Everything the resolver hands the pure translation.
The pure translation reads only this record (plus the
'SwapWizardQ' answers); it never performs IO.
-}
data WizardEnv = WizardEnv
    { weNetwork :: !Text
    -- ^ @"mainnet"@ / @"preprod"@; informational
    , weCurrentTip :: !Word64
    , weNetworkConstants :: !NetworkConstants
    , weRegistry :: !RegistryView
    , weScopeView :: !ScopeView
    , weTreasurySelection :: !TreasurySelection
    , weWalletSelection :: !WalletSelection
    }
    deriving (Eq, Show)

-- ----------------------------------------------------
-- FromJSON instances (for fixtures)
-- ----------------------------------------------------

instance FromJSON RationaleAnswers where
    parseJSON = withObject "RationaleAnswers" $ \o ->
        RationaleAnswers
            <$> o .: "description"
            <*> o .: "justification"
            <*> o .: "destinationLabel"
            <*> o .:? "event"
            <*> o .:? "label"

instance FromJSON SwapWizardQ where
    parseJSON = withObject "SwapWizardQ" $ \o -> do
        scopeText' <- o .: "scope"
        scope <- case scopeFromText scopeText' of
            Right s -> pure s
            Left e -> fail e
        SwapWizardQ scope
            <$> o .: "amountLovelace"
            <*> o .: "chunkSizeLovelace"
            <*> o .: "rateNumerator"
            <*> o .: "rateDenominator"
            <*> o .: "validityHours"
            <*> o .: "rationale"
            <*> o .:? "signersOverride"

instance FromJSON NetworkConstants where
    parseJSON = withObject "NetworkConstants" $ \o ->
        NetworkConstants
            <$> o .: "swapOrderAddress"
            <*> o .: "usdmPolicy"
            <*> o .: "usdmToken"
            <*> o .: "sundaeProtocolFeeLovelace"
            <*> o .: "extraPerChunkLovelace"
            <*> o .: "slotsPerHour"
            <*> o .: "defaultPoolId"

instance FromJSON ScopeOwners where
    parseJSON = withObject "ScopeOwners" $ \o ->
        ScopeOwners
            <$> o .: "core"
            <*> o .: "ops"
            <*> o .: "networkCompliance"
            <*> o .: "middleware"

instance FromJSON TreasuryRefs where
    parseJSON = withObject "TreasuryRefs" $ \o ->
        TreasuryRefs
            <$> o .: "address"
            <*> o .: "scriptHash"
            <*> o .: "permissionsRewardAccount"

instance FromJSON RegistryView where
    parseJSON = withObject "RegistryView" $ \o -> do
        rawByScope <-
            o .: "treasuryByScope"
                :: A.Parser (Map Text TreasuryRefs)
        byScope <- traverseKeysScope rawByScope
        RegistryView
            <$> o .: "scopesDeployedAt"
            <*> o .: "permissionsDeployedAt"
            <*> o .: "treasuryDeployedAt"
            <*> o .: "registryDeployedAt"
            <*> o .: "registryPolicyId"
            <*> o .: "owners"
            <*> pure byScope

traverseKeysScope
    :: Map Text TreasuryRefs
    -> A.Parser (Map ScopeId TreasuryRefs)
traverseKeysScope =
    fmap Map.fromList . traverse step . Map.toList
  where
    step (k, v) = case scopeFromText k of
        Right s -> pure (s, v)
        Left e -> fail e

instance FromJSON ScopeView where
    parseJSON = withObject "ScopeView" $ \o -> do
        scopeText' <- o .: "scope"
        scope <- case scopeFromText scopeText' of
            Right s -> pure s
            Left e -> fail e
        ScopeView scope
            <$> o .: "refs"
            <*> o .: "defaultSigners"

instance FromJSON TreasurySelection where
    parseJSON = withObject "TreasurySelection" $ \o ->
        TreasurySelection
            <$> o .: "inputs"
            <*> o .: "leftoverLovelace"

instance FromJSON WalletSelection where
    parseJSON = withObject "WalletSelection" $ \o ->
        WalletSelection
            <$> o .: "txIn"
            <*> o .: "address"

instance FromJSON WizardEnv where
    parseJSON = withObject "WizardEnv" $ \o ->
        WizardEnv
            <$> o .: "network"
            <*> o .: "currentTip"
            <*> o .: "networkConstants"
            <*> o .: "registry"
            <*> o .: "scopeView"
            <*> o .: "treasurySelection"
            <*> o .: "walletSelection"

-- ----------------------------------------------------
-- Translation
-- ----------------------------------------------------

-- | Domain errors detectable from the typed answers.
data WizardError
    = WizardChunkSizeNotPositive
    | WizardChunkSizeExceedsAmount
    | WizardAmountNotPositive
    | WizardValidityHoursOutOfRange !Word8
    | WizardRateDenominatorZero
    | WizardSignerNotHex28 !Text
    | -- | wizard accepts only Core/Ops/NetworkCompliance/
      --   Middleware; @Contingency@ is rejected
      WizardScopeUnsupported !ScopeId
    deriving (Eq, Show)

{- | Pure, total translation from a 'WizardEnv' and a
'SwapWizardQ' to a 'SwapIntentJSON'.

The mapping is the contract documented in
@specs\/002-swap-wizard\/data-model.md §4@. Local
validation produces a 'WizardError'; resolver-level
failures (empty UTxOs, unknown network, registry walk
failure) are caught by the resolver and never reach this
function.
-}
wizardToIntentJSON
    :: WizardEnv
    -> SwapWizardQ
    -> Either WizardError SwapIntentJSON
wizardToIntentJSON we q = do
    validate q
    signers <- resolveSigners we q
    pure
        SwapIntentJSON
            { sijWallet = mkWallet (weWalletSelection we)
            , sijScope = mkScope we
            , sijSwap = mkSwap we q
            , sijSigners = signers
            , sijValidityUpperBoundSlot =
                weCurrentTip we
                    + ncSlotsPerHour
                        (weNetworkConstants we)
                        * fromIntegral (wqValidityHours q)
            , sijRationale = mkRationale (wqRationale q)
            }

-- | Domain-level validation per FR-012 + data-model §3.
validate :: SwapWizardQ -> Either WizardError ()
validate q = do
    when
        (wqAmountLovelace q <= 0)
        (Left WizardAmountNotPositive)
    when
        (wqChunkSizeLovelace q <= 0)
        (Left WizardChunkSizeNotPositive)
    when
        ( wqChunkSizeLovelace q
            > wqAmountLovelace q
        )
        (Left WizardChunkSizeExceedsAmount)
    when
        (wqRateDenominator q == 0)
        (Left WizardRateDenominatorZero)
    let h = wqValidityHours q
    when
        (h == 0 || h > 48)
        (Left (WizardValidityHoursOutOfRange h))

{- | Default signer set is the four scope-owner key
hashes; an explicit override replaces it. Each
override entry is validated as 28-byte hex.
-}
resolveSigners
    :: WizardEnv -> SwapWizardQ -> Either WizardError [Text]
resolveSigners we q =
    case wqSignersOverride q of
        Nothing ->
            Right (svDefaultSigners (weScopeView we))
        Just xs -> traverse checkHex28 xs
  where
    checkHex28 t
        | T.length t == 56
        , T.all isHexChar t =
            Right t
        | otherwise =
            Left (WizardSignerNotHex28 t)
    isHexChar c =
        isDigit c
            || (c >= 'a' && c <= 'f')
            || (c >= 'A' && c <= 'F')

mkWallet :: WalletSelection -> Wallet
mkWallet ws =
    Wallet
        { wTxIn = wsTxIn ws
        , wAddress = wsAddress ws
        }

mkScope :: WizardEnv -> ScopeInputs
mkScope we =
    let r = weRegistry we
        s = svRefs (weScopeView we)
        sel = weTreasurySelection we
    in  ScopeInputs
            { siTreasuryAddress_ = trAddress s
            , siTreasuryUtxos_ = tsInputs sel
            , siTreasuryLeftoverLovelace_ =
                tsLeftoverLovelace sel
            , siTreasuryScriptHash_ = trScriptHash s
            , siPermissionsRewardAccount_ =
                trPermissionsRewardAccount s
            , siScopesDeployedAt_ = rvScopesDeployedAt r
            , siPermissionsDeployedAt_ =
                rvPermissionsDeployedAt r
            , siTreasuryDeployedAt_ =
                rvTreasuryDeployedAt r
            , siRegistryDeployedAt_ =
                rvRegistryDeployedAt r
            , siRegistryPolicyId_ = rvRegistryPolicyId r
            }

mkSwap :: WizardEnv -> SwapWizardQ -> SwapInputs
mkSwap we q =
    let nc = weNetworkConstants we
        os = rvOwners (weRegistry we)
    in  SwapInputs
            { swSwapOrderAddress = ncSwapOrderAddress nc
            , swChunkSizeLovelace = wqChunkSizeLovelace q
            , swAmountLovelace = wqAmountLovelace q
            , swExtraPerChunkLovelace =
                ncExtraPerChunkLovelace nc
            , swRateNumerator = wqRateNumerator q
            , swRateDenominator = wqRateDenominator q
            , swPoolId = ncDefaultPoolId nc
            , swCoreOwner = soCore os
            , swOpsOwner = soOps os
            , swNetworkComplianceOwner =
                soNetworkCompliance os
            , swMiddlewareOwner = soMiddleware os
            , swSundaeProtocolFeeLovelace =
                ncSundaeProtocolFeeLovelace nc
            , swUsdmPolicy = ncUsdmPolicy nc
            , swUsdmToken = ncUsdmToken nc
            }

mkRationale :: RationaleAnswers -> RationaleInputs
mkRationale r =
    RationaleInputs
        { riEvent = fromMaybe "disburse" (raEvent r)
        , riLabel =
            fromMaybe "Swap ADA<->USDM" (raLabel r)
        , riDescription = raDescription r
        , riDestinationLabel = raDestinationLabel r
        , riJustification = raJustification r
        }

{- | Stable pretty-printed encoder for 'SwapIntentJSON',
used by golden tests. Fixed config: 4-space indent,
@aeson-pretty@ default key ordering (alphabetical), no
unicode escapes for ASCII text, decimals for numbers.
-}
encodeIntentJSON :: SwapIntentJSON -> ByteString
encodeIntentJSON = encodePretty' cfg
  where
    cfg =
        Config
            { confIndent = Spaces 4
            , confCompare = compare
            , confNumFormat = Generic
            , confTrailingNewline = True
            }
