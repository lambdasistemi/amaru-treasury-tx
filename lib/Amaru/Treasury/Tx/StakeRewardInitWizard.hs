{- |
Module      : Amaru.Treasury.Tx.StakeRewardInitWizard
Description : Typed-Q&A wizard data types for the stake-reward-init wizard family
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The stake-reward-init wizard is split into two sub-actions
(@script-account@, @plain-account@) mirroring the
'Amaru.Treasury.IntentJSON.SAction' variants
'StakeRewardInitScriptAccount' and
'StakeRewardInitPlainAccount'.

Slice 1 of [#159](https://github.com/lambdasistemi/amaru-treasury-tx/issues/159)
shipped the typed 'Answers' records and the parser-layer
errors. Slice 2 adds the resolver layer for the
@script-account@ sub-action, the devnet network guard (a
fail-fast UX that fires BEFORE any chain query), the
registry-file parse via the existing
'Amaru.Treasury.Devnet.StakeRewardInit.readDevnetStakeRewardRegistry',
and the pure translation to
'Amaru.Treasury.IntentJSON.SomeTreasuryIntent' for the
script-account arm. Slice 3 wires plain-account on the same
shape.

Unlike the registry-init wizard family, stake-reward-init is
operational rather than governance: there is no rationale
flag set (@--description@, @--justification@,
@--destination-label@, @--event@, @--label@) and no
scope/metadata. The two operator-typed inter-tx inputs are
@--registry@ (the registry-init artifact file produced by
[#158](https://github.com/lambdasistemi/amaru-treasury-tx/pull/165))
and @--funding-seed-txin@ (the wallet UTxO that pays the
registration deposit).
-}
module Amaru.Treasury.Tx.StakeRewardInitWizard
    ( -- * Answers
      StakeRewardInitScriptAccountAnswers (..)
    , StakeRewardInitPlainAccountAnswers (..)

      -- * Errors
    , StakeRewardInitError (..)

      -- * Resolved environment
    , StakeRewardInitEnv (..)

      -- * Resolver
    , StakeRewardInitResolverInput (..)
    , StakeRewardInitResolverEnv (..)
    , resolveStakeRewardInitScriptAccount
    , resolveStakeRewardInitPlainAccount

      -- * Input control (#184 — Slice 6)
    , PoolHit (..)
    , InputControlOutcome (..)
    , OutRef
    , resolveStakeRewardInitScriptAccountIC
    , resolveStakeRewardInitPlainAccountIC
    , renderStakeRewardInitExclusionLogLine
    , renderStakeRewardInitWalletShortfallWithExcludes

      -- * Pure translation
    , stakeRewardInitScriptAccountToIntent
    , stakeRewardInitPlainAccountToIntent
    ) where

import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.ByteString.Base16 qualified as B16
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word16, Word64)

import Cardano.Crypto.Hash.Class (hashToBytes)
import Cardano.Ledger.BaseTypes (txIxToInt)
import Cardano.Ledger.Hashes (extractHash)
import Cardano.Ledger.TxIn (TxId (..), TxIn (..))

import Cardano.Node.Client.Validity qualified as Validity

import Amaru.Treasury.Devnet.StakeRewardInit
    ( DevnetStakeRewardRegistry (..)
    )
import Amaru.Treasury.IntentJSON
    ( RationaleJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , StakeRewardInitPlainAccountInputs (..)
    , StakeRewardInitScriptAccountInputs (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    )
import Amaru.Treasury.LedgerParse (txInFromText)
import Amaru.Treasury.Registry.Derive (scriptHashToHex)
import Amaru.Treasury.Tx.SwapWizard
    ( InputControlOutcome (..)
    , PoolHit (..)
    , WalletSelection (..)
    , selectWallet
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

{- | Typed operator answers for the @script-account@
sub-action.

The funding seed is operator-typed (it identifies the
specific wallet UTxO that pays the registration deposit);
the @--registry@ artifact path is parsed at the resolver
layer in Slice 2 via 'readDevnetStakeRewardRegistry', so it
does not appear in the typed answers.
-}
data StakeRewardInitScriptAccountAnswers
    = StakeRewardInitScriptAccountAnswers
    { sasaValidityHours :: !(Maybe Word16)
    , sasaFundingSeedTxIn :: !TxIn
    }
    deriving stock (Eq, Show)

instance FromJSON StakeRewardInitScriptAccountAnswers where
    parseJSON =
        withObject "StakeRewardInitScriptAccountAnswers" $ \o -> do
            hours <- o .:? "validityHours"
            seedText <- o .: "fundingSeedTxIn"
            seed <- case txInFromText seedText of
                Left e -> fail ("fundingSeedTxIn: " <> e)
                Right t -> pure t
            pure
                StakeRewardInitScriptAccountAnswers
                    { sasaValidityHours = hours
                    , sasaFundingSeedTxIn = seed
                    }

{- | Typed operator answers for the @plain-account@
sub-action.

Mirrors the script-account shape: the operator-typed funding
seed identifies the wallet UTxO paying the registration
deposit; the @--registry@ artifact is parsed at the resolver
layer.
-}
data StakeRewardInitPlainAccountAnswers
    = StakeRewardInitPlainAccountAnswers
    { spaaValidityHours :: !(Maybe Word16)
    , spaaFundingSeedTxIn :: !TxIn
    }
    deriving stock (Eq, Show)

instance FromJSON StakeRewardInitPlainAccountAnswers where
    parseJSON =
        withObject "StakeRewardInitPlainAccountAnswers" $ \o -> do
            hours <- o .:? "validityHours"
            seedText <- o .: "fundingSeedTxIn"
            seed <- case txInFromText seedText of
                Left e -> fail ("fundingSeedTxIn: " <> e)
                Right t -> pure t
            pure
                StakeRewardInitPlainAccountAnswers
                    { spaaValidityHours = hours
                    , spaaFundingSeedTxIn = seed
                    }

-- ----------------------------------------------------
-- Errors
-- ----------------------------------------------------

{- | Typed errors the stake-reward-init wizard surfaces to the
operator. Slice 1 ships the parent-directory and collision
variants used by the @--out@ pre-flight checks. Slice 2
adds the devnet guard, the wallet-shortfall path, the
registry-file parse variants, and the validity-window
errors.

The @StakeRewardInitRegistryReadError@ payload carries the
raw error string from 'readDevnetStakeRewardRegistry' (which
already covers missing files, unparseable JSON, wrong
@phase@, and wrong @network@) so the resolver layer does not
need to know which sub-failure occurred.
-}
data StakeRewardInitError
    = -- | @--out@ pointed at a path whose parent directory
      --   does not exist.
      StakeRewardInitOutputParentMissing !FilePath
    | -- | @--out@ pointed at an existing file and
      --   @--force@ was not passed.
      StakeRewardInitOutputExistsNoForce !FilePath
    | -- | The supplied @--network@ (carried on the resolver
      --   input) is not @"devnet"@. The resolver fails fast
      --   at this guard BEFORE any chain query.
      StakeRewardInitNonDevnetNetwork !Text
    | -- | The wallet has no pure-ADA UTxOs that satisfy the
      --   selection helper for the funding seed.
      StakeRewardInitWalletShortfall
    | -- | The @--registry@ artifact failed to parse via
      --   'readDevnetStakeRewardRegistry' (missing file,
      --   unparseable JSON, wrong @phase@, or wrong
      --   @network@). Payload is the raw underlying error.
      StakeRewardInitRegistryReadError !String
    | -- | @--validity-hours = Just 0@.
      StakeRewardInitValidityHoursZero
    | -- | @--validity-hours = Just n@ overshoots the chain
      --   horizon.
      StakeRewardInitValidityOvershoot !Validity.HorizonError
    | -- | One or more @--extra-tx-in@ refs were not returned
      --   by the wallet-address query (FR-009, #184).
      StakeRewardInitResolverExtraTxInNotOnWallet ![OutRef]
    | -- | @StakeRewardInitResolverWalletShortfallWithExcludes
      --   available target refs@. Wallet pool was emptied by
      --   the operator's @--exclude-utxo@ set (FR-008, #184).
      StakeRewardInitResolverWalletShortfallWithExcludes
        !Integer
        !Integer
        ![OutRef]
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Resolved environment
-- ----------------------------------------------------

{- | Everything the resolver hands the pure translation.
The pure 'stakeRewardInitScriptAccountToIntent' reads only
this record plus the typed 'StakeRewardInitScriptAccountAnswers';
it never performs IO.
-}
data StakeRewardInitEnv = StakeRewardInitEnv
    { sreNetwork :: !Text
    -- ^ Always @"devnet"@ after the resolver guard.
    , sreUpperBoundSlot :: !Word64
    -- ^ Resolver-supplied @invalid-hereafter@ slot. Already
    --   horizon-validated; the pure translator just stamps it.
    , sreRegistry :: !DevnetStakeRewardRegistry
    -- ^ Parsed registry-init artifact; supplies the
    --   treasury reference-script anchor and the treasury
    --   stake-script hash.
    , sreWalletSelection :: !WalletSelection
    -- ^ Wallet block carrier. The pure translation uses
    --   @wsAddress@ verbatim and overrides @wsTxIn@ with
    --   the operator-typed funding seed from the answers.
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Resolver
-- ----------------------------------------------------

{- | Inputs the resolver pulls from the CLI before any chain
query. The @--registry@ artifact path and the funding-seed
TxIn are operator-typed; the wallet selection is derived from
the chain via @wreQueryWalletUtxos@.
-}
data StakeRewardInitResolverInput = StakeRewardInitResolverInput
    { sriNetwork :: !Text
    -- ^ CLI @--network@ value. Anything other than @"devnet"@
    --   trips the devnet guard before any chain query.
    , sriWalletAddrBech32 :: !Text
    , sriRegistryPath :: !FilePath
    , sriValidityHours :: !(Maybe Word16)
    }
    deriving stock (Eq, Show)

{- | Effects the resolver pulls from the backend. Keeping
these as record fields lets tests inject mocks without
depending on a live node.
-}
data StakeRewardInitResolverEnv m = StakeRewardInitResolverEnv
    { sreQueryWalletUtxos
        :: !(Text -> m [(Text, Integer, Bool)])
    -- ^ @(txInRef, lovelace, hasNativeAssets)@ for the wallet.
    , sreComputeUpperBound
        :: !( Validity.ValidityChoice
              -> m (Either Validity.HorizonError Word64)
            )
    , sreReadRegistry
        :: !(FilePath -> m (Either String DevnetStakeRewardRegistry))
    -- ^ Reads + parses the @--registry@ artifact. The live
    --   wiring sets this to a lifted
    --   'readDevnetStakeRewardRegistry'; tests inject mocks.
    }

{- | Resolve the chain-derived script-account environment.

The DEVNET GUARD is the first check; on any non-@"devnet"@
network the function returns
'StakeRewardInitNonDevnetNetwork' WITHOUT performing the
registry parse, the wallet query, the upper-bound
computation, or any other effect. The mock-driven tests rely
on this short-circuit.

Subsequent failure paths:

* registry parse: any 'Left' from @sreReadRegistry@ is
  wrapped as 'StakeRewardInitRegistryReadError';
* wallet shortfall: 'selectWallet' returning @Left _@ or
  yielding an empty selection surfaces
  'StakeRewardInitWalletShortfall';
* validity-window: the @--validity-hours@ resolver returns
  'StakeRewardInitValidityHoursZero' or
  'StakeRewardInitValidityOvershoot'.
-}
resolveStakeRewardInitScriptAccount
    :: (Monad m)
    => StakeRewardInitResolverEnv m
    -> StakeRewardInitResolverInput
    -> m (Either StakeRewardInitError StakeRewardInitEnv)
resolveStakeRewardInitScriptAccount renv input = do
    r <-
        resolveStakeRewardInitScriptAccountIC
            renv
            (ExclusionSet [])
            (ForcedInclusionSet [])
            input
    pure (fmap fst r)

{- | Variant of 'resolveStakeRewardInitScriptAccount' that
threads the operator's @--exclude-utxo@ and @--extra-tx-in@
sets through the wallet candidate pool (#184 Slice 6).
Returns the resolved 'StakeRewardInitEnv' alongside the
'InputControlOutcome' the caller uses to emit per-ref log
lines.
-}
resolveStakeRewardInitScriptAccountIC
    :: (Monad m)
    => StakeRewardInitResolverEnv m
    -> ExclusionSet
    -> ForcedInclusionSet
    -> StakeRewardInitResolverInput
    -> m
        ( Either StakeRewardInitError (StakeRewardInitEnv, InputControlOutcome)
        )
resolveStakeRewardInitScriptAccountIC renv excl forced input
    | sriNetwork input /= "devnet" =
        pure
            ( Left
                ( StakeRewardInitNonDevnetNetwork (sriNetwork input)
                )
            )
    | otherwise = do
        regE <- sreReadRegistry renv (sriRegistryPath input)
        case regE of
            Left e ->
                pure (Left (StakeRewardInitRegistryReadError e))
            Right registry -> do
                walletUtxos <-
                    sreQueryWalletUtxos
                        renv
                        (sriWalletAddrBech32 input)
                let ExclusionSet exclRefs = excl
                    ForcedInclusionSet forcedRefs = forced
                    walletRefSet =
                        map walletCandidateRef walletUtxos
                    missing =
                        filter (`notElem` walletRefSet) forcedRefs
                if not (null missing)
                    then
                        pure
                            ( Left
                                ( StakeRewardInitResolverExtraTxInNotOnWallet
                                    missing
                                )
                            )
                    else
                        let (filteredWallet, _, _, _) =
                                filterPool
                                    walletCandidateRef
                                    excl
                                    forced
                                    walletUtxos
                            outcome =
                                buildStakeRewardInitOutcome
                                    exclRefs
                                    walletRefSet
                            forcedTexts = map outRefText forcedRefs
                        in  case selectWallet 1 filteredWallet of
                                Left _ ->
                                    pure
                                        ( Left
                                            ( stakeRewardWalletShortfallError
                                                exclRefs
                                                0
                                                1
                                            )
                                        )
                                Right ([], _) ->
                                    pure
                                        ( Left
                                            ( stakeRewardWalletShortfallError
                                                exclRefs
                                                0
                                                1
                                            )
                                        )
                                Right (walletRef : _, _) -> do
                                    upperE <-
                                        resolveUpperBound
                                            (sreComputeUpperBound renv)
                                            (sriValidityHours input)
                                    case upperE of
                                        Left e -> pure (Left e)
                                        Right upperBound ->
                                            pure $
                                                Right
                                                    ( StakeRewardInitEnv
                                                        { sreNetwork = sriNetwork input
                                                        , sreUpperBoundSlot = upperBound
                                                        , sreRegistry = registry
                                                        , sreWalletSelection =
                                                            WalletSelection
                                                                { wsTxIn = walletRef
                                                                , wsAddress =
                                                                    sriWalletAddrBech32
                                                                        input
                                                                , wsExtraTxIns = forcedTexts
                                                                }
                                                        }
                                                    , outcome
                                                    )

{- | Same as 'resolveStakeRewardInitScriptAccountIC': the
plain-account resolver's environmental checks are
sub-action-agnostic.
-}
resolveStakeRewardInitPlainAccountIC
    :: (Monad m)
    => StakeRewardInitResolverEnv m
    -> ExclusionSet
    -> ForcedInclusionSet
    -> StakeRewardInitResolverInput
    -> m
        ( Either StakeRewardInitError (StakeRewardInitEnv, InputControlOutcome)
        )
resolveStakeRewardInitPlainAccountIC =
    resolveStakeRewardInitScriptAccountIC

-- ----------------------------------------------------
-- Input-control helpers (#184 Slice 6)
-- ----------------------------------------------------

stakeRewardWalletShortfallError
    :: [OutRef] -> Integer -> Integer -> StakeRewardInitError
stakeRewardWalletShortfallError exclRefs avail target
    | null exclRefs = StakeRewardInitWalletShortfall
    | otherwise =
        StakeRewardInitResolverWalletShortfallWithExcludes
            avail
            target
            exclRefs

walletCandidateRef :: (Text, Integer, Bool) -> OutRef
walletCandidateRef (ref, _, _) =
    case parseOutRef ref of
        Right r -> r
        Left e ->
            error
                ( "stake-reward-init-wizard: wallet candidate ref not parseable: "
                    <> T.unpack ref
                    <> ": "
                    <> T.unpack e
                )

buildStakeRewardInitOutcome
    :: [OutRef] -> [OutRef] -> InputControlOutcome
buildStakeRewardInitOutcome excluded walletRefs =
    let classify ref
            | ref `elem` walletRefs = Right (ref, WalletOnly)
            | otherwise = Left ref
        classified = map classify excluded
    in  InputControlOutcome
            { icoHits = rights classified
            , icoInert = lefts classified
            }

{- | Render the per-ref exclusion log line for the
stake-reward-init wizard family. Wallet pool only, so
attribution is always @[wallet]@.
-}
renderStakeRewardInitExclusionLogLine
    :: Text -> OutRef -> PoolHit -> Text
renderStakeRewardInitExclusionLogLine prefix ref _pool =
    prefix
        <> ": excluded utxo "
        <> outRefText ref
        <> " (operator-supplied) [wallet]"

{- | Wizard-side shim that DELEGATES to the shared
'Amaru.Treasury.Wizard.InputControl.renderShortfallWithExcludes'.
-}
renderStakeRewardInitWalletShortfallWithExcludes
    :: Text -> [OutRef] -> Text
renderStakeRewardInitWalletShortfallWithExcludes =
    renderShortfallWithExcludes

resolveUpperBound
    :: (Monad m)
    => ( Validity.ValidityChoice
         -> m (Either Validity.HorizonError Word64)
       )
    -> Maybe Word16
    -> m (Either StakeRewardInitError Word64)
resolveUpperBound askUpperBound hours = case hours of
    Just 0 -> pure (Left StakeRewardInitValidityHoursZero)
    other -> do
        let choice =
                maybe
                    Validity.AutoLongest
                    Validity.ExactlyHours
                    other
        result <- askUpperBound choice
        pure $ case result of
            Left horizonErr ->
                Left (StakeRewardInitValidityOvershoot horizonErr)
            Right slot -> Right slot

-- ----------------------------------------------------
-- Pure translation (script-account)
-- ----------------------------------------------------

{- | Translate the resolved @script-account@ environment
plus typed answers into a 'SomeTreasuryIntent'. Pure; reads
only its arguments.

The translator extracts @dsrrTreasuryRef@ →
@treasuryRefTxIn@ and @dsrrTreasuryScriptHash@ →
@treasuryScriptHash@ from the parsed registry, and bakes
the operator-typed @sasaFundingSeedTxIn@ verbatim into the
wallet block's @wjTxIn@ (overriding the env-supplied
'WalletSelection.wsTxIn'), mirroring
'Amaru.Treasury.Tx.RegistryInitWizard.registryInitReferenceScriptsToIntent'.

Constitutional constraint (NFR-006): this function MUST NOT
call 'Amaru.Treasury.Devnet.StakeRewardInit.buildStakeRewardScriptAccountCore'
or any other 'Amaru.Treasury.Devnet.*' construction core; it
only manipulates the JSON-shaped intent. The dispatcher in
"Amaru.Treasury.Build" is the one that consumes the encoded
intent and calls the core. Slice 4 ships a grep-based test
that enforces this boundary on the wizard module.
-}
stakeRewardInitScriptAccountToIntent
    :: StakeRewardInitEnv
    -> StakeRewardInitScriptAccountAnswers
    -> Either StakeRewardInitError SomeTreasuryIntent
stakeRewardInitScriptAccountToIntent env ans = do
    -- Defensive guards mirroring the resolver, for callers
    -- that bypass the resolver and feed an arbitrary Env.
    case sasaValidityHours ans of
        Just 0 -> Left StakeRewardInitValidityHoursZero
        _ -> pure ()
    let registry = sreRegistry env
        treasuryRefText = txInText (dsrrTreasuryRef registry)
        treasuryHashHex =
            scriptHashToHex (dsrrTreasuryScriptHash registry)
        intent =
            TreasuryIntent
                { tiSAction = SStakeRewardInitScriptAccount
                , tiSchema = 1
                , tiNetwork = sreNetwork env
                , tiWallet =
                    mkWalletScriptAccount
                        (sreWalletSelection env)
                        (sasaFundingSeedTxIn ans)
                , tiScope = mkScopeStakeRewardInit env ans
                , tiSigners = []
                , tiValidityUpperBoundSlot = sreUpperBoundSlot env
                , tiRationale = mkRationaleScriptAccount
                , tiPayload =
                    StakeRewardInitScriptAccountInputs
                        { srisaiTreasuryRefTxIn = treasuryRefText
                        , srisaiTreasuryScriptHash = treasuryHashHex
                        }
                }
    Right
        ( SomeTreasuryIntent
            SStakeRewardInitScriptAccount
            intent
        )

mkWalletScriptAccount :: WalletSelection -> TxIn -> WalletJSON
mkWalletScriptAccount ws fundingSeed =
    WalletJSON
        { wjTxIn = txInText fundingSeed
        , wjAddress = wsAddress ws
        , wjExtraTxIns = wsExtraTxIns ws
        }

{- | Stake-reward-init does NOT bind to a scope: the script
account it registers is a top-level treasury credential. The
construction-core path consumes only @treasuryScriptHash@
and @treasuryRefTxIn@ from the payload; the @ScopeJSON@ slot
is filled with a placeholder skeleton so the JSON envelope
parses through the existing 'TreasuryIntent' decoder. The
fixture goldens use the same placeholder shape — drift here
would fail the CBOR-parity assertion.

The placeholder mirrors
'Support.StakeRewardInitFixtures.placeholderScopeJSON' shape:
@sjId@ is the @core_development@ literal, hashes are
56-zero placeholders, and the four @*DeployedAt@ slots
all carry the operator-typed funding seed TxIn (rendered).
-}
mkScopeStakeRewardInit
    :: StakeRewardInitEnv
    -> StakeRewardInitScriptAccountAnswers
    -> ScopeJSON
mkScopeStakeRewardInit env ans =
    let wallet = sreWalletSelection env
        seedText = txInText (sasaFundingSeedTxIn ans)
    in  ScopeJSON
            { sjId = "core_development"
            , sjTreasuryAddress = wsAddress wallet
            , sjTreasuryUtxos = []
            , sjTreasuryLeftoverLovelace = 0
            , sjTreasuryLeftoverUsdm = 0
            , sjTreasuryLeftoverOtherAssets = mempty
            , sjTreasuryScriptHash = T.replicate 56 "0"
            , sjPermissionsRewardAccount = T.replicate 56 "0"
            , sjScopesDeployedAt = seedText
            , sjPermissionsDeployedAt = seedText
            , sjTreasuryDeployedAt = seedText
            , sjRegistryDeployedAt = seedText
            , sjRegistryPolicyId = T.replicate 56 "0"
            }

mkRationaleScriptAccount :: RationaleJSON
mkRationaleScriptAccount =
    RationaleJSON
        { rjEvent = "stake-reward-init"
        , rjLabel = "stake-reward-init"
        , rjDescription = "stake-reward-init bootstrap fixture"
        , rjJustification = "test"
        , rjDestinationLabel = "fixture"
        , rjReferences = []
        }

-- ----------------------------------------------------
-- Plain-account resolver
-- ----------------------------------------------------

{- | Resolve the chain-derived plain-account environment.

The resolver pipeline mirrors
'resolveStakeRewardInitScriptAccount' exactly — the DEVNET
guard is the first check, then registry parse, then wallet
selection, then validity-window. The only downstream
difference is which registry field the pure translator
consumes ('dsrrPermissionsScriptHash' here vs
'dsrrTreasuryRef' + 'dsrrTreasuryScriptHash' for
script-account), so it is safe to share the env shape.

NFR-007 (subcommand independence): the resolver does NOT
query chain state for "is the treasury account already
registered" or any sibling check; the plain-account path is
fully independent of the script-account path.
-}
resolveStakeRewardInitPlainAccount
    :: (Monad m)
    => StakeRewardInitResolverEnv m
    -> StakeRewardInitResolverInput
    -> m (Either StakeRewardInitError StakeRewardInitEnv)
resolveStakeRewardInitPlainAccount =
    -- The plain-account resolver pipeline is identical to
    -- the script-account one: every environmental check
    -- (devnet guard, registry parse, wallet shortfall,
    -- validity-window) is sub-action-agnostic. The pure
    -- translator picks the right payload fields downstream.
    resolveStakeRewardInitScriptAccount

-- ----------------------------------------------------
-- Pure translation (plain-account)
-- ----------------------------------------------------

{- | Translate the resolved @plain-account@ environment plus
typed answers into a 'SomeTreasuryIntent'. Pure; reads only
its arguments.

The translator extracts @dsrrPermissionsScriptHash@ →
@permissionsScriptHash@ from the parsed registry into the
'StakeRewardInitPlainAccountInputs' payload, and bakes the
operator-typed @spaaFundingSeedTxIn@ verbatim into the wallet
block's @wjTxIn@ (overriding the env-supplied
'WalletSelection.wsTxIn'), mirroring the script-account
translator.

Constitutional constraint (NFR-006): this function MUST NOT
call 'Amaru.Treasury.Devnet.StakeRewardInit.buildStakeRewardPlainAccountCore'
or any other 'Amaru.Treasury.Devnet.*' construction core; it
only manipulates the JSON-shaped intent. The dispatcher in
"Amaru.Treasury.Build" is the one that consumes the encoded
intent and calls the core. Slice 4 ships a grep-based test
that enforces this boundary on the wizard module.

NFR-007 (subcommand independence): the translator reads only
its 'StakeRewardInitEnv' + 'StakeRewardInitPlainAccountAnswers'
arguments; it never branches on whether the sibling
script-account sub-action has run.
-}
stakeRewardInitPlainAccountToIntent
    :: StakeRewardInitEnv
    -> StakeRewardInitPlainAccountAnswers
    -> Either StakeRewardInitError SomeTreasuryIntent
stakeRewardInitPlainAccountToIntent env ans = do
    -- Defensive guards mirroring the resolver, for callers
    -- that bypass the resolver and feed an arbitrary Env.
    case spaaValidityHours ans of
        Just 0 -> Left StakeRewardInitValidityHoursZero
        _ -> pure ()
    let registry = sreRegistry env
        permissionsHashHex =
            scriptHashToHex (dsrrPermissionsScriptHash registry)
        intent =
            TreasuryIntent
                { tiSAction = SStakeRewardInitPlainAccount
                , tiSchema = 1
                , tiNetwork = sreNetwork env
                , tiWallet =
                    mkWalletPlainAccount
                        (sreWalletSelection env)
                        (spaaFundingSeedTxIn ans)
                , tiScope = mkScopePlainAccount env
                , tiSigners = []
                , tiValidityUpperBoundSlot = sreUpperBoundSlot env
                , tiRationale = mkRationalePlainAccount
                , tiPayload =
                    StakeRewardInitPlainAccountInputs
                        { srispiPermissionsScriptHash =
                            permissionsHashHex
                        }
                }
    Right
        ( SomeTreasuryIntent
            SStakeRewardInitPlainAccount
            intent
        )

mkWalletPlainAccount :: WalletSelection -> TxIn -> WalletJSON
mkWalletPlainAccount ws fundingSeed =
    WalletJSON
        { wjTxIn = txInText fundingSeed
        , wjAddress = wsAddress ws
        , wjExtraTxIns = wsExtraTxIns ws
        }

{- | Same placeholder shape as the script-account scope; for
the plain-account fixture the @*DeployedAt@ slots are sourced
from the registry's @dsrrPermissionsRef@ (the bootstrap
permissions-deployed anchor), which the wizard fixture lines
up with the shared script-account seed TxIn so the wizard
intent compares equal to the library-core fixture's
@srifIntent@.
-}
mkScopePlainAccount
    :: StakeRewardInitEnv
    -> ScopeJSON
mkScopePlainAccount env =
    let wallet = sreWalletSelection env
        registry = sreRegistry env
        anchorText = txInText (dsrrPermissionsRef registry)
    in  ScopeJSON
            { sjId = "core_development"
            , sjTreasuryAddress = wsAddress wallet
            , sjTreasuryUtxos = []
            , sjTreasuryLeftoverLovelace = 0
            , sjTreasuryLeftoverUsdm = 0
            , sjTreasuryLeftoverOtherAssets = mempty
            , sjTreasuryScriptHash = T.replicate 56 "0"
            , sjPermissionsRewardAccount = T.replicate 56 "0"
            , sjScopesDeployedAt = anchorText
            , sjPermissionsDeployedAt = anchorText
            , sjTreasuryDeployedAt = anchorText
            , sjRegistryDeployedAt = anchorText
            , sjRegistryPolicyId = T.replicate 56 "0"
            }

mkRationalePlainAccount :: RationaleJSON
mkRationalePlainAccount =
    RationaleJSON
        { rjEvent = "stake-reward-init"
        , rjLabel = "stake-reward-init"
        , rjDescription = "stake-reward-init bootstrap fixture"
        , rjJustification = "test"
        , rjDestinationLabel = "fixture"
        , rjReferences = []
        }

-- ----------------------------------------------------
-- Text rendering helpers
-- ----------------------------------------------------

txInText :: TxIn -> Text
txInText (TxIn (TxId h) ix) =
    TE.decodeUtf8Lenient
        (B16.encode (hashToBytes (extractHash h)))
        <> "#"
        <> T.pack (show (txIxToInt ix))
