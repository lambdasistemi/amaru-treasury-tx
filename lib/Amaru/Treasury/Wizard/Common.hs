{- |
Module      : Amaru.Treasury.Wizard.Common
Description : Shared signer-resolver primitives across wizards
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Pure primitives shared by every per-action wizard's
signer resolver. Bodies are lifted verbatim from
[`Amaru.Treasury.Tx.SwapWizard`](https://github.com/lambdasistemi/amaru-treasury-tx/blob/main/lib/Amaru/Treasury/Tx/SwapWizard.hs)
in this commit; the originals there are deleted in T012
(this commit).

This module intentionally exposes only the primitives
that don't depend on a wizard-specific error type or
record. Callers (per-action wizards) wrap these into
their own typed errors and 'ScopeOwners' record.

The 'NetworkConstants' table and the type itself stay in
'Tx.SwapWizard' for now — they get moved here when the
SwapWizard module is fully collapsed in T021.
-}
module Amaru.Treasury.Wizard.Common
    ( isHex28
    , normaliseSignerToken
    , signerScopeFromText
    ) where

import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as T

import Amaru.Treasury.Scope
    ( ScopeId
        ( Contingency
        , CoreDevelopment
        , Middleware
        , NetworkCompliance
        , OpsAndUseCases
        )
    )

{- | True iff the text is exactly 56 hex characters
(28 bytes). Used to distinguish a raw keyhash token from
a scope-name signer token.
-}
isHex28 :: Text -> Bool
isHex28 t =
    T.length t == 56 && T.all isHexChar t
  where
    isHexChar c =
        isDigit c
            || (c >= 'a' && c <= 'f')
            || (c >= 'A' && c <= 'F')

{- | Lower-case + dash-to-underscore so the operator can
type @"core-development"@, @"core_development"@, or
@"Core Development"@ interchangeably.
-}
normaliseSignerToken :: Text -> Text
normaliseSignerToken =
    T.map dashToUnderscore . T.toLower
  where
    dashToUnderscore '-' = '_'
    dashToUnderscore c = c

{- | Map a normalised signer token to a 'ScopeId',
accepting common shorthands. Returns 'Nothing' if the
token isn't a recognised scope name (the caller decides
whether to fall back to 'isHex28' parsing or to fail).
-}
signerScopeFromText :: Text -> Maybe ScopeId
signerScopeFromText t = case normaliseSignerToken t of
    "core" -> Just CoreDevelopment
    "core_development" -> Just CoreDevelopment
    "coredevelopment" -> Just CoreDevelopment
    "ops" -> Just OpsAndUseCases
    "ops_and_use_cases" -> Just OpsAndUseCases
    "opsandusecases" -> Just OpsAndUseCases
    "network" -> Just NetworkCompliance
    "network_compliance" -> Just NetworkCompliance
    "networkcompliance" -> Just NetworkCompliance
    "middleware" -> Just Middleware
    "contingency" -> Just Contingency
    _ -> Nothing
