# Issue #367 Plan

## Scope

Implement a small `Store.PendingTx` PureScript module backed by
IndexedDB FFI. The module exposes typed records and CRUD helpers, but
does not inspect or transform transaction CBOR, witness hex, or signer
hashes.

## Data Shape

`PendingTxEntry` contains:

- `txid :: String`
- `intent :: Json`
- `unsignedTxHex :: String`
- `scope :: String`
- `requiredSigners :: Array String`
- `invalidHereafter :: Maybe String`
- `witnesses :: Object String`
- `savedAt :: String`
- `supersedes :: Maybe String`

## Implementation

- Add `frontend/src/Store/PendingTx.purs` and matching FFI.
- Add PureScript tests for CRUD, witness add/remove, and supersede
  linking.
- Add a Playwright CLI harness that writes an entry, reloads the page,
  and reads it back from IndexedDB.
- Keep the PR gate frontend-only: no Haskell build, unit, golden,
  schema, smoke, or release checks.

## Verification

- `./gate.sh` from the worktree root.
- Final gate must include `spago build`, `spago test`, the esbuild +
  `spago bundle` path, and the persistence-across-reload harness.

