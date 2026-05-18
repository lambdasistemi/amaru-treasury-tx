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

      -- * Pure translation
    , stakeRewardInitScriptAccountToIntent
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
    , StakeRewardInitScriptAccountInputs (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    )
import Amaru.Treasury.LedgerParse (txInFromText)
import Amaru.Treasury.Registry.Derive (scriptHashToHex)
import Amaru.Treasury.Tx.SwapWizard
    ( WalletSelection (..)
    , selectWallet
    )

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
resolveStakeRewardInitScriptAccount renv input
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
                case selectWallet 1 walletUtxos of
                    Left _ ->
                        pure (Left StakeRewardInitWalletShortfall)
                    Right ([], _) ->
                        pure (Left StakeRewardInitWalletShortfall)
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
                                        StakeRewardInitEnv
                                            { sreNetwork = sriNetwork input
                                            , sreUpperBoundSlot = upperBound
                                            , sreRegistry = registry
                                            , sreWalletSelection =
                                                WalletSelection
                                                    { wsTxIn = walletRef
                                                    , wsAddress =
                                                        sriWalletAddrBech32
                                                            input
                                                    , wsExtraTxIns = []
                                                    }
                                            }

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
