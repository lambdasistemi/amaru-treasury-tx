# plan — #522

One bisect-safe slice: wire carriers and provider wrapper
(`Amaru.Treasury.Backend.Indexer`), the `POST /v1/utxos` route,
config/flag plumbing into `GlobalOpts`, the `withCliBackend` bracket
replacing the CLI's `withLocalNodeBackend` call sites, unit specs,
operator docs.

Constraints: fourmolu 70 columns, `GHC2021`, `-Werror`, hlint clean.

Gate: `nix develop --quiet -c just ci`.
