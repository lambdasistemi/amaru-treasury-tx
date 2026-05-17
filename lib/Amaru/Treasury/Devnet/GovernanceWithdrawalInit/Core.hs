{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE LambdaCase #-}

{- |
Module      : Amaru.Treasury.Devnet.GovernanceWithdrawalInit.Core
Description : Pure construction cores for the
              @governance-withdrawal-init-*@ sub-actions
License     : Apache-2.0

Extracted construction cores for the two flat
@governance-withdrawal-init-*@ intents. Kept in a
dedicated module (no @Amaru.Treasury.Report@ imports) so
the offline @tx-build@ dispatcher under
"Amaru.Treasury.Build.GovernanceWithdrawalInit" can pull
them in without re-introducing the
@Build → Report → Build@ cycle that the live runner in
"Amaru.Treasury.Devnet.GovernanceWithdrawalInit" carries.

Each core wraps a single 'TxBuild' program shape used by
the live DevNet submitter; the live runner re-exports the
cores so its public surface includes them.
-}
module Amaru.Treasury.Devnet.GovernanceWithdrawalInit.Core
    ( -- * Evaluator
      GovernanceWithdrawalCoreEvaluator

      -- * Construction cores
    , buildGovernanceWithdrawalProposalCore
    , buildGovernanceWithdrawalMaterializationCore

      -- * Underlying TxBuild programs

    --
    -- \^ Exposed mainly to keep
    -- 'governanceWithdrawalProposalProgram' (the
    -- module-level wrapper used by the DevNet submitter)
    -- defined in terms of the anchored variant.
    , governanceWithdrawalProposalProgramAnchored

      -- * Constants used by the proposal program
    , stakeDeposit
    , governanceDeposit
    , drepDeposit
    , voteOutputCoin

      -- * Empty interpret
    , NoCtx
    , governanceWithdrawalEmptyInterpret
    ) where

import Data.Map.Strict qualified as Map
import Data.Void (Void)

import Cardano.Ledger.Address
    ( AccountAddress
    , Addr
    )
import Cardano.Ledger.Alonzo.Scripts (AsIx)
import Cardano.Ledger.BaseTypes
    ( Inject (..)
    , StrictMaybe (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Conway.Governance (Anchor)
import Cardano.Ledger.Conway.Scripts (ConwayPlutusPurpose)
import Cardano.Ledger.Core (PParams)
import Cardano.Ledger.Credential (Credential)
import Cardano.Ledger.Hashes (KeyHash)
import Cardano.Ledger.Keys (KeyRole (DRepRole, Staking))
import Cardano.Ledger.Plutus.ExUnits (ExUnits)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Slotting.Slot (SlotNo)
import Cardano.Tx.Build
    ( CertWitness (..)
    , ConwayDelegCert (..)
    , ConwayGovCert (..)
    , ConwayTxCert (..)
    , DRep (..)
    , Delegatee (..)
    , InterpretIO (..)
    , ProposalWitness (..)
    , TxBuild
    , build
    , certify
    , collateral
    , mkPParamsBound
    , payTo
    , proposeTreasuryWithdrawal
    , registerAndVoteAbstain
    , spend
    , validTo
    )
import Cardano.Tx.Build qualified as TxBuild
import Cardano.Tx.Ledger (ConwayTx)

import Amaru.Treasury.Tx.Withdraw
    ( WithdrawIntent (..)
    , withdrawProgram
    )
import Cardano.Ledger.Api.Tx.Out (TxOut)

{- | Tag with no inhabitants used as the context type for
the empty 'InterpretIO'. The construction cores never need
an application-level context, so any context request would
be unreachable.
-}
data NoCtx a

{- | Shape of the script evaluator the construction cores
hand to 'Cardano.Tx.Build.build'.

The @tx-build@ infrastructure consumes a per-purpose map
keyed by 'ConwayPlutusPurpose' 'AsIx' and producing either
an error string or the evaluator's 'ExUnits'. The live
'Provider' returns a richer error type; the @tx-build@
dispatcher and the live submitter each wrap their
'evaluateTx' into this simpler shape before calling the
cores.
-}
type GovernanceWithdrawalCoreEvaluator =
    ConwayTx
    -> IO
        ( Map.Map
            (ConwayPlutusPurpose AsIx ConwayEra)
            (Either String ExUnits)
        )

{- | Pure-IO construction core for the
@governance-withdrawal-init-proposal@ sub-transaction.

Spends a single funding UTxO that doubles as collateral,
registers the funding stake credential (delegating its
vote to @AlwaysAbstain@), registers a DRep, registers the
voter stake credential delegating its vote to that DRep,
pays a small UTxO to the voter base address (which the
follow-up vote tx will spend), and proposes a treasury
withdrawal into the supplied @treasuryAccount@ for the
supplied @amount@. The governance anchor is supplied by
the caller so the same core can drive both the production
DevNet submitter (which uses a fixed example anchor) and
test fixtures.

No Plutus scripts are involved (all certificates are
@PubKeyCert@-witnessed and the proposal carries
@NoProposalScript@), so the evaluator is expected to
return an empty map.

Returns the unsigned 'ConwayTx' as balanced by
'Cardano.Tx.Build.build'; the caller is responsible for
signing, submission, and waiting.
-}
buildGovernanceWithdrawalProposalCore
    :: PParams ConwayEra
    -> Addr
    -- ^ funding/change address (must match seed UTxO owner)
    -> Credential Staking
    -- ^ funding stake credential — registered, delegated
    --     to @AlwaysAbstain@, and used as the proposal's
    --     reward-return account
    -> Credential Staking
    -- ^ voter stake credential — registered and delegated
    --     to the new DRep
    -> Credential DRepRole
    -- ^ DRep credential — newly registered
    -> KeyHash DRepRole
    -- ^ DRep key hash — target of the voter delegation
    -> Addr
    -- ^ voter base address — receives the seed UTxO the
    --     follow-up vote tx spends
    -> AccountAddress
    -- ^ return account — receives the proposal deposit if
    --     the proposal is rejected
    -> AccountAddress
    -- ^ treasury reward account — destination of the
    --     proposed withdrawal
    -> Coin
    -- ^ withdrawal amount (lovelace)
    -> SlotNo
    -- ^ validity upper bound
    -> Anchor
    -- ^ CIP-1694 governance anchor (URL + content hash)
    -> (TxIn, TxOut ConwayEra)
    -- ^ funding seed UTxO (also collateral)
    -> GovernanceWithdrawalCoreEvaluator
    -> IO (Either (TxBuild.BuildError Void) ConwayTx)
buildGovernanceWithdrawalProposalCore
    pp
    fundingAddress
    fundingCredential
    voterCredential
    drepCredential
    drepKey
    voterBaseAddr
    returnAccount
    treasuryAccount
    amount
    upperSlot
    anchor
    seed@(seedIn, _)
    eval = do
        let prog :: TxBuild NoCtx Void ()
            prog =
                governanceWithdrawalProposalProgramAnchored
                    seedIn
                    fundingCredential
                    voterCredential
                    drepCredential
                    drepKey
                    voterBaseAddr
                    returnAccount
                    treasuryAccount
                    amount
                    upperSlot
                    anchor
        build
            (mkPParamsBound pp)
            governanceWithdrawalEmptyInterpret
            eval
            [seed]
            []
            fundingAddress
            prog

{- | Pure 'TxBuild' program for the proposal sub-action,
parameterized by the governance 'Anchor'. The original
@governanceWithdrawalProposalProgram@ in
"Amaru.Treasury.Devnet.GovernanceWithdrawalInit" is now a
thin alias that supplies the module-level
@governanceAnchor@ constant.
-}
governanceWithdrawalProposalProgramAnchored
    :: TxIn
    -> Credential Staking
    -> Credential Staking
    -> Credential DRepRole
    -> KeyHash DRepRole
    -> Addr
    -> AccountAddress
    -> AccountAddress
    -> Coin
    -> SlotNo
    -> Anchor
    -> TxBuild NoCtx Void ()
governanceWithdrawalProposalProgramAnchored
    seedIn
    fundingCredential
    voterCredential
    drepCredential
    drepKey
    voterBaseAddr
    returnAccount
    treasuryAccount
    amount
    upperSlot
    anchor = do
        _ <- spend seedIn
        collateral seedIn
        _ <-
            registerAndVoteAbstain
                fundingCredential
                stakeDeposit
                PubKeyCert
        _ <-
            certify
                ( ConwayTxCertGov $
                    ConwayRegDRep drepCredential drepDeposit SNothing
                )
                PubKeyCert
        _ <-
            certify
                ( ConwayTxCertDeleg $
                    ConwayRegDelegCert
                        voterCredential
                        (DelegVote (DRepKeyHash drepKey))
                        stakeDeposit
                )
                PubKeyCert
        _ <- payTo voterBaseAddr (inject voteOutputCoin)
        _ <-
            proposeTreasuryWithdrawal
                governanceDeposit
                returnAccount
                anchor
                (Map.singleton treasuryAccount amount)
                SNothing
                NoProposalScript
        validTo upperSlot

{- | Pure-IO construction core for the
@governance-withdrawal-init-materialization@
sub-transaction.

Builds the materialization tx that pulls the treasury
reward balance into the treasury contract address. The
program shape is identical to the unified @withdraw@
action's 'Amaru.Treasury.Tx.Withdraw.withdrawProgram':
spend wallet fuel (also collateral), reference the
deployed treasury and registry scripts, withdraw the
balance via the treasury script (single Plutus
@ConwayRewarding@ redeemer), forward the rewards to the
treasury contract address, set validity.

Per-script ExUnits are supplied by the caller via the
evaluator argument; the materialization tx contains
exactly one Plutus redeemer.

Returns the unsigned 'ConwayTx' as balanced by
'Cardano.Tx.Build.build'.
-}
buildGovernanceWithdrawalMaterializationCore
    :: PParams ConwayEra
    -> Addr
    -- ^ funding/change address
    -> AccountAddress
    -- ^ treasury reward account (script-witnessed)
    -> Addr
    -- ^ treasury contract address (destination)
    -> TxIn
    -- ^ treasury reference-script TxIn
    -> TxIn
    -- ^ registry reference-script TxIn
    -> Coin
    -- ^ rewards balance (lovelace) to withdraw
    -> SlotNo
    -- ^ validity upper bound
    -> (TxIn, TxOut ConwayEra)
    -- ^ funding seed UTxO (also collateral)
    -> (TxIn, TxOut ConwayEra)
    -- ^ treasury reference-script UTxO
    -> (TxIn, TxOut ConwayEra)
    -- ^ registry reference-script UTxO
    -> GovernanceWithdrawalCoreEvaluator
    -> IO (Either (TxBuild.BuildError Void) ConwayTx)
buildGovernanceWithdrawalMaterializationCore
    pp
    fundingAddress
    treasuryRewardAccount
    treasuryAddress
    treasuryRef
    registryRef
    rewardsAmount
    upperSlot
    seed
    treasuryRefUtxo
    registryRefUtxo
    eval = do
        let intent =
                WithdrawIntent
                    { wiWalletUtxo = fst seed
                    , wiTreasuryRewardAccount =
                        treasuryRewardAccount
                    , wiTreasuryAddress = treasuryAddress
                    , wiTreasuryDeployedAt = treasuryRef
                    , wiRegistryDeployedAt = registryRef
                    , wiRewardsAmount = rewardsAmount
                    , wiUpperBound = upperSlot
                    }
            prog :: TxBuild NoCtx Void ()
            prog = withdrawProgram intent
        build
            (mkPParamsBound pp)
            governanceWithdrawalEmptyInterpret
            eval
            [seed]
            [treasuryRefUtxo, registryRefUtxo]
            fundingAddress
            prog

{- | Empty 'InterpretIO' used by the construction cores.
The 'NoCtx' tag has no inhabitants so no context request
is reachable.
-}
governanceWithdrawalEmptyInterpret :: InterpretIO NoCtx
governanceWithdrawalEmptyInterpret =
    InterpretIO $ \case {}

-- | Stake-key deposit baked into the proposal program.
stakeDeposit :: Coin
stakeDeposit = Coin 400_000

-- | Governance proposal deposit baked into the program.
governanceDeposit :: Coin
governanceDeposit = Coin 1_000_000

-- | DRep registration deposit baked into the program.
drepDeposit :: Coin
drepDeposit = Coin 500_000

-- | Lovelace paid to the voter base address.
voteOutputCoin :: Coin
voteOutputCoin = Coin 5_000_000
