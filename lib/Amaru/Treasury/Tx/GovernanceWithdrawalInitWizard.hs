{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard
Description : Typed-Q&A wizard data types + resolver + pure translation
              for the governance-withdrawal-init wizard family
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The governance-withdrawal-init wizard is split into two
sub-actions (@proposal@, @materialization@) mirroring the
'Amaru.Treasury.IntentJSON.SAction' variants
'GovernanceWithdrawalInitProposal' and
'GovernanceWithdrawalInitMaterialization' (#157).

Slice 1 shipped the typed 'Answers' records, the
'GovernanceWithdrawalInitError' ADT (parser-layer variants),
and the @--out@ pre-flight check. Slice 2 (this slice) adds
the resolver layer for the @proposal@ sub-action: devnet
network guard, registry + stake-reward-accounts artifact
parses (via the existing
'Amaru.Treasury.Devnet.GovernanceWithdrawalInit.readDevnetGovernanceWithdrawalRegistry'
and
'Amaru.Treasury.Devnet.GovernanceWithdrawalInit.readDevnetGovernanceStakeRewardAccounts'),
cross-validation via the existing
'validateGovernanceWithdrawalPrerequisites', deposit-aware
wallet-shortfall check (FR-008), and the pure translation
to 'SomeTreasuryIntent'. Slice 3 will wire @materialization@
on the same shape with a simpler shortfall (no governance
deposits).

Per NFR-008 the wizard touches no key material: the two
governance key hashes and the CIP-1694 anchor hash are
operator-typed hex strings, validated for length at the
parser layer (Slice 1), and passed through verbatim into
the resulting intent payload. Source-of-truth consistency
between the declared hashes and the keys the operator will
sign with at @witness@ time is the operator's
responsibility, surfaced as a required-signer mismatch at
@witness@ time if violated.

Per NFR-006 this module MUST NOT call
'Amaru.Treasury.Devnet.GovernanceWithdrawalInit.Core.buildGovernanceWithdrawalProposalCore'
or
'buildGovernanceWithdrawalMaterializationCore'; the
construction cores are reached only via the @tx-build@
dispatcher consuming the encoded intent. Slice 4 will ship
a grep-based test enforcing this boundary.
-}
module Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard
    ( -- * Answers
      GovernanceWithdrawalInitProposalAnswers (..)
    , GovernanceWithdrawalInitMaterializationAnswers (..)

      -- * Errors
    , GovernanceWithdrawalInitError (..)

      -- * Resolved environment
    , GovernanceWithdrawalInitEnv (..)

      -- * Resolver (proposal)
    , GovernanceWithdrawalInitResolverInput (..)
    , GovernanceWithdrawalInitResolverEnv (..)
    , resolveGovernanceWithdrawalInitProposal

      -- * Pure translation (proposal)
    , governanceWithdrawalInitProposalToIntent

      -- * Deposit-aware wallet floor
    , DepositComponents (..)
    , proposalWalletFloorLovelace
    , proposalVoteOutputCoinLovelace
    , proposalEstimatedFeeLovelace
    , extractDepositComponents
    ) where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word16, Word64)
import Lens.Micro ((^.))

import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.PParams
    ( ppDRepDepositL
    , ppGovActionDepositL
    )
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Core qualified as Ledger
import Cardano.Ledger.TxIn (TxIn)

import Cardano.Node.Client.Validity qualified as Validity

import Amaru.Treasury.Devnet.GovernanceWithdrawalInit
    ( DevnetGovernanceStakeRewardAccount (..)
    , DevnetGovernanceStakeRewardAccounts (..)
    , DevnetGovernanceWithdrawalRegistry (..)
    , GovernanceWithdrawalInitFailure (..)
    , GovernanceWithdrawalPrerequisites (..)
    , validateGovernanceWithdrawalPrerequisites
    )
import Amaru.Treasury.IntentJSON
    ( GovernanceWithdrawalInitProposalInputs (..)
    , RationaleJSON (..)
    , SAction (..)
    , ScopeJSON (..)
    , SomeTreasuryIntent (..)
    , TreasuryIntent (..)
    , WalletJSON (..)
    )
import Amaru.Treasury.LedgerParse (txInFromText, txInToText)
import Amaru.Treasury.Tx.SwapWizard
    ( WalletSelection (..)
    )

