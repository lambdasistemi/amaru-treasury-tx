# Quickstart — `reorganize-wizard` (parser scaffold)

This is the operator's-eye view of what the slice produces.
After this PR merges:

## What works

```bash
# 1. Discover the flag set.
$ amaru-treasury-tx reorganize-wizard --help
Usage: amaru-treasury-tx reorganize-wizard
         --wallet-addr BECH32
         --metadata PATH
         (-o|--out PATH)
         [--log PATH]
         --scope NAME
         [--validity-hours HOURS]
         [--description TEXT]
         [--justification TEXT]
         [--destination-label TEXT]
         [--event TEXT]
         [--label TEXT]
         [--force]
         --funding-seed-txin TXID#IX

Produce a reorganize intent.json from registry and treasury UTxO
state (devnet only; Slice 1 stubs the live path)

$ echo $?
0

# 2. Top-level help lists the subcommand.
$ amaru-treasury-tx --help | grep reorganize-wizard
    reorganize-wizard
                           Produce a reorganize intent.json from
                           registry and treasury UTxO state
                           (devnet only; Slice 1 stubs the live path)
```

## What fails (intentionally)

### Malformed `--funding-seed-txin`

```bash
$ amaru-treasury-tx reorganize-wizard \
    --network devnet \
    --metadata journal/2026/metadata.json \
    --wallet-addr addr_test1vq... \
    --funding-seed-txin not-a-txin \
    --scope core_development \
    --out /tmp/foo.json
option --funding-seed-txin: expected TXID#IX (a 64-hex-char TxId, '#', and a Word16 ix)

Usage: amaru-treasury-tx reorganize-wizard ...

$ echo $?
1
```

### Missing required flag

```bash
$ amaru-treasury-tx reorganize-wizard \
    --network devnet \
    --metadata journal/2026/metadata.json \
    --funding-seed-txin 00...#0 \
    --scope core_development \
    --out /tmp/foo.json
Missing: --wallet-addr BECH32

Usage: amaru-treasury-tx reorganize-wizard ...

$ echo $?
1
```

(Same shape for missing `--metadata`, `--funding-seed-txin`,
`--out`, `--scope`.)

### `--out` parent directory doesn't exist

```bash
$ amaru-treasury-tx --network devnet reorganize-wizard \
    --metadata journal/2026/metadata.json \
    --wallet-addr addr_test1vq... \
    --funding-seed-txin 00...#0 \
    --scope core_development \
    --out /tmp/does-not-exist-186/foo.json
ReorganizeOutputParentMissing "/tmp/does-not-exist-186"

$ echo $?
2
```

### Non-devnet network

```bash
$ amaru-treasury-tx --network preprod reorganize-wizard \
    --metadata journal/2026/metadata.json \
    --wallet-addr addr_test1vq... \
    --funding-seed-txin 00...#0 \
    --scope core_development \
    --out /tmp/foo.json
ReorganizeNonDevnetNetwork "preprod"

$ echo $?
2
```

### Valid flags + valid `--out` parent → stub runner fires

```bash
$ mkdir -p /tmp/reorganize-186-run
$ amaru-treasury-tx --network devnet reorganize-wizard \
    --metadata journal/2026/metadata.json \
    --wallet-addr addr_test1vq... \
    --funding-seed-txin <real-devnet-txid>#0 \
    --scope core_development \
    --out /tmp/reorganize-186-run/intent.json
ReorganizeTodoSliceC

$ echo $?
3

$ ls /tmp/reorganize-186-run/
# (empty — no file written; the stub runner exits before any work)
```

## What this slice does NOT yet do

- Open a node socket. (#187 will, when the runner body lands.)
- Verify the registry. (#187.)
- Query treasury UTxOs. (#187.)
- Sample a validity bound from the chain tip. (#187.)
- Encode a `SomeTreasuryIntent` JSON. (#187 — once the resolver
  populates the typed `Reorganize` shape from chain state, the
  encoder is already shipped by #185.)
- Write a file to `--out`. (#187.)
- Drive a DevNet smoke. (#87.)
- Update the README / docs / asciinema. (#188.)

## When can I actually use this?

After #187 merges, the `ReorganizeTodoSliceC` error is replaced
by the real runner; the same flag invocation produces an
`intent.json` at the named path. The subsequent
`amaru-treasury-tx tx-build --intent intent.json --out
tx.unsigned.cbor` step is already supported (the dispatcher arm
was wired by #185, which merged at `da9d65b5`).

After #87 merges, `just devnet-smoke reorganize` exercises the
whole path against a live local DevNet.

After #188 merges, an asciinema cast embedded in the docs page
demonstrates the full operator flow.

## Verification

```bash
# Build the binary (haskell.nix + IOG cache):
$ nix build .#default

# Run the unit suite, including the new parser/dispatch specs:
$ nix develop --quiet -c just unit

# Run the full CI gate the worktree uses for review:
$ ./gate.sh

# Once the PR is ready for review, gate.sh is removed in the
# final `chore: drop gate.sh` commit; reviewers run `nix develop
# -c just ci` to reproduce the same checks.
```
