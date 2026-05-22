{- |
Module      : Amaru.Treasury.Tx.ReorganizeWizard
Description : Typed answers and error sum for the reorganize-wizard scaffold
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Slice 1 of #186 (parser scaffold + TODO-stub runner). Exposes
the typed answers record that #187's runner body will consume
and the error sum the runner shell surfaces to stderr. The
answers record is shipped early so #187 can extend
'ReorganizeError' with runner-body variants without churning
this module's public surface; the Slice-1 stub runner never
constructs an 'ReorganizeWizardAnswers' value.

The @Opts → Answers@ projection lives in
'Amaru.Treasury.Cli.ReorganizeWizard' (where the
'ReorganizeWizardOpts' record itself is defined): keeping the
projection on the parser side mirrors the sibling convention
in 'Amaru.Treasury.Cli.RegistryInitWizard' and avoids a
circular import.
-}
module Amaru.Treasury.Tx.ReorganizeWizard
    ( -- * Answers
      ReorganizeWizardAnswers (..)

      -- * Errors
    , ReorganizeError (..)
    ) where

import Data.Text (Text)
import Data.Word (Word16)

import Cardano.Ledger.TxIn (TxIn)

import Amaru.Treasury.Scope (ScopeId)

{- | Typed operator answers for the reorganize wizard.

The "interview answers" view of the parsed
'Amaru.Treasury.Cli.ReorganizeWizard.ReorganizeWizardOpts'
record — same operator-typed values, with the runner-shell
fields ('cfOut', 'cfForce', 'cfLog') dropped. Slice 1 ships
the record so #187 can consume it without churning the public
module surface; the Slice-1 stub runner never constructs one.
-}
data ReorganizeWizardAnswers = ReorganizeWizardAnswers
    { rwaWalletAddr :: !Text
    , rwaMetadataPath :: !FilePath
    , rwaScope :: !ScopeId
    , rwaValidityHours :: !(Maybe Word16)
    , rwaDescription :: !(Maybe Text)
    , rwaJustification :: !(Maybe Text)
    , rwaDestinationLabel :: !(Maybe Text)
    , rwaEvent :: !(Maybe Text)
    , rwaLabel :: !(Maybe Text)
    , rwaFundingSeedTxIn :: !TxIn
    }
    deriving stock (Eq, Show)

{- | Typed error sum surfaced by the reorganize-wizard runner.

Each variant maps to a CLI exit code via the @exitCodeFor@
helper in 'Amaru.Treasury.Cli.ReorganizeWizard': pre-flight
variants surface at exit code 2; the runner-stub marker
'ReorganizeTodoSliceC' surfaces at exit code 3. #187 will
grow this sum with the runner-body error variants (chain
query failure, missing UTxO, validity-bound computation
failure, etc.).
-}
data ReorganizeError
    = -- | @--out@'s parent directory does not exist; exit 2.
      ReorganizeOutputParentMissing !FilePath
    | -- | @--out@ points at an existing file and @--force@ was
      -- not passed; exit 2.
      ReorganizeOutputExistsNoForce !FilePath
    | -- | @--network@ is not @"devnet"@; exit 2. Carries the
      -- offending network name so test specs can pin the
      -- exact value.
      ReorganizeNonDevnetNetwork !Text
    | -- | Stub marker: the real runner body lands in #187
      -- (Slice C of epic #189); exit 3.
      ReorganizeTodoSliceC
    deriving stock (Eq, Show)
