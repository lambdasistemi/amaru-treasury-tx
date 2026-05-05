# Phase 1 Data Model: Upstream metadata fetch + chain sanity-check

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-05

This file pins the Haskell types that cross module boundaries
inside `Amaru.Treasury.Metadata.Upstream`. Implementation-only
helpers land with the code.

## 1. UpstreamMetadata — the parsed JSON shape

Mirrors
[`pragma-org/amaru-treasury/journal/2026/metadata.json`](https://github.com/pragma-org/amaru-treasury/blob/main/journal/2026/metadata.json).

```haskell
module Amaru.Treasury.Metadata.Upstream where

import Data.Text (Text)
import Data.Map.Strict (Map)

import Amaru.Treasury.Scope (ScopeId)

data UpstreamMetadata = UpstreamMetadata
    { umScopeOwners :: !TxInRef
    -- ^ TxIn carrying the on-chain Scopes NFT. e.g.
    --   @"11ace24a...#00"@.
    , umTreasuries :: !(Map ScopeId TreasuryEntry)
    }
    deriving (Eq, Show)

data TreasuryEntry = TreasuryEntry
    { teOwner :: !(Maybe Text)
    -- ^ 28-byte hex of the scope's primary owner key.
    --   @Nothing@ for the contingency scope.
    , teAddress :: !Text
    -- ^ bech32 treasury address.
    , teTreasuryScript :: !ScriptDeployment
    , tePermissionsScript :: !ScriptDeployment
    , teRegistryScript :: !ScriptDeployment
    }
    deriving (Eq, Show)

data ScriptDeployment = ScriptDeployment
    { sdHash :: !Text
    -- ^ 28-byte hex of the validator's script hash.
    , sdDeployedAt :: !TxInRef
    -- ^ TxIn carrying the script as a reference script.
    }
    deriving (Eq, Show)

newtype TxInRef = TxInRef Text
    -- ^ canonical @"<txid>#<ix>"@ form
    deriving (Eq, Ord, Show)
```

Notes:
- `FromJSON UpstreamMetadata` follows the upstream schema field
  for field. Unknown extra fields are ignored (forward
  compatibility). Missing required fields fail the parse with a
  message naming the field.
- `Map ScopeId TreasuryEntry` is keyed by the same canonical
  scope names used elsewhere in the project
  (`core_development`, `ops_and_use_cases`, `network_compliance`,
  `middleware`, `contingency`).

## 2. Errors

```haskell
data MetadataError
    = MetadataFetchHttp !Int !Text
    -- ^ HTTP status + URL
    | MetadataFetchTimeout !Text
    -- ^ URL
    | MetadataFetchTransport !Text
    -- ^ generic transport failure (DNS, TLS, etc.)
    | MetadataParse !String
    -- ^ aeson decode failure message
    | ChainVerificationSpent !TxInRef !Text
    -- ^ ref + a label saying which slot it was
    --   (e.g. "treasury_script.deployed_at for scope=core_development")
    | ChainVerificationProviderError !Text
    -- ^ Provider IO surfaced an error during queryUTxOByTxIn
    deriving (Eq, Show)
```

## 3. The fetch + verify entry point

```haskell
fetchAndVerifyMetadata
    :: MetadataFetcher IO
    -> Provider IO
    -> Text       -- ^ commit SHA (40-char hex)
    -> ScopeId    -- ^ which scope's deployed-at refs to verify
    -> IO (Either MetadataError UpstreamMetadata)
```

Behaviour:

1. Build the URL
   `https://raw.githubusercontent.com/pragma-org/amaru-treasury/<sha>/journal/2026/metadata.json`.
2. Call the `MetadataFetcher` to get the body bytes.
3. Parse into `UpstreamMetadata`. Any aeson failure surfaces as
   `MetadataParse`.
4. For each TxIn in the verify-set (see §4) call
   `Provider.queryUTxOByTxIn (Set.singleton ref)`. Empty result =
   `ChainVerificationSpent`.
5. Return `Right md` on success.

Total. No IOExceptions escape the function — `MetadataFetcher`
catches HTTP/transport failures and returns them as typed
errors.

## 4. Verify-set

For requested scope `s`:

- `umScopeOwners`
- `teTreasuryScript.sdDeployedAt` of `umTreasuries ! s`
- `tePermissionsScript.sdDeployedAt` of `umTreasuries ! s`
- `teRegistryScript.sdDeployedAt` of `umTreasuries ! s`

Other scopes' refs are intentionally not checked (research R6).

## 5. The fetcher abstraction

```haskell
newtype MetadataFetcher m = MetadataFetcher
    { runFetcher :: Text -> m (Either MetadataError ByteString)
    -- ^ url -> body or error
    }
```

Production builds this once via `httpFetcher :: Manager ->
MetadataFetcher IO`. Tests construct
`pureFetcher :: Map Text ByteString -> MetadataFetcher IO`
that returns the mapped body for a known URL.

## 6. The pinned default

```haskell
defaultUpstreamCommit :: Text
defaultUpstreamCommit = "<40-hex-sha>"  -- updated by PR
```

Comment line above the constant cites the upstream branch
(`main`) and the rationale for the chosen pin (e.g. "merge
commit of upstream PR #N").

## 7. Projection to the wizard's `RegistryView`

The wizard branch (`002-swap-wizard`) carries a `RegistryView`
record. Once this branch lands on `main` and the wizard rebases,
it consumes:

```haskell
projectRegistryView
    :: UpstreamMetadata
    -> Either MetadataError RegistryView
```

Pure, total. Maps `umScopeOwners` to `rvScopesDeployedAt`,
`umTreasuries` to `rvTreasuryByScope` and `rvOwners`, derives
`rvRegistryDeployedAt` / `rvPermissionsDeployedAt` /
`rvTreasuryDeployedAt` from per-scope refs.

The mapping table for that projection lives in the rebase PR,
not here, because `RegistryView` does not exist on `main` yet.
