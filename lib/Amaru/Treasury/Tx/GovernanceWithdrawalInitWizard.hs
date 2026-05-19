{- |
Module      : Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard
Description : Typed-Q&A wizard data types for the governance-withdrawal-init wizard family
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The governance-withdrawal-init wizard is split into two
sub-actions (@proposal@, @materialization@) mirroring the
'Amaru.Treasury.IntentJSON.SAction' variants
'GovernanceWithdrawalInitProposal' and
'GovernanceWithdrawalInitMaterialization' (#157).

Slice 1 of [#160](https://github.com/lambdasistemi/amaru-treasury-tx/issues/160)
ships the typed 'Answers' records and the parser-layer
errors. Slice 2 adds the resolver layer for the
@proposal@ sub-action, the devnet network guard, the
artifact-file parses (registry + stake-reward accounts)
via the existing
'Amaru.Treasury.Devnet.GovernanceWithdrawalInit.readDevnetGovernanceWithdrawalRegistry'
and
'Amaru.Treasury.Devnet.GovernanceWithdrawalInit.readDevnetGovernanceStakeRewardAccounts',
the cross-validation via
'validateGovernanceWithdrawalPrerequisites', the
deposit-aware wallet-shortfall check (FR-008), and the
pure translation to
'Amaru.Treasury.IntentJSON.SomeTreasuryIntent' for the
proposal arm. Slice 3 wires materialization on the same
shape with a simpler shortfall.

Unlike the stake-reward-init wizard family (#159), this
wizard's proposal sub-action requires the operator to type
two 28-byte governance key hashes
(@--funding-stake-key-hash@, @--voter-key-hash@), a
CIP-1694 32-byte anchor content hash (@--anchor-hash@), a
withdrawal amount, and an anchor URL. Per NFR-008 the
wizard touches no key material itself: the hashes are
operator-declared hex strings, validated for length, and
passed through verbatim into the resulting intent. Source-
of-truth consistency between the declared hashes and the
keys the operator will sign with at @witness@ time is the
operator's responsibility, caught at @witness@ time as a
required-signer mismatch if violated.
-}
module Amaru.Treasury.Tx.GovernanceWithdrawalInitWizard
    ( -- * Answers
      GovernanceWithdrawalInitProposalAnswers (..)
    , GovernanceWithdrawalInitMaterializationAnswers (..)

      -- * Errors
    , GovernanceWithdrawalInitError (..)
    ) where

import Data.Text (Text)
import Data.Word (Word16)

import Cardano.Ledger.TxIn (TxIn)

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
    -- ^ 28-byte (56 hex char) key hash; pass-through into
    -- 'Amaru.Treasury.IntentJSON.GovernanceWithdrawalInitProposalInputs.gwipiFundingStakeKeyHash'.
    , gwipaVoterKeyHash :: !Text
    -- ^ 28-byte (56 hex char) key hash; pass-through into
    -- 'gwipiVoterKeyHash'. Reused by the library at three
    -- role slots (voter stake credential, voter payment
    -- credential, DRep credential) via type-coercion
    -- identities — one physical witness satisfies all
    -- three.
    , gwipaWithdrawalAmountLovelace :: !Integer
    -- ^ Strictly positive; the parser rejects zero or
    -- negative values.
    , gwipaAnchorUrl :: !Text
    -- ^ CIP-1694 governance anchor URL; pass-through.
    , gwipaAnchorHash :: !Text
    -- ^ 32-byte (64 hex char) anchor content hash; pass-
    -- through. The wizard does NOT fetch the URL or
    -- verify the content hashes to this value — content
    -- coherence is operator-managed.
    }
    deriving stock (Eq, Show)

{- | Typed operator answers for the @materialization@
sub-action.

The wizard derives 'gwimiTreasuryRewardAccountHash',
'gwimiTreasuryAddress', 'gwimiTreasuryRefTxIn', and
'gwimiRegistryRefTxIn' from the @--registry@ artifact at
Slice 3 time; the only operator-typed payload field is
'gwipaRewardsLovelace' — the post-enactment treasury
reward balance the operator observed off-chain.
-}
data GovernanceWithdrawalInitMaterializationAnswers
    = GovernanceWithdrawalInitMaterializationAnswers
    { gwimaValidityHours :: !(Maybe Word16)
    , gwimaFundingSeedTxIn :: !TxIn
    , gwimaRewardsLovelace :: !Integer
    -- ^ Strictly positive; the parser rejects zero or
    -- negative values.
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Errors
-- ----------------------------------------------------

{- | Typed errors the governance-withdrawal-init wizard
surfaces to the operator. Slice 1 ships the parent-
directory and collision variants used by the @--out@
pre-flight checks. Slice 2 adds the devnet guard, the
wallet-shortfall path (deposit-aware for @proposal@), the
two artifact-parse error variants
(@GovernanceWithdrawalInitRegistryReadError@,
@GovernanceWithdrawalInitAccountsReadError@), the cross-
validation mismatch
(@GovernanceWithdrawalInitCrossValidationMismatch@), and
the validity-window errors. Slice 3 reuses the same
'Error' type for the materialization arm.
-}
data GovernanceWithdrawalInitError
    = -- | @--out@ pointed at a path whose parent
      --   directory does not exist.
      GovernanceWithdrawalInitOutputParentMissing !FilePath
    | -- | @--out@ pointed at an existing file and
      --   @--force@ was not passed.
      GovernanceWithdrawalInitOutputExistsNoForce !FilePath
    deriving stock (Eq, Show)
