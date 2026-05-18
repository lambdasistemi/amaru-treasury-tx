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
ships the typed 'Answers' records and the parser-layer
errors. Slices 2 and 3 add the resolver layer, the devnet
network guard (a fail-fast UX that fires BEFORE any chain
query), the registry-file parse via the existing
'Amaru.Treasury.Devnet.StakeRewardInit.readDevnetStakeRewardRegistry',
and the two pure translations to
'Amaru.Treasury.IntentJSON.SomeTreasuryIntent'.

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
    ) where

import Data.Text (Text)
import Data.Word (Word16)

import Cardano.Ledger.TxIn (TxIn)

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
variants used by the @--out@ pre-flight checks. Slices 2-3
add the devnet guard, the wallet-shortfall path, and the
registry-file parse variants.

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
    deriving stock (Eq, Show)
