{-# LANGUAGE DataKinds #-}

{- |
Module      : Amaru.Treasury.Tx.RegistryInitWizard
Description : Typed-Q&A wizard data types for the registry-init wizard family
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

The registry-init wizard is split into three sub-actions
(@seed-split@, @mint@, @reference-scripts@) mirroring the
'Amaru.Treasury.IntentJSON.SAction' variants
'RegistryInitSeedSplit', 'RegistryInitMint', and
'RegistryInitReferenceScripts'.

Slice 1 of #158 ships only the typed Answers records and
the 'RegistryInitError' surface used by the parser-layer
checks. The resolver, the @RegistryInitEnv@ type, the pure
translations, and the live runner paths land in Slices 2-4.
-}
module Amaru.Treasury.Tx.RegistryInitWizard
    ( -- * Answers
      RegistryInitSeedSplitAnswers (..)
    , RegistryInitMintAnswers (..)
    , RegistryInitReferenceScriptsAnswers (..)

      -- * Errors
    , RegistryInitError (..)
    ) where

import Data.Text (Text)
import Data.Word (Word16)

import Cardano.Ledger.Hashes (KeyHash (..))
import Cardano.Ledger.Keys (KeyRole (Witness))
import Cardano.Ledger.TxIn (TxIn)

import Amaru.Treasury.Scope (ScopeId)

-- ----------------------------------------------------
-- Answers
-- ----------------------------------------------------

{- | Typed operator answers for the @seed-split@ sub-action.

The seed UTxO comes from the resolver (Slice 2), not from
operator-typed flags; only the scope, validity, and rationale
overrides are carried here.
-}
data RegistryInitSeedSplitAnswers = RegistryInitSeedSplitAnswers
    { risScope :: !ScopeId
    , risValidityHours :: !(Maybe Word16)
    , risDescription :: !(Maybe Text)
    , risJustification :: !(Maybe Text)
    , risDestinationLabel :: !(Maybe Text)
    , risEvent :: !(Maybe Text)
    , risLabel :: !(Maybe Text)
    }
    deriving stock (Eq, Show)

{- | Typed operator answers for the @mint@ sub-action.

The three extra fields are operator-typed inter-tx state
that the wizard cannot derive from chain query in Slice 1:

* @rimScopesSeedTxIn@ — first output of the seed-split sub-tx.
* @rimRegistrySeedTxIn@ — second output of the seed-split sub-tx.
* @rimOwnerKeyHash@ — scope owner key hash baked into the
  scopes NFT datum.
-}
data RegistryInitMintAnswers = RegistryInitMintAnswers
    { rimScope :: !ScopeId
    , rimValidityHours :: !(Maybe Word16)
    , rimDescription :: !(Maybe Text)
    , rimJustification :: !(Maybe Text)
    , rimDestinationLabel :: !(Maybe Text)
    , rimEvent :: !(Maybe Text)
    , rimLabel :: !(Maybe Text)
    , rimScopesSeedTxIn :: !TxIn
    , rimRegistrySeedTxIn :: !TxIn
    , rimOwnerKeyHash :: !(KeyHash Witness)
    }
    deriving stock (Eq, Show)

{- | Typed operator answers for the @reference-scripts@
sub-action.

The three TxIn fields are operator-typed inter-tx state:
the two seed TxIns reproduce the mint sub-tx's script
derivation, and the funding seed TxIn pays the
reference-scripts deposits.
-}
data RegistryInitReferenceScriptsAnswers
    = RegistryInitReferenceScriptsAnswers
    { rirScope :: !ScopeId
    , rirValidityHours :: !(Maybe Word16)
    , rirDescription :: !(Maybe Text)
    , rirJustification :: !(Maybe Text)
    , rirDestinationLabel :: !(Maybe Text)
    , rirEvent :: !(Maybe Text)
    , rirLabel :: !(Maybe Text)
    , rirScopesSeedTxIn :: !TxIn
    , rirRegistrySeedTxIn :: !TxIn
    , rirFundingSeedTxIn :: !TxIn
    }
    deriving stock (Eq, Show)

-- ----------------------------------------------------
-- Errors
-- ----------------------------------------------------

{- | Typed errors the registry-init wizard surfaces to the
operator. Slice 1 only ships the parent-directory and
collision variants used by the @--out@ pre-flight checks.
Slices 2-4 extend with @RegistryInitNonDevnetNetwork@,
@RegistryInitWalletShortfall@, and the per-sub-action
translation errors.
-}
data RegistryInitError
    = -- | @--out@ pointed at a path whose parent directory
      --   does not exist.
      RegistryInitOutputParentMissing !FilePath
    | -- | @--out@ pointed at an existing file and
      --   @--force@ was not passed.
      RegistryInitOutputExistsNoForce !FilePath
    deriving stock (Eq, Show)
