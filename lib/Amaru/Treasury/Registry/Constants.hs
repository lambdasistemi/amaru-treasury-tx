{-# LANGUAGE TemplateHaskell #-}

{- |
Module      : Amaru.Treasury.Registry.Constants
Description : Build-time registry verification trust roots
Copyright   : (c) Paolo Veronelli, 2026
License     : Apache-2.0

Constants copied from the pinned upstream Amaru treasury deployment.
The metadata resolver treats `metadata.json` as an untrusted hint; these
values and the on-chain anchors are the trust roots.
-}
module Amaru.Treasury.Registry.Constants
    ( -- * Upstream pin
      upstreamAmaruTreasuryCommit
    , upstreamTreasuryContractsCommit

      -- * Seed output references
    , scopesSeedTxIdHex
    , scopesSeedIx
    , registrySeedTxIdHex
    , registrySeedIx

      -- * Token names
    , scopesTokenName
    , registryTokenName

      -- * Treasury configuration
    , treasuryExpirationMs
    , payoutUpperbound

      -- * Compiled validators
    , scopesValidatorBlob
    , treasuryRegistryValidatorBlob
    , permissionsValidatorBlob
    , treasuryValidatorBlob
    ) where

import Data.ByteString (ByteString)
import Data.FileEmbed (embedFile)
import Data.Text (Text)
import Data.Word (Word64)

{- | Upstream Amaru treasury commit that supplies `aiken.toml`,
`plutus.json`, and the checked-in metadata fixture.
-}
upstreamAmaruTreasuryCommit :: Text
upstreamAmaruTreasuryCommit =
    "99600d8cedf0e3c4894fe7f45d5e8abad2289d76"

-- | Upstream SundaeSwap treasury contracts commit used by Amaru.
upstreamTreasuryContractsCommit :: Text
upstreamTreasuryContractsCommit =
    "8a3183c929be57886214624b45ee0c43a0c19277"

-- | TxId that parameterises the Scopes NFT validator.
scopesSeedTxIdHex :: Text
scopesSeedTxIdHex =
    "2d8871c264e32bef3ad728738beba5a8b4c78edccaf51e8c3ab693ff697f21fc"

-- | Output index that parameterises the Scopes NFT validator.
scopesSeedIx :: Word64
scopesSeedIx = 0

-- | TxId that parameterises each per-scope registry validator.
registrySeedTxIdHex :: Text
registrySeedTxIdHex =
    "80ac843c71d5c4933877ab671bf377b34bc90abfc4df8287a3e92af806152c48"

-- | Output index that parameterises each per-scope registry validator.
registrySeedIx :: Word64
registrySeedIx = 0

-- | Asset name baked into the Scopes NFT validator.
scopesTokenName :: ByteString
scopesTokenName = "amaru 2026 scopes"

-- | Asset name baked into the per-scope registry validators.
registryTokenName :: ByteString
registryTokenName = "REGISTRY"

-- | Treasury expiration, in POSIX milliseconds.
treasuryExpirationMs :: Integer
treasuryExpirationMs = 1798757999000

-- | Upstream `TreasuryConfiguration.payout_upperbound`.
payoutUpperbound :: Integer
payoutUpperbound = 0

-- | Compiled `scopes` validator bytes from upstream `plutus.json`.
scopesValidatorBlob :: ByteString
scopesValidatorBlob = $(embedFile "assets/plutus/scopes.cbor")

-- | Compiled `treasury_registry` validator bytes from upstream `plutus.json`.
treasuryRegistryValidatorBlob :: ByteString
treasuryRegistryValidatorBlob =
    $(embedFile "assets/plutus/treasury_registry.cbor")

-- | Compiled `permissions` validator bytes from upstream `plutus.json`.
permissionsValidatorBlob :: ByteString
permissionsValidatorBlob = $(embedFile "assets/plutus/permissions.cbor")

-- | Compiled SundaeSwap treasury validator bytes from upstream `plutus.json`.
treasuryValidatorBlob :: ByteString
treasuryValidatorBlob = $(embedFile "assets/plutus/treasury.cbor")