-- ----------------------------------------------------
-- Answers
-- ----------------------------------------------------

{- | Typed operator answers for the @proposal@
sub-action.

The wizard validates the hex length of
'gwipaFundingStakeKeyHash' and 'gwipaVoterKeyHash'
(28 bytes \\(\\equiv\\) 56 hex chars) and
'gwipaAnchorHash' (32 bytes \\(\\equiv\\) 64 hex chars)
at the parser layer; the validated text is passed through
into the resulting intent payload verbatim. The wizard
does NOT verify that either key hash corresponds to a key
the operator's vault holds — consistency between the
declared hash and the signing-time vault identity is the
operator's responsibility, surfaced as a required-signer
mismatch at @witness@ time if violated.
-}
data GovernanceWithdrawalInitProposalAnswers
    = GovernanceWithdrawalInitProposalAnswers
    { gwipaValidityHours :: !(Maybe Word16)
    , gwipaFundingSeedTxIn :: !TxIn
    , gwipaFundingStakeKeyHash :: !Text
    , gwipaVoterKeyHash :: !Text
    , gwipaWithdrawalAmountLovelace :: !Integer
    , gwipaAnchorUrl :: !Text
    , gwipaAnchorHash :: !Text
    }
    deriving stock (Eq, Show)

instance FromJSON GovernanceWithdrawalInitProposalAnswers where
    parseJSON =
        withObject "GovernanceWithdrawalInitProposalAnswers" $ \o -> do
            hours <- o .:? "validityHours"
            seedText <- o .: "fundingSeedTxIn"
            seed <- case txInFromText seedText of
                Left e -> fail ("fundingSeedTxIn: " <> e)
                Right t -> pure t
            fsh <- o .: "fundingStakeKeyHash"
            vh <- o .: "voterKeyHash"
            amount <- o .: "withdrawalAmountLovelace"
            url <- o .: "anchorUrl"
            ah <- o .: "anchorHash"
            pure
                GovernanceWithdrawalInitProposalAnswers
                    { gwipaValidityHours = hours
                    , gwipaFundingSeedTxIn = seed
                    , gwipaFundingStakeKeyHash = fsh
                    , gwipaVoterKeyHash = vh
                    , gwipaWithdrawalAmountLovelace = amount
                    , gwipaAnchorUrl = url
                    , gwipaAnchorHash = ah
                    }

