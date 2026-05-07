{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

{- |
Module      : Amaru.Treasury.Tx.SwapWizard
Description : Typed answers + resolved env -> TreasuryIntent 'Swap
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The wizard's pure core. 'SwapWizardQ' captures the fields a
human actually decides for a swap; 'WizardEnv' captures
everything the resolver pulled from the registry, the
backend, and the curated 'NetworkConstants' table. Their
combination feeds 'wizardToTreasuryIntent', which
produces the typed
'Amaru.Treasury.IntentJSON.TreasuryIntent' \'Swap the
unified @tx-build@ subcommand consumes.

The translation here is total and pure — no IO. The
resolver and the prompt loop live elsewhere (see
@app/amaru-treasury-tx/Main.hs@).
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
    , wizardToTreasuryIntent

      -- * Resolution
    , ResolverInput (..)
    , ResolverError (..)
    , ResolverEnv (..)
    , registryViewFromVerified
    , networkConstants
    , selectTreasury
    , selectWallet
    , addrNetwork
    , resolveWizardEnv

      -- * Re-usable helpers
    , txInToText
    ) where

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.Address
    ( Addr (..)
    , getNetwork
    , serialiseAddr
    )
import Cardano.Ledger.BaseTypes
    ( Network (..)
    , txIxToInt
    )
import Cardano.Ledger.Hashes
    ( KeyHash (..)
    , extractHash
    )
import Cardano.Ledger.Keys (KeyRole (Witness))
import Cardano.Ledger.TxIn
    ( TxId (..)
    , TxIn (..)
    )
import Codec.Binary.Bech32 qualified as Bech32
import Control.Monad (when)
import Data.Aeson
    ( FromJSON (..)
    , withObject
    , (.:)
    , (.:?)
    )
import Data.Aeson.Types qualified as A
import Data.ByteString.Base16 qualified as B16
import Data.Function (on)
import Data.List qualified as L
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, maybeToList)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64, Word8)

import Amaru.Treasury.IntentJSON qualified as TI
import Amaru.Treasury.Registry.Derive (scriptHashToHex)
import Amaru.Treasury.Registry.Verify
    ( VerifiedRegistry (..)
    , VerifiedScope (..)
    )
import Amaru.Treasury.Scope
    ( ScopeId
        ( Contingency
        , CoreDevelopment
        , Middleware
        , NetworkCompliance
        , OpsAndUseCases
        )
    , scopeFromText
    , scopeText
    )
import Amaru.Treasury.Wizard.Common
    ( isHex28
    , signerScopeFromText
    )

-- ----------------------------------------------------
-- Answers
-- ----------------------------------------------------

