{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

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

      -- * Resolution
    , ResolverInput (..)
    , ResolverError (..)
    , ResolverEnv (..)
    , networkConstants
    , selectTreasury
    , selectWallet
    , addrNetwork
    , resolveWizardEnv
    ) where

import Cardano.Ledger.BaseTypes (Network (..))
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
import Data.Function (on)
import Data.List qualified as L
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

-- ----------------------------------------------------
-- Resolution
-- ----------------------------------------------------

{- | Inputs the resolver needs from the CLI.

The 'RegistryView' is supplied by the operator (loaded
from a JSON file) rather than walked on-chain in the v1
wizard. The walk is recorded as out-of-scope in
@research.md@ and tracked separately; it is a deep
Plutus-data parse that does not belong in the wizard
critical path.
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
    -- ^ operator-supplied; see module note above
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
    deriving (Eq, Show)

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
    "preprod" ->
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
    "mainnet" ->
        Left
            "swap-wizard: NetworkConstants for mainnet pending operator audit; preprod only in v1"
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
    'wizardToIntentJSON' adds @slotsPerHour * hours@)
  * the operator-supplied 'RegistryView'

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
                                                                    [ soCore
                                                                        owners
                                                                    , soOps
                                                                        owners
                                                                    , soNetworkCompliance
                                                                        owners
                                                                    , soMiddleware
                                                                        owners
                                                                    ]
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
