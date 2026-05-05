# Phase 1 Data Model: On-chain anchor verification

**Plan**: [plan.md](./plan.md) · **Spec**: [spec.md](./spec.md)
**Date**: 2026-05-05

## 1. Build-time constants

```haskell
module Amaru.Treasury.Registry.Constants where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Word (Word64)

-- | TxIn that bootstraps the scopes validator. From upstream
-- aiken.toml @ <pinned-commit>.
scopesSeedTxIdHex :: Text
scopesSeedTxIdHex = "2d8871c264e32bef3ad728738beba5a8b4c78edccaf51e8c3ab693ff697f21fc"

scopesSeedIx :: Word64
scopesSeedIx = 0

-- | TxIn that bootstraps the per-scope registry validator.
registrySeedTxIdHex :: Text
registrySeedTxIdHex = "80ac843c71d5c4933877ab671bf377b34bc90abfc4df8287a3e92af806152c48"

registrySeedIx :: Word64
registrySeedIx = 0

-- | Asset names baked into upstream contracts.
scopesTokenName :: ByteString
scopesTokenName = "amaru 2026 scopes"

registryTokenName :: ByteString
registryTokenName = "REGISTRY"

-- | TreasuryConfiguration parameters baked into upstream.
treasuryExpirationMs :: Integer
treasuryExpirationMs = 1798757999000

payoutUpperbound :: Integer
payoutUpperbound = 0

-- | Compiled Plutus blobs from upstream plutus.json. One per
-- validator we need to parameter-apply.
scopesValidatorBlob :: ByteString
scopesValidatorBlob = $(embedFile ".../scopes.cbor")

treasuryRegistryValidatorBlob :: ByteString
treasuryRegistryValidatorBlob =
    $(embedFile ".../treasury_registry.cbor")

permissionsValidatorBlob :: ByteString
permissionsValidatorBlob =
    $(embedFile ".../permissions.cbor")

treasuryValidatorBlob :: ByteString
treasuryValidatorBlob = $(embedFile ".../treasury.cbor")
```

