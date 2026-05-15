# Pinned Plutus Assets

These CBOR files are copied from upstream validator blueprints and
embedded by `Amaru.Treasury.Registry.Constants`.

## Upstream Pins

- `pragma-org/amaru-treasury@99600d8cedf0e3c4894fe7f45d5e8abad2289d76`
  - `traps.scopes.spend` -> `scopes.cbor`
  - `traps.treasury_registry.spend` -> `treasury_registry.cbor`
  - `permissions.permissions.withdraw` -> `permissions.cbor`
- `SundaeSwap-finance/treasury-contracts@8a3183c929be57886214624b45ee0c43a0c19277`
  - `treasury.treasury.spend` -> `treasury.cbor`
- `SundaeSwap-finance/sundae-contracts@be33466b7dbe0f8e6c0e0f46ff23737897f45835`
  - `order.spend` -> `sundae_order.cbor`

## Refresh Procedure

1. Pick the upstream commit and inspect its `aiken.toml`,
   `plutus.json`, and metadata changes in review.
2. Replace these files from the matching blueprint `compiledCode`
   fields, decoded from hex to bytes.
3. Update the constants in
   `Amaru.Treasury.Registry.Constants` if the seeds, token names,
   expiration, or payout upper bound changed.
4. Regenerate the expected derived-hash fixture used by the registry
   tests and run `just ci`.