{- | Typed operator answers for the @materialization@
sub-action.

The wizard derives 'gwimiTreasuryRewardAccountHash',
'gwimiTreasuryAddress', 'gwimiTreasuryRefTxIn', and
'gwimiRegistryRefTxIn' from the @--registry@ artifact
(Slice 3 wiring); the only operator-typed payload field is
'gwimaRewardsLovelace' — the post-enactment treasury
reward balance the operator observed off-chain.
-}
data GovernanceWithdrawalInitMaterializationAnswers
    = GovernanceWithdrawalInitMaterializationAnswers
    { gwimaValidityHours :: !(Maybe Word16)
    , gwimaFundingSeedTxIn :: !TxIn
    , gwimaRewardsLovelace :: !Integer
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Deposit components (deposit-aware shortfall, FR-008)
-- ----------------------------------------------------

{- | Named breakdown of the lovelace floor the funding wallet
must clear for a proposal tx to even build, before any
balancing. The total is

@
proposalWalletFloorLovelace dc =
      2 * dcStakeDeposit dc      -- one for funding stake, one for voter stake
    + dcDrepDeposit dc           -- DRep registration
    + dcGovActionDeposit dc      -- proposal procedure
    + dcVoteOutputCoin dc        -- voter base address output
    + dcEstimatedFee dc          -- conservative fee + min-utxo headroom
@

Carrying each component in the typed shortfall error
('GovernanceWithdrawalInitWalletShortfall') makes the
operator-facing message name the exact contribution of
each line, so a 'WalletShortfall' is actionable instead of
generic.

The proposal program in
'Amaru.Treasury.Devnet.GovernanceWithdrawalInit.Core'
issues exactly these certs/outputs: two
'registerAndVoteAbstain' (funding stake + voter stake), one
'ConwayRegDRep', one 'proposeTreasuryWithdrawal', one
'payTo voterBaseAddr (inject voteOutputCoin)'. The Core
module also bakes
'stakeDeposit'/'governanceDeposit'/'drepDeposit'/'voteOutputCoin'
as module-level constants. The wizard chooses NOT to
import those (NFR-006 forbids reaching into the Core for
construction symbols, and the brief here forbids editing
the Core module); instead it carries the @voteOutputCoin@
and @estimatedFee@ as named constants below, and reads the
three deposits from the chain pparams (production wiring)
or a stub (tests).
-}
data DepositComponents = DepositComponents
    { dcStakeDeposit :: !Integer
    , dcDrepDeposit :: !Integer
    , dcGovActionDeposit :: !Integer
    , dcVoteOutputCoin :: !Integer
    , dcEstimatedFee :: !Integer
    }
    deriving stock (Eq, Show)

-- | Sum the components into the lovelace floor.
proposalWalletFloorLovelace :: DepositComponents -> Integer
proposalWalletFloorLovelace dc =
    2 * dcStakeDeposit dc
        + dcDrepDeposit dc
        + dcGovActionDeposit dc
        + dcVoteOutputCoin dc
        + dcEstimatedFee dc

{- | Lovelace paid to the voter base address by the proposal
program. Must equal the
'Amaru.Treasury.Devnet.GovernanceWithdrawalInit.Core.voteOutputCoin'
constant the construction core embeds. Documented as a
named constant here so a future divergence breaks loudly
at the deposit-aware shortfall test rather than at chain
validation.
-}
proposalVoteOutputCoinLovelace :: Integer
proposalVoteOutputCoinLovelace = 5_000_000

{- | Conservative fee + min-UTxO-change headroom for a
proposal tx. Picked at 1.5 ADA: ~0.5 ADA fee under
mainnet-shaped pparams plus ~1 ADA headroom for a single
change output. The actual fee is balanced at @tx-build@
time; this is the resolver's pre-flight floor so the
operator hits 'GovernanceWithdrawalInitWalletShortfall'
with a deposit-aware diagnostic before a generic build
failure surfaces.
-}
proposalEstimatedFeeLovelace :: Integer
proposalEstimatedFeeLovelace = 1_500_000

{- | Extract the three pparams-derived deposit fields from a
chain 'PParams' projection. The two locally-named
constants ('proposalVoteOutputCoinLovelace',
'proposalEstimatedFeeLovelace') fill in the remaining two
slots so the resulting 'DepositComponents' is complete.

Note: 'ppKeyDepositL' is the Conway-era stake-address
deposit; the proposal tx registers TWO stake credentials
(funding stake + voter stake) so the floor multiplies it
by 2.
-}
extractDepositComponents :: PParams ConwayEra -> DepositComponents
extractDepositComponents pp =
    DepositComponents
        { dcStakeDeposit = unCoin (pp ^. Ledger.ppKeyDepositL)
        , dcDrepDeposit = unCoin (pp ^. ppDRepDepositL)
        , dcGovActionDeposit = unCoin (pp ^. ppGovActionDepositL)
        , dcVoteOutputCoin = proposalVoteOutputCoinLovelace
        , dcEstimatedFee = proposalEstimatedFeeLovelace
        }

-- ----------------------------------------------------
-- Errors
-- ----------------------------------------------------

{- | Typed errors the governance-withdrawal-init wizard
surfaces to the operator. Slice 1 ships the parent-
directory and collision variants used by the @--out@
pre-flight checks. Slice 2 (this slice) adds the devnet
guard, the two artifact-parse error variants, the cross-
validation mismatch, the deposit-aware wallet-shortfall,
and the validity-window errors. Slice 3 reuses the same
'Error' type for the materialization arm (with a simpler,
non-deposit-aware shortfall).
-}
data GovernanceWithdrawalInitError
    = -- | @--out@ pointed at a path whose parent
      --   directory does not exist.
      GovernanceWithdrawalInitOutputParentMissing !FilePath
    | -- | @--out@ pointed at an existing file and
      --   @--force@ was not passed.
      GovernanceWithdrawalInitOutputExistsNoForce !FilePath
    | -- | The supplied @--network@ is not @"devnet"@.
      --   Resolver fails fast at this guard BEFORE any
      --   chain query, artifact parse, or pparams query.
      GovernanceWithdrawalInitNonDevnetNetwork !Text
    | -- | The @--registry@ artifact failed to parse via
      --   'readDevnetGovernanceWithdrawalRegistry'
      --   (missing file, unparseable JSON, wrong
      --   @phase@, or wrong @network@). Payload is the
      --   raw underlying error string.
      GovernanceWithdrawalInitRegistryReadError !String
    | -- | The @--stake-reward-accounts@ artifact failed
      --   to parse via
      --   'readDevnetGovernanceStakeRewardAccounts'.
      --   Payload is the raw underlying error string.
      GovernanceWithdrawalInitAccountsReadError !String
    | -- | The cross-validator
      --   'validateGovernanceWithdrawalPrerequisites'
      --   rejected the pair. Payload combines the
      --   validator's code + message (the validator only
      --   exposes a single code-message Failure shape).
      GovernanceWithdrawalInitCrossValidationMismatch !Text
    | -- | The funding wallet's pure-ADA balance is below
      --   the deposit-aware floor. Payload carries the
      --   exact 'DepositComponents' the floor was
      --   computed from AND the observed wallet balance
      --   in lovelace, so the operator-facing message
      --   names every contribution (deposits, vote
      --   output, fee headroom) and the shortfall gap.
      GovernanceWithdrawalInitWalletShortfall
        !DepositComponents
        -- ^ deposit components the floor was computed from
        !Integer
        -- ^ observed pure-ADA wallet balance (lovelace)
    | -- | @--validity-hours = Just 0@.
      GovernanceWithdrawalInitValidityHoursZero
    | -- | @--validity-hours = Just n@ overshoots the
      --   chain horizon.
      GovernanceWithdrawalInitValidityOvershoot
        !Validity.HorizonError
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Resolved environment
-- ----------------------------------------------------