The blobs are extracted from upstream's
[`plutus.json`](https://github.com/pragma-org/amaru-treasury/blob/main/plutus.json)
at the pinned commit. Nix-based builds use a fixed-output
derivation that resolves to the same content; non-Nix builds
use Template Haskell `embedFile` over the same files committed
under `assets/`.

## 2. Untrusted metadata

```haskell
module Amaru.Treasury.Registry.Metadata where

data UpstreamMetadata = UpstreamMetadata
    { umScopeOwners :: !TxInRef
    , umTreasuries :: !(Map ScopeId TreasuryEntry)
    }
    deriving (Eq, Show)

data TreasuryEntry = TreasuryEntry
    { teOwner :: !(Maybe Text)        -- 28-byte hex
    , teAddress :: !Text              -- bech32
    , teTreasuryScript :: !ScriptDeployment
    , tePermissionsScript :: !ScriptDeployment
    , teRegistryScript :: !ScriptDeployment
    }
    deriving (Eq, Show)

data ScriptDeployment = ScriptDeployment
    { sdHash :: !Text                 -- 28-byte hex
    , sdDeployedAt :: !TxInRef
    }
    deriving (Eq, Show)

newtype TxInRef = TxInRef Text
    deriving (Eq, Ord, Show)
```

## 3. Verified projection

```haskell
module Amaru.Treasury.Registry.Verified where

data VerifiedRegistry = VerifiedRegistry
    { vrScopesNftUtxo :: !TxIn
    , vrScopesNftPolicy :: !ScriptHash
    , vrOwners :: !(Map ScopeId KeyHash)
    , vrTreasuriesByScope :: !(Map ScopeId VerifiedScope)
    }
    deriving (Eq, Show)

data VerifiedScope = VerifiedScope
    { vsAddress :: !Addr
    , vsTreasuryScriptHash :: !ScriptHash
    , vsRegistryScriptHash :: !ScriptHash
    , vsPermissionsScriptHash :: !ScriptHash
    , vsRegistryNftUtxo :: !TxIn
    , vsTreasuryDeployedAt :: !TxIn
    , vsPermissionsDeployedAt :: !TxIn
    , vsRegistryDeployedAt :: !TxIn
    }
    deriving (Eq, Show)
```

`VerifiedRegistry` is the only thing downstream consumes
(`projectToWizardRegistryView` for PR #28). Construction is
private to the verifier — there is no exported `Constructor` or
`mkVerifiedRegistry`.

## 4. Errors

```haskell
data RegistryWalkError
    = MetadataFetchHttp !Int !Text
    | MetadataFetchTimeout !Text
    | MetadataFetchTransport !Text
    | MetadataParse !String
    | MetadataSourceConflict
    -- ^ both --metadata-url and --metadata-file passed

    -- | The metadata's claim does not match the on-chain
    -- anchor or the locally-derived value. Field is one of:
    -- "owner", "treasury_script.hash", "registry_script.hash",
    -- "permissions_script.hash", "address",
    -- "treasury_script.deployed_at",
    -- "permissions_script.deployed_at",
    -- "registry_script.deployed_at",
    -- "scope_owners".
    | AnchorMismatch !Text !(Maybe ScopeId) !Text !Text
    -- ^ field, scope, expected, got

    -- | A required UTxO is no longer unspent.
    | AnchorSpent !Text !(Maybe ScopeId) !TxInRef

    -- | Multiple UTxOs match an NFT criterion (token policy +
    -- name). The trap validators forbid this; if it happens
    -- the wizard refuses to run.
    | AnchorAmbiguous !Text !(Maybe ScopeId) ![TxIn]

    | ChainQueryError !Text
    deriving (Eq, Show)
```

## 5. Verifier entry point

```haskell
verifyRegistry
    :: Provider IO
    -> MetadataFetcher IO
    -> MetadataSource          -- default URL | --url ... | --file ...
    -> Set ScopeId             -- which scopes to verify
    -> IO (Either RegistryWalkError VerifiedRegistry)
```

Behaviour, in order:

1. Resolve metadata bytes from `MetadataSource`. Fetch errors
   ⇒ `MetadataFetchHttp/Timeout/Transport`.
2. Parse to `UpstreamMetadata`. Parse errors ⇒
   `MetadataParse`.
3. Recompute Scopes NFT policy id from
   `scopes(scopesSeed)` blob. Compute its script address.
4. For each requested scope, recompute the per-scope registry
   NFT policy id and script address.
5. Issue **LSQ round-trip 1**: `queryUTxOsAt {scopes_addr,
   each_registry_addr}`. Filter for the unique NFT-bearing
   UTxO at each address. Multi-match ⇒ `AnchorAmbiguous`.
   Empty ⇒ `AnchorSpent`.
6. Parse the Scopes NFT inline datum → owner key hashes.
   Verify every metadata `owner` claim. Mismatch ⇒
   `AnchorMismatch "owner" scope`.
7. Parse each per-scope `ScriptHashRegistry` datum → treasury
   script credential. Verify metadata's
   `treasury_script.hash`. Mismatch ⇒ `AnchorMismatch`.
8. Recompute `permissions(scopes_nft_policy, scope)` hash.
   Verify metadata's `permissions_script.hash`.
9. Verify metadata's `registry_script.hash` against the
   recomputed registry policy id (already computed in step 4).
10. Recompute the bech32 address from
    `vsTreasuryScriptHash` for the configured network. Verify
    metadata's `address`.
11. Issue **LSQ round-trip 2**:
    `queryUTxOByTxIn {scope_owners, each per-scope deployed-at}`.
    Empty result for any TxIn ⇒
    `AnchorSpent`. For every returned UTxO, verify its reference
    script hash equals the verified script hash for that field.
    Mismatch ⇒ `AnchorMismatch "*.deployed_at" scope`.
12. Build `VerifiedRegistry`. Return `Right`.

Total: pure validation surrounded by exactly two LSQ
round-trips against the node. Cross-call atomicity is a v2
upstream enhancement
([cardano-node-clients#126](https://github.com/lambdasistemi/cardano-node-clients/issues/126)).

## 6. MetadataSource and MetadataFetcher

```haskell
data MetadataSource
    = MetadataSourceDefaultUrl
    | MetadataSourceUrl !Text
    | MetadataSourceFile !FilePath

newtype MetadataFetcher m = MetadataFetcher
    { runFetcher
        :: MetadataSource
        -> m (Either RegistryWalkError ByteString)
    }

defaultMetadataUrl :: Text
defaultMetadataUrl =
    "https://raw.githubusercontent.com/pragma-org/amaru-treasury/main/journal/2026/metadata.json"
```

`MetadataSource` is constructed once from the CLI flags;
mutual exclusion between `--metadata-url` and `--metadata-file`
is checked at parse time and produces
`MetadataSourceConflict`.

## 7. Provider IO addition

```haskell
-- to be added to cardano-node-clients/Provider.hs:
queryUTxOsAt
    :: Provider m
    -> Set Addr
    -> m (Map Addr [(TxIn, TxOut ConwayEra)])
```

A small change upstream. If it's blocked on review, this
branch can ship with a sequential fallback (one
`queryUTxOs` per address) and migrate to the batched form in a
patch release. Adding to the FR-011 round-trip count is the
only consequence; safety is unchanged.