{- | Free-form rationale answers. Mirrors
'Amaru.Treasury.IntentJSON.RationaleJSON' minus the
optional/default treatment that the JSON layer already
encodes.
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
'Amaru.Treasury.IntentJSON.TreasuryIntent' \'Swap but
restricted to fields the user actually chooses.
-}
data SwapWizardQ = SwapWizardQ
    { wqScope :: !ScopeId
    , wqAmountLovelace :: !Integer
    , wqChunkSizeLovelace :: !Integer
    , wqRateNumerator :: !Integer
    , wqRateDenominator :: !Integer
    , wqValidityHours :: !Word8
    -- ^ Range [1, 48]; enforced by 'wizardToTreasuryIntent'.
    , wqRationale :: !RationaleAnswers
    , wqExtraSigners :: ![Text]
    -- ^ Extra signer tokens. Each token is either a
    --   scope name/alias, resolved to that scope owner's
    --   key hash from the registry walk, or a raw
    --   28-byte key hash hex string. The selected scope
    --   owner is always inferred separately.
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
    -- ^ 28-byte hex; defaults to the selected scope
    --   owner. Kept in the environment for traceability;
    --   'resolveSigners' derives the same owner from the
    --   registry view and appends any extra signers.
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
        extraSigners <- fromMaybe [] <$> o .:? "extraSigners"
        -- Legacy fixture/input key; after the signer model change,
        -- these tokens are treated as extras, not replacements.
        legacySigners <- fromMaybe [] <$> o .:? "signersOverride"
        SwapWizardQ scope
            <$> o .: "amountLovelace"
            <*> o .: "chunkSizeLovelace"
            <*> o .: "rateNumerator"
            <*> o .: "rateDenominator"
            <*> o .: "validityHours"
            <*> o .: "rationale"
            <*> pure (extraSigners <> legacySigners)

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
    | WizardSignerNotScopeOrHex28 !Text
    | -- | wizard accepts only Core/Ops/NetworkCompliance/
      --   Middleware; @Contingency@ is rejected
      WizardScopeUnsupported !ScopeId
    deriving (Eq, Show)

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
    when
        (wqScope q == Contingency)
        (Left (WizardScopeUnsupported Contingency))
    let h = wqValidityHours q
    when
        (h == 0 || h > 48)
        (Left (WizardValidityHoursOutOfRange h))

{- | Required signers always start with the selected scope
owner. User-supplied signer tokens add witnesses; each
extra token may be a known scope name/alias or a raw
28-byte key hash. Duplicate tokens are removed after
resolution while preserving the first occurrence.
-}
resolveSigners
    :: WizardEnv -> SwapWizardQ -> Either WizardError [Text]
resolveSigners we q = do
    selectedOwner <-
        ownerForScope
            (rvOwners (weRegistry we))
            (wqScope q)
    extraOwners <-
        traverse
            (resolveExtraSigner (rvOwners (weRegistry we)))
            (wqExtraSigners q)
    pure (L.nub (selectedOwner : extraOwners))

resolveExtraSigner
    :: ScopeOwners -> Text -> Either WizardError Text
resolveExtraSigner owners t
    | isHex28 t = Right t
    | otherwise =
        case signerScopeFromText t of
            Just scope -> ownerForScope owners scope
            Nothing -> Left (WizardSignerNotScopeOrHex28 t)

ownerForScope :: ScopeOwners -> ScopeId -> Either WizardError Text
ownerForScope owners scope =
    maybe
        (Left (WizardScopeUnsupported scope))
        Right
        (scopeOwnerText owners scope)

scopeOwnerText :: ScopeOwners -> ScopeId -> Maybe Text
scopeOwnerText ScopeOwners{..} = \case
    CoreDevelopment -> Just soCore
    OpsAndUseCases -> Just soOps
    NetworkCompliance -> Just soNetworkCompliance
    Middleware -> Just soMiddleware
    Contingency -> Nothing

-- 'isHex28', 'normaliseSignerToken', and 'signerScopeFromText'
-- moved to 'Amaru.Treasury.Wizard.Common' in T009. Imported above.

{- | Convert wizard answers + resolved env into a typed
'TI.TreasuryIntent' parameterised at @\'Swap@.

This is the wizard's pure output: the unified
'TI.TreasuryIntent' the @tx-build@ subcommand consumes.
The translation is total — domain validation reports a
'WizardError', signer resolution maps scope names /
aliases / 28-byte hex through the registry walk, and
every other field is a direct projection of the resolver
'WizardEnv' or a constant from the curated
'NetworkConstants' table (the JSON schema's v1
additions: top-level @network@, @scope.id@,
@scope.treasuryLeftoverUsdm@,
@scope.treasuryLeftoverOtherAssets@).
-}
wizardToTreasuryIntent
    :: WizardEnv
    -> SwapWizardQ
    -> Either WizardError (TI.TreasuryIntent 'TI.Swap)
wizardToTreasuryIntent we q = do
    validate q
    signers <- resolveSigners we q
    let r = weRegistry we
        s = svRefs (weScopeView we)
        sel = weTreasurySelection we
        wal = weWalletSelection we
        nc = weNetworkConstants we
        os = rvOwners r
        rat = wqRationale q
    pure
        TI.TreasuryIntent
            { TI.tiSAction = TI.SSwap
            , TI.tiSchema = 1
            , TI.tiNetwork = weNetwork we
            , TI.tiWallet =
                TI.WalletJSON
                    { TI.wjTxIn = wsTxIn wal
                    , TI.wjAddress = wsAddress wal
                    }
            , TI.tiScope =
                TI.ScopeJSON
                    { TI.sjId = scopeText (wqScope q)
                    , TI.sjTreasuryAddress = trAddress s
                    , TI.sjTreasuryUtxos = tsInputs sel
                    , TI.sjTreasuryLeftoverLovelace =
                        tsLeftoverLovelace sel
                    , TI.sjTreasuryLeftoverUsdm = 0
                    , TI.sjTreasuryLeftoverOtherAssets =
                        Map.empty
                    , TI.sjTreasuryScriptHash = trScriptHash s
                    , TI.sjPermissionsRewardAccount =
                        trPermissionsRewardAccount s
                    , TI.sjScopesDeployedAt =
                        rvScopesDeployedAt r
                    , TI.sjPermissionsDeployedAt =
                        rvPermissionsDeployedAt r
                    , TI.sjTreasuryDeployedAt =
                        rvTreasuryDeployedAt r
                    , TI.sjRegistryDeployedAt =
                        rvRegistryDeployedAt r
                    , TI.sjRegistryPolicyId =
                        rvRegistryPolicyId r
                    }
            , TI.tiSigners = signers
            , TI.tiValidityUpperBoundSlot =
                weCurrentTip we
                    + ncSlotsPerHour nc
                        * fromIntegral (wqValidityHours q)
            , TI.tiRationale =
                TI.RationaleJSON
                    { TI.rjEvent =
                        fromMaybe "disburse" (raEvent rat)
                    , TI.rjLabel =
                        fromMaybe
                            "Swap ADA<->USDM"
                            (raLabel rat)
                    , TI.rjDescription = raDescription rat
                    , TI.rjJustification = raJustification rat
                    , TI.rjDestinationLabel =
                        raDestinationLabel rat
                    }
            , TI.tiPayload =
                TI.SwapInputs
                    { TI.swiSwapOrderAddress =
                        ncSwapOrderAddress nc
                    , TI.swiChunkSizeLovelace =
                        wqChunkSizeLovelace q
                    , TI.swiAmountLovelace = wqAmountLovelace q
                    , TI.swiExtraPerChunkLovelace =
                        ncExtraPerChunkLovelace nc
                    , TI.swiRateNumerator = wqRateNumerator q
                    , TI.swiRateDenominator =
                        wqRateDenominator q
                    , TI.swiPoolId = ncDefaultPoolId nc
                    , TI.swiCoreOwner = soCore os
                    , TI.swiOpsOwner = soOps os
                    , TI.swiNetworkComplianceOwner =
                        soNetworkCompliance os
                    , TI.swiMiddlewareOwner = soMiddleware os
                    , TI.swiSundaeProtocolFeeLovelace =
                        ncSundaeProtocolFeeLovelace nc
                    , TI.swiUsdmPolicy = ncUsdmPolicy nc
                    , TI.swiUsdmToken = ncUsdmToken nc
                    }
            }

-- ----------------------------------------------------
-- Resolution
-- ----------------------------------------------------

{- | Inputs the resolver needs from the CLI.

The 'RegistryView' is projected from a verified local
metadata file before resolution begins. The resolver keeps
this compact view so the pure intent translation stays
decoupled from chain-query details.
-}
data ResolverInput = ResolverInput
    { riNetwork :: !Text
    -- ^ @"mainnet"@ / @"preprod"@; selects the
    --   'NetworkConstants' row and validates the wallet
    --   address belongs to the same network.
    , riWalletAddrBech32 :: !Text
    -- ^ bech32 wallet address for fuel + collateral
    , riScope :: !ScopeId
    , riAmountLovelace :: !Integer
    -- ^ total lovelace to be swapped (drives treasury
    --   selection target)
    , riRegistry :: !RegistryView
    -- ^ verified projection; see 'registryViewFromVerified'
    }
    deriving (Eq, Show)

-- | Resolver-level failure modes per @data-model.md §3@.
data ResolverError
    = ResolverNetworkUnsupported !Text
    | -- | @ResolverNetworkMismatch requested observed@
      ResolverNetworkMismatch !Text !Text
    | ResolverScopeUnsupported !ScopeId
    | ResolverEmptyTreasuryUtxos
    | ResolverEmptyWalletUtxos
    | -- | @ResolverShortfall available requested@
      ResolverShortfall !Integer !Integer
    | ResolverVerifiedScopeMissing !ScopeId
    | ResolverOwnerMissing !ScopeId
    | ResolverAddressEncodingFailed !Text
    deriving (Eq, Show)

{- | Project a verified registry walk into the compact view
consumed by the swap wizard.

The verifier owns all chain trust decisions. This adapter is
only a shape conversion from ledger-native values to the
JSON-oriented fields the existing wizard and intent schema
already consume.
-}
registryViewFromVerified
    :: ScopeId
    -> VerifiedRegistry
    -> Either ResolverError RegistryView
registryViewFromVerified scope verified = do
    selected <-
        maybe
            (Left (ResolverVerifiedScopeMissing scope))
            Right
            (Map.lookup scope (vrTreasuriesByScope verified))
    owners <-
        ScopeOwners
            <$> owner CoreDevelopment
            <*> owner OpsAndUseCases
            <*> owner NetworkCompliance
            <*> owner Middleware
    treasuryByScope <-
        traverse
            (treasuryRefsFromVerified scope)
            (Map.singleton scope selected)
    pure
        RegistryView
            { rvScopesDeployedAt =
                txInToText (vrScopesNftUtxo verified)
            , rvPermissionsDeployedAt =
                txInToText (vsPermissionsDeployedAt selected)
            , rvTreasuryDeployedAt =
                txInToText (vsTreasuryDeployedAt selected)
            , rvRegistryDeployedAt =
                txInToText (vsRegistryDeployedAt selected)
            , rvRegistryPolicyId =
                scriptHashToHex (vsRegistryScriptHash selected)
            , rvOwners = owners
            , rvTreasuryByScope = treasuryByScope
            }
  where
    owner ownerScope =
        maybe
            (Left (ResolverOwnerMissing ownerScope))
            (Right . keyHashToText)
            (Map.lookup ownerScope (vrOwners verified))

treasuryRefsFromVerified
    :: ScopeId
    -> VerifiedScope
    -> Either ResolverError TreasuryRefs
treasuryRefsFromVerified _scope verified = do
    address <- addressToText (vsAddress verified)
    pure
        TreasuryRefs
            { trAddress = address
            , trScriptHash =
                scriptHashToHex (vsTreasuryScriptHash verified)
            , -- Withdraw-zero pattern: the permissions script is
              -- invoked by registering its hash as a stake credential
              -- and submitting a 0-lovelace withdrawal. The reward
              -- account IS the permissions script hash, NOT the
              -- stake credential of the treasury address (which is
              -- the treasury hash by upstream's symmetric
              -- addr1x<treasury><treasury> convention).
              trPermissionsRewardAccount =
                scriptHashToHex (vsPermissionsScriptHash verified)
            }

addressToText :: Addr -> Either ResolverError Text
addressToText addr = do
    hrp <-
        case Bech32.humanReadablePartFromText (addressHrp addr) of
            Right value -> Right value
            Left err ->
                Left $
                    ResolverAddressEncodingFailed (T.pack (show err))
    pure $
        Bech32.encodeLenient
            hrp
            (Bech32.dataPartFromBytes (serialiseAddr addr))
  where
    addressHrp target =
        case getNetwork target of
            Mainnet -> "addr"
            Testnet -> "addr_test"

keyHashToText :: KeyHash Witness -> Text
keyHashToText (KeyHash h) =
    TE.decodeUtf8Lenient (B16.encode (hashToBytes h))

txInToText :: TxIn -> Text
txInToText (TxIn (TxId h) ix) =
    TE.decodeUtf8Lenient (B16.encode (hashToBytes (extractHash h)))
        <> "#"
        <> T.pack (show (txIxToInt ix))

{- | Curated per-network constants table.

Sources for each value live in the comment block above
this function and must be kept in lock-step with upstream
Sundae V3 deployments + USDM constants. The MVP table
covers preprod (the documented manual E2E target); the
mainnet row is left as a placeholder until the values are
audited by an operator on-chain.

Sources:

  * SundaeSwap V3 order address: existing
    @test/fixtures/swap/intent.json@ (preprod).
  * USDM policy/token: same fixture (lifted from
    @journal/2026/lib/swap_order.sh@).
  * @extraPerChunkLovelace@, @sundaeProtocolFeeLovelace@:
    same fixture.
  * @slotsPerHour@: 3600 for 1-second slots on
    preprod/mainnet (Conway era).
  * @defaultPoolId@: same fixture.
-}
networkConstants :: Text -> Either String NetworkConstants
networkConstants n = case T.toLower n of
    "mainnet" ->
        Right
            NetworkConstants
                { ncSwapOrderAddress =
                    "addr1x8ax5k9mutg07p2ngscu3chsauktmstq92z9de938j8nqaejyqwur6p8pqmycmzz55lcnan4x99mnt2a5fe54ggt4gxst7gy3n"
                , ncUsdmPolicy =
                    "c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad"
                , ncUsdmToken = "0014df105553444d"
                , ncSundaeProtocolFeeLovelace = 1280000
                , ncExtraPerChunkLovelace = 3280000
                , ncSlotsPerHour = 3600
                , ncDefaultPoolId =
                    "64f35d26b237ad58e099041bc14c687ea7fdc58969d7d5b66e2540ef"
                }
    "preprod" ->
        Left
            "swap-wizard: NetworkConstants for preprod pending operator audit; mainnet only in v1"
    _ ->
        Left
            ( "swap-wizard: no NetworkConstants for network "
                <> T.unpack n
            )

{- | Classify a bech32 address as 'Mainnet' or 'Testnet' by
HRP prefix. The bech32 prefix only carries the network
discriminator (the @addr_test1@ family covers preprod, preview,
and any custom testnet); inferring 'preprod' specifically from
@addr_test1@ would mis-flag a preview wallet as a network
mismatch. Use this for the coarse mainnet-vs-testnet check;
do NOT use it to disambiguate among testnets.
-}
addrNetwork :: Text -> Maybe Network
addrNetwork t
    | "addr_test1" `T.isPrefixOf` t = Just Testnet
    | "addr1" `T.isPrefixOf` t = Just Mainnet
    | otherwise = Nothing

-- | The network family of a CLI 'riNetwork' name.
networkFamily :: Text -> Maybe Network
networkFamily = \case
    "mainnet" -> Just Mainnet
    "preprod" -> Just Testnet
    "preview" -> Just Testnet
    _ -> Nothing

{- | Largest-first deterministic treasury selection over a
list of @(txInRef, lovelace)@. Sorts by lovelace desc and
accumulates until the running sum reaches the target.
Returns the selected refs (in selection order) and the
leftover (Σ selected − target).

Total only when @sum (snd <$> xs) >= target@; the caller
('resolveWizardEnv') checks this and emits a typed
'ResolverShortfall' otherwise.
-}
selectTreasury
    :: [(Text, Integer)]
    -> Integer
    -> Maybe ([Text], Integer)
selectTreasury inputs target
    | total < target = Nothing
    | otherwise = Just (go 0 [] sorted)
  where
    sorted =
        L.sortOn (\(_, l) -> negate l) inputs
    total = sum (snd <$> inputs)
    go acc picked [] = (reverse picked, acc - target)
    go acc picked ((ref, l) : rest)
        | acc >= target =
            (reverse picked, acc - target)
        | otherwise =
            go (acc + l) (ref : picked) rest

{- | Pick the largest pure-ADA UTxO at the wallet address
to use as fuel + collateral. @inputs@ is a list of
@(txInRef, lovelace, hasNativeAssets)@; only entries with
@hasNativeAssets = False@ are eligible.
-}
selectWallet :: [(Text, Integer, Bool)] -> Maybe Text
selectWallet inputs =
    case filter (\(_, _, hasNa) -> not hasNa) inputs of
        [] -> Nothing
        xs ->
            let (ref, _, _) =
                    L.maximumBy
                        (compare `on` snd3)
                        xs
            in  Just ref
  where
    snd3 (_, l, _) = l

{- | The MVP resolver. Combines:

  * 'networkConstants' lookup (pure)
  * wallet address network check ('addrNetwork')
  * largest-first treasury selection ('selectTreasury')
  * largest pure-ADA wallet selection ('selectWallet')
  * a tip read via @posixMsToSlot@ (rounded to the
    closest hour boundary; the validity-window math in
    'wizardToTreasuryIntent' adds @slotsPerHour * hours@)
  * the verifier-projected 'RegistryView'

projecting them into the 'WizardEnv' the pure
translation expects. All resolver errors are typed; no
exception escapes.
-}
resolveWizardEnv
    :: (Monad m)
    => ResolverEnv m
    -> ResolverInput
    -> m (Either ResolverError WizardEnv)
resolveWizardEnv ResolverEnv{..} ri =
    case networkConstants (riNetwork ri) of
        Left _ ->
            pure (Left (ResolverNetworkUnsupported (riNetwork ri)))
        Right nc -> do
            case ( addrNetwork (riWalletAddrBech32 ri)
                 , networkFamily (riNetwork ri)
                 ) of
                (Just obs, Just want)
                    | obs /= want ->
                        let observed = case obs of
                                Mainnet -> "mainnet" :: Text
                                Testnet -> "testnet"
                        in  pure
                                ( Left
                                    ( ResolverNetworkMismatch
                                        (riNetwork ri)
                                        observed
                                    )
                                )
                _ -> resolveWith nc
  where
    resolveWith nc =
        case Map.lookup (riScope ri) (rvTreasuryByScope (riRegistry ri)) of
            Nothing ->
                pure (Left (ResolverScopeUnsupported (riScope ri)))
            Just refs -> do
                walletUtxos <-
                    reEnvQueryWalletUtxos
                        (riWalletAddrBech32 ri)
                if null walletUtxos
                    then pure (Left ResolverEmptyWalletUtxos)
                    else do
                        treasuryUtxos <-
                            reEnvQueryTreasuryUtxos
                                (trAddress refs)
                        if null treasuryUtxos
                            then
                                pure
                                    (Left ResolverEmptyTreasuryUtxos)
                            else case selectTreasury
                                ( map
                                    (\(r, l, _) -> (r, l))
                                    treasuryUtxos
                                )
                                (riAmountLovelace ri) of
                                Nothing ->
                                    pure
                                        ( Left
                                            ( ResolverShortfall
                                                ( sum
                                                    ( map
                                                        ( \(_, l, _) ->
                                                            l
                                                        )
                                                        treasuryUtxos
                                                    )
                                                )
                                                (riAmountLovelace ri)
                                            )
                                        )
                                Just (picked, leftover) ->
                                    case selectWallet
                                        walletUtxos of
                                        Nothing ->
                                            pure
                                                ( Left
                                                    ResolverEmptyWalletUtxos
                                                )
                                        Just walletRef -> do
                                            tip <- reEnvCurrentTip
                                            let owners =
                                                    rvOwners
                                                        (riRegistry ri)
                                                env =
                                                    WizardEnv
                                                        { weNetwork =
                                                            riNetwork ri
                                                        , weCurrentTip =
                                                            tip
                                                        , weNetworkConstants =
                                                            nc
                                                        , weRegistry =
                                                            riRegistry ri
                                                        , weScopeView =
                                                            ScopeView
                                                                { svScope =
                                                                    riScope
                                                                        ri
                                                                , svRefs =
                                                                    refs
                                                                , svDefaultSigners =
                                                                    maybeToList
                                                                        ( scopeOwnerText
                                                                            owners
                                                                            (riScope ri)
                                                                        )
                                                                }
                                                        , weTreasurySelection =
                                                            TreasurySelection
                                                                { tsInputs =
                                                                    picked
                                                                , tsLeftoverLovelace =
                                                                    leftover
                                                                }
                                                        , weWalletSelection =
                                                            WalletSelection
                                                                { wsTxIn =
                                                                    walletRef
                                                                , wsAddress =
                                                                    riWalletAddrBech32
                                                                        ri
                                                                }
                                                        }
                                            pure (Right env)

{- | Effects the resolver pulls from a 'Provider'. Kept as
its own record so tests can stub IO without depending on
@cardano-node-clients@.
-}
data ResolverEnv m = ResolverEnv
    { reEnvQueryWalletUtxos
        :: Text
        -> m [(Text, Integer, Bool)]
    -- ^ wallet address (bech32) ->
    --   @[(txInRef, lovelace, hasNativeAssets)]@
    , reEnvQueryTreasuryUtxos
        :: Text
        -> m [(Text, Integer, Bool)]
    -- ^ same, for the treasury address
    , reEnvCurrentTip :: m Word64
    -- ^ current chain tip in slots
    }