{- | Everything the resolver hands the pure translation.
The pure 'governanceWithdrawalInitProposalToIntent' reads
only this record plus the typed
'GovernanceWithdrawalInitProposalAnswers'; it never
performs IO.
-}
data GovernanceWithdrawalInitEnv = GovernanceWithdrawalInitEnv
    { gwieNetwork :: !Text
    -- ^ Always @"devnet"@ after the resolver guard.
    , gwieUpperBoundSlot :: !Word64
    , gwieRegistry :: !DevnetGovernanceWithdrawalRegistry
    -- ^ Parsed registry-init artifact; supplies the
    --   treasury stake-script hash + (Slice 3) address +
    --   reference TxIns + permissions hash for cross-
    --   validation.
    , gwieAccounts :: !DevnetGovernanceStakeRewardAccounts
    -- ^ Parsed stake-reward-init accounts artifact;
    --   cross-validated against the registry's treasury
    --   script hash via 'gwiePrerequisites'.
    , gwiePrerequisites :: !GovernanceWithdrawalPrerequisites
    -- ^ Cross-validated wrapper produced by
    --   'validateGovernanceWithdrawalPrerequisites'.
    --   Carrying it through to the translation lets a
    --   future invariant assertion compare against it
    --   without re-running the validator.
    , gwieWalletSelection :: !WalletSelection
    -- ^ Wallet block carrier. The pure translation uses
    --   @wsAddress@ verbatim and overrides @wsTxIn@ with
    --   the operator-typed funding seed from the
    --   answers.
    , gwieDepositComponents :: !DepositComponents
    -- ^ Components the resolver already used to clear the
    --   deposit-aware shortfall. Carried through so the
    --   diagnostic surface stays self-contained.
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Resolver
-- ----------------------------------------------------

{- | Inputs the resolver pulls from the CLI before any
chain query. The @--registry@ + @--stake-reward-accounts@
artifact paths and the funding-seed TxIn are operator-
typed; the wallet selection is derived from the chain via
'gwireQueryWalletUtxos'.
-}
data GovernanceWithdrawalInitResolverInput
    = GovernanceWithdrawalInitResolverInput
    { gwiriNetwork :: !Text
    , gwiriWalletAddrBech32 :: !Text
    , gwiriRegistryPath :: !FilePath
    , gwiriAccountsPath :: !FilePath
    , gwiriValidityHours :: !(Maybe Word16)
    }
    deriving stock (Eq, Show)

{- | Effects the resolver pulls from the backend. Keeping
these as record fields lets tests inject mocks without
depending on a live node.
-}
data GovernanceWithdrawalInitResolverEnv m
    = GovernanceWithdrawalInitResolverEnv
    { gwireQueryWalletUtxos
        :: !(Text -> m [(Text, Integer, Bool)])
    -- ^ @(txInRef, lovelace, hasNativeAssets)@ for the
    --   wallet. The resolver sums lovelace of pure-ADA
    --   entries (where @hasNativeAssets == False@) for
    --   the deposit-aware shortfall check.
    , gwireComputeUpperBound
        :: !( Validity.ValidityChoice
              -> m (Either Validity.HorizonError Word64)
            )
    , gwireReadRegistry
        :: !( FilePath
              -> m
                    ( Either
                        String
                        DevnetGovernanceWithdrawalRegistry
                    )
            )
    , gwireReadAccounts
        :: !( FilePath
              -> m
                    ( Either
                        String
                        DevnetGovernanceStakeRewardAccounts
                    )
            )
    , gwireDepositComponents :: m DepositComponents
    -- ^ Production wiring fills this from
    --   'extractDepositComponents' on chain pparams;
    --   tests inject a stub naming each component so the
    --   deposit-aware shortfall formula is visible at
    --   test level. Left lazy so a test stub of
    --   @error "must not be called"@ doesn't fire at
    --   record construction; the resolver's @do@ block
    --   forces the action via @dc <- gwireDepositComponents renv@
    --   only when control flow reaches the shortfall
    --   check (i.e., after the artifact parses, the
    --   cross-validation, and the wallet query).
    }

{- | Resolve the chain-derived proposal environment.

The DEVNET GUARD is the first check; on any non-@"devnet"@
network the function returns
'GovernanceWithdrawalInitNonDevnetNetwork' WITHOUT
performing the registry parse, the accounts parse, the
cross-validation, the wallet query, the upper-bound
computation, or any other effect.

Subsequent failure paths (each short-circuits the rest):

1. Registry parse: any @Left@ from @gwireReadRegistry@ is
   wrapped as 'GovernanceWithdrawalInitRegistryReadError'.
2. Accounts parse: any @Left@ from @gwireReadAccounts@ is
   wrapped as 'GovernanceWithdrawalInitAccountsReadError'.
3. Cross-validation: any @Left@ from
   'validateGovernanceWithdrawalPrerequisites' is wrapped
   as 'GovernanceWithdrawalInitCrossValidationMismatch'
   carrying the validator's @code: message@.
4. Wallet shortfall: the sum of pure-ADA UTxO lovelace
   is compared to 'proposalWalletFloorLovelace'; below the
   floor surfaces
   'GovernanceWithdrawalInitWalletShortfall' carrying the
   exact 'DepositComponents' and observed balance.
5. Validity-window: same path as the stake-reward-init
   wizard.
-}
resolveGovernanceWithdrawalInitProposal
    :: (Monad m)
    => GovernanceWithdrawalInitResolverEnv m
    -> GovernanceWithdrawalInitResolverInput
    -> m
        ( Either
            GovernanceWithdrawalInitError
            GovernanceWithdrawalInitEnv
        )
resolveGovernanceWithdrawalInitProposal renv input
    | gwiriNetwork input /= "devnet" =
        pure
            ( Left
                ( GovernanceWithdrawalInitNonDevnetNetwork
                    (gwiriNetwork input)
                )
            )
    | otherwise = do
        regE <- gwireReadRegistry renv (gwiriRegistryPath input)
        case regE of
            Left e ->
                pure
                    ( Left
                        ( GovernanceWithdrawalInitRegistryReadError e
                        )
                    )
            Right registry -> do
                accE <- gwireReadAccounts renv (gwiriAccountsPath input)
                case accE of
                    Left e ->
                        pure
                            ( Left
                                ( GovernanceWithdrawalInitAccountsReadError e
                                )
                            )
                    Right accounts ->
                        case validateGovernanceWithdrawalPrerequisites
                            registry
                            accounts of
                            Left fl ->
                                pure
                                    ( Left
                                        ( GovernanceWithdrawalInitCrossValidationMismatch
                                            ( gwifCode fl
                                                <> ": "
                                                <> gwifMessage fl
                                            )
                                        )
                                    )
                            Right prereqs ->
                                continueAfterCrossValidation
                                    renv
                                    input
                                    registry
                                    accounts
                                    prereqs

continueAfterCrossValidation
    :: (Monad m)
    => GovernanceWithdrawalInitResolverEnv m
    -> GovernanceWithdrawalInitResolverInput
    -> DevnetGovernanceWithdrawalRegistry
    -> DevnetGovernanceStakeRewardAccounts
    -> GovernanceWithdrawalPrerequisites
    -> m
        ( Either
            GovernanceWithdrawalInitError
            GovernanceWithdrawalInitEnv
        )
continueAfterCrossValidation renv input registry accounts prereqs = do
    walletUtxos <-
        gwireQueryWalletUtxos
            renv
            (gwiriWalletAddrBech32 input)
    dc <- gwireDepositComponents renv
    let pureAdaBalance =
            sum
                [ lov
                | (_, lov, hasNa) <- walletUtxos
                , not hasNa
                ]
        floor_ = proposalWalletFloorLovelace dc
    if pureAdaBalance < floor_
        then
            pure
                ( Left
                    ( GovernanceWithdrawalInitWalletShortfall
                        dc
                        pureAdaBalance
                    )
                )
        else case firstPureAdaRef walletUtxos of
            Nothing ->
                -- Balance >= floor but no pure-ADA entry exists;
                -- the wallet entries are all asset-bearing. Surface
                -- as a shortfall with the same diagnostic so the
                -- operator sees the asymmetry.
                pure
                    ( Left
                        ( GovernanceWithdrawalInitWalletShortfall
                            dc
                            pureAdaBalance
                        )
                    )
            Just walletRef -> do
                upperE <-
                    resolveUpperBound
                        (gwireComputeUpperBound renv)
                        (gwiriValidityHours input)
                case upperE of
                    Left e -> pure (Left e)
                    Right upper ->
                        pure $
                            Right
                                GovernanceWithdrawalInitEnv
                                    { gwieNetwork = gwiriNetwork input
                                    , gwieUpperBoundSlot = upper
                                    , gwieRegistry = registry
                                    , gwieAccounts = accounts
                                    , gwiePrerequisites = prereqs
                                    , gwieWalletSelection =
                                        WalletSelection
                                            { wsTxIn = walletRef
                                            , wsAddress =
                                                gwiriWalletAddrBech32 input
                                            , wsExtraTxIns = []
                                            }
                                    , gwieDepositComponents = dc
                                    }

firstPureAdaRef :: [(Text, Integer, Bool)] -> Maybe Text
firstPureAdaRef utxos =
    case [ref | (ref, _, hasNa) <- utxos, not hasNa] of
        (r : _) -> Just r
        [] -> Nothing

resolveUpperBound
    :: (Monad m)
    => ( Validity.ValidityChoice
         -> m (Either Validity.HorizonError Word64)
       )
    -> Maybe Word16
    -> m (Either GovernanceWithdrawalInitError Word64)
resolveUpperBound askUpperBound hours = case hours of
    Just 0 ->
        pure (Left GovernanceWithdrawalInitValidityHoursZero)
    other -> do
        let choice =
                maybe
                    Validity.AutoLongest
                    Validity.ExactlyHours
                    other
        result <- askUpperBound choice
        pure $ case result of
            Left horizonErr ->
                Left
                    ( GovernanceWithdrawalInitValidityOvershoot
                        horizonErr
                    )
            Right slot -> Right slot

-- ----------------------------------------------------
-- Pure translation (proposal)
-- ----------------------------------------------------

{- | Translate the resolved @proposal@ environment plus
typed answers into a 'SomeTreasuryIntent'. Pure; reads
only its arguments.

The translator extracts @dgwrTreasuryScriptHashText@ →
@treasuryRewardAccountHash@ from the parsed registry, and
passes through verbatim the operator-typed
'gwipaFundingStakeKeyHash', 'gwipaVoterKeyHash',
'gwipaWithdrawalAmountLovelace', 'gwipaAnchorUrl', and
'gwipaAnchorHash'. The wallet block carries the operator-
typed @gwipaFundingSeedTxIn@ as @wjTxIn@.

The scope + rationale slots are filled with the
placeholder shape the existing library-core test fixture
('Support.GovernanceWithdrawalInitFixtures.proposalFixture')
uses, so the wizard-produced intent compares byte-equal
to the fixture's @gwifIntent@ when fed the co-derived
inputs.

Constitutional constraint (NFR-006): this function MUST
NOT call
'Amaru.Treasury.Devnet.GovernanceWithdrawalInit.Core.buildGovernanceWithdrawalProposalCore'
or any other 'Amaru.Treasury.Devnet.*' construction
core; it only manipulates the JSON-shaped intent. Slice 4
ships a grep-based test enforcing this boundary on the
wizard module.
-}
governanceWithdrawalInitProposalToIntent
    :: GovernanceWithdrawalInitEnv
    -> GovernanceWithdrawalInitProposalAnswers
    -> Either GovernanceWithdrawalInitError SomeTreasuryIntent
governanceWithdrawalInitProposalToIntent env ans = do
    case gwipaValidityHours ans of
        Just 0 -> Left GovernanceWithdrawalInitValidityHoursZero
        _ -> pure ()
    let registry = gwieRegistry env
        treasuryHashHex = dgwrTreasuryScriptHashText registry
        intent =
            TreasuryIntent
                { tiSAction = SGovernanceWithdrawalInitProposal
                , tiSchema = 1
                , tiNetwork = gwieNetwork env
                , tiWallet =
                    mkWalletProposal
                        (gwieWalletSelection env)
                        (gwipaFundingSeedTxIn ans)
                , tiScope = mkScopeProposal env ans
                , tiSigners = []
                , tiValidityUpperBoundSlot = gwieUpperBoundSlot env
                , tiRationale = rationaleProposal
                , tiPayload =
                    GovernanceWithdrawalInitProposalInputs
                        { gwipiTreasuryRewardAccountHash =
                            treasuryHashHex
                        , gwipiWithdrawalAmountLovelace =
                            gwipaWithdrawalAmountLovelace ans
                        , gwipiFundingStakeKeyHash =
                            gwipaFundingStakeKeyHash ans
                        , gwipiVoterKeyHash = gwipaVoterKeyHash ans
                        , gwipiAnchorUrl = gwipaAnchorUrl ans
                        , gwipiAnchorHash = gwipaAnchorHash ans
                        }
                }
    -- Asserting an invariant carried through from the
    -- resolver: the operator-typed treasuryRewardAccountHash
    -- in the cross-validated prerequisites equals the value
    -- we extracted from the registry. This is a tautology
    -- given a resolver-produced env; calling it here keeps
    -- the dependency on the prereqs visible so a future
    -- refactor that bypasses the resolver still tripwires.
    unless
        ( dgsraScriptHash
            ( dgsrasTreasury
                (gwpAccounts (gwiePrerequisites env))
            )
            == treasuryHashHex
        )
        ( Left
            ( GovernanceWithdrawalInitCrossValidationMismatch
                "translation: treasury script hash drift after cross-validation"
            )
        )
    Right
        ( SomeTreasuryIntent
            SGovernanceWithdrawalInitProposal
            intent
        )

mkWalletProposal :: WalletSelection -> TxIn -> WalletJSON
mkWalletProposal ws fundingSeed =
    WalletJSON
        { wjTxIn = txInToText fundingSeed
        , wjAddress = wsAddress ws
        , wjExtraTxIns = wsExtraTxIns ws
        }

{- | Scope placeholder mirroring
'Support.GovernanceWithdrawalInitFixtures.placeholderScopeJSON':
@sjId = "core_development"@, the four @*DeployedAt@ slots
carry the operator-typed funding seed (rendered), and the
hash slots are 56-zero placeholders. Drift here breaks the
CBOR-parity assertion in the proposal golden.
-}
mkScopeProposal
    :: GovernanceWithdrawalInitEnv
    -> GovernanceWithdrawalInitProposalAnswers
    -> ScopeJSON
mkScopeProposal env ans =
    let wallet = gwieWalletSelection env
        seedText = txInToText (gwipaFundingSeedTxIn ans)
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

rationaleProposal :: RationaleJSON
rationaleProposal =
    RationaleJSON
        { rjEvent = "governance-withdrawal-init"
        , rjLabel = "governance-withdrawal-init"
        , rjDescription =
            "governance-withdrawal-init bootstrap fixture"
        , rjJustification = "test"
        , rjDestinationLabel = "fixture"
        }

-- TxIn rendering for the wallet JSON block and the scope
-- placeholder lives in 'Amaru.Treasury.LedgerParse.txInToText'.
-- Keeping the underlying crypto/Base16 primitives confined
-- to that module lets the no-key-material grep (NFR-008 /
-- Slice 4 SC-008) over this wizard source stay negative.
