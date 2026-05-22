# Parser Flag Contract — `reorganize-wizard`

This contract enumerates every flag the `reorganize-wizard`
subcommand parser exposes after S1 lands. It is the
authoritative reference for the slice executor and for
reviewers; any deviation from this matrix is a slice-level
defect.

## Subcommand surface

```text
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
state (devnet only; Slice 1 stubs the live path — runner body
lands in #187 / Slice C)
```

`progDesc` for the `command "reorganize-wizard"` entry in `cmdP`
of `lib/Amaru/Treasury/Cli.hs` MUST mirror this line. The
"Slice 1 stubs the live path" phrasing matches the sibling
`registry-init-wizard` / `stake-reward-init-wizard` /
`governance-withdrawal-init-wizard` Slice-1 phrasing (see
`Cli.hs` lines 192–214 for the existing template).

## Flag inventory

| Flag | Long | Short | Required | Metavar | Reader | Help text |
|---|---|---|---|---|---|---|
| Wallet address | `--wallet-addr` | — | yes | `BECH32` | `strOption` | "Wallet address (fuel + collateral)" |
| Metadata path | `--metadata` | — | yes | `PATH` | `strOption` | "Path to local journal/2026 metadata.json" |
| Output | `--out` | `-o` | yes | `PATH` | `strOption` | "Where to write the intent.json" |
| Log | `--log` | — | no | `PATH` | `strOption` (optional) | "Where to write step-by-step trace lines (defaults to stderr)" |
| Scope | `--scope` | — | yes | `NAME` | `eitherReader (scopeFromText . T.pack . map toLower)` | "core_development \| ops_and_use_cases \| network_compliance \| middleware" |
| Validity hours | `--validity-hours` | — | no | `HOURS` | `option auto` (optional) | "Optional. Omit to use the chain's current horizon (longest safe slot)." |
| Rationale description | `--description` | — | no | `TEXT` | `strOption` (optional) | "Rationale description override" |
| Rationale justification | `--justification` | — | no | `TEXT` | `strOption` (optional) | "Rationale justification override" |
| Rationale destination label | `--destination-label` | — | no | `TEXT` | `strOption` (optional) | "Rationale destination label override" |
| Rationale event | `--event` | — | no | `TEXT` | `strOption` (optional) | "Rationale event override" |
| Rationale label | `--label` | — | no | `TEXT` | `strOption` (optional) | "Rationale label override" |
| Force overwrite | `--force` | — | no | — | `flag False True` | "Overwrite the file at --out if it already exists" |
| Funding seed | `--funding-seed-txin` | — | yes | `TXID#IX` | `eitherReader (txInFromText . T.pack)` | "Funding seed TxIn — fuel + collateral for the reorganize tx" |

## Network flag (global, not subcommand)

`--network NAME` (where NAME ∈ `mainnet | preprod | preview |
devnet`) is owned by `Amaru.Treasury.Cli.Common.globalOptsP`,
NOT by `reorganizeWizardOptsP`. The wizard subcommand parser
does NOT redeclare it. The C2 verdict (see
[`../research.md` §5](../research.md#5-q-001-c1--c2-plan-time-discovery))
puts the devnet-only invariant in `runReorganizeWizard`'s
pre-flight check, BEFORE any chain query, file write, or
socket open. See
[`exit-code-contract.md`](./exit-code-contract.md) for the
exact pre-flight ordering.

## ReadM helpers (reuse, do NOT redefine)

- `eitherReader (txInFromText . T.pack)` — reuses
  `Amaru.Treasury.LedgerParse.txInFromText` (FR-006 hard
  requirement).
- `eitherReader (scopeFromText . T.pack . map toLower)` —
  reuses `Amaru.Treasury.Scope.scopeFromText` and the
  case-folding pattern from `Amaru.Treasury.Cli.RegistryInitWizard`'s
  `scopeReader`. The slice executor either copies `scopeReader`
  locally (matches sibling convention) or imports it
  (would expand owned-files scope; **default is copy**).
- `option auto` — for `Word16`; relies on `Read` instance.
- `strOption` — for `Text` / `FilePath`.
- `flag False True` — for boolean presence flags.

## Negative-test coverage matrix (parser tests)

The `ReorganizeWizardParserSpec` spec MUST cover at minimum
the following negative cases (all via
`Options.Applicative.execParserPure reorganizeWizardOptsP
<argv> [...]`):

| Test name | Input | Expected `Failure` substring |
|---|---|---|
| "rejects malformed --funding-seed-txin (no #)" | `..., "--funding-seed-txin", "abc..."` (no `#`) | "expected TXID#IX" (or whatever `txInFromText` emits) |
| "rejects malformed --funding-seed-txin (short hex)" | `..., "--funding-seed-txin", "00#0"` | `txInFromText` rejection |
| "rejects malformed --funding-seed-txin (non-hex)" | `..., "--funding-seed-txin", "zz...#0"` (64 z's) | `txInFromText` rejection |
| "rejects malformed --funding-seed-txin (out-of-range ix)" | `..., "--funding-seed-txin", "00...#65536"` | `txInFromText` rejection |
| "rejects missing --funding-seed-txin" | omitted | `Missing: --funding-seed-txin TXID#IX` |
| "rejects missing --registry"        | omitted (note: `--registry` is the issue's wording; this contract uses `--metadata` per B1's sibling-mirror) | `Missing: --metadata PATH` (see Q-002 note below) |
| "rejects missing --wallet-addr"     | omitted | `Missing: --wallet-addr BECH32` |
| "rejects missing --out"             | omitted | `Missing: (-o\|--out) PATH` |
| "rejects missing --scope"           | omitted | `Missing: --scope NAME` |

The substring assertions use `Data.List.isInfixOf` (or
`Data.Text` equivalent) against the `renderFailure` result;
they do NOT pin exact whitespace or rendering.

**Q-002 note on `--registry` vs `--metadata`**:

The issue #186 ACs use the flag name `--registry`. Every
sibling wizard uses `--metadata`. The B1 verdict
("sibling-mirrored shared flags") implies `--metadata`.
The S1 brief picks one of:

- **Option α (default, sibling-mirror)**: ship `--metadata`,
  amend `spec.md`'s wording (the issue's `--registry` is a
  misnomer for what every sibling wizard already calls
  `--metadata`). The parser tests assert
  `Missing: --metadata`.
- **Option β (issue-literal)**: ship `--registry` as a new
  flag name distinct from siblings. This diverges from
  every wizard scaffold; reviewers would have to learn a new
  flag-name convention per wizard.

**Default**: option α. The spec's wording amendment lives
alongside the C2 amendment in S3's `docs(spec):` commit.
This is non-blocking and surfaces in Q-002-plan-ready for
the epic owner's read receipt.

If the epic owner picks β at Q-002, S1's brief is updated
before dispatch.

## Positive-test coverage matrix (parser tests)

| Test name | Input | Expected `Success` |
|---|---|---|
| "accepts a fully-valid argv with all required flags" | full argv | `Right ReorganizeWizardOpts{...}` with every field populated |
| "accepts a fully-valid argv with rationale overrides" | full argv + 5 rationale flags | same with `cfDescription = Just _` etc. |
| "accepts `--funding-seed-txin <txid64hex>#0`"  | min ix | `rwoFundingSeedTxIn` parses correctly |
| "accepts `--funding-seed-txin <txid64hex>#65535`" | max ix | parses correctly |

The positive tests share a fixture argv (a `[String]` literal
or builder helper) to keep the test concise.

## Cli.hs dispatcher arm (S2)

```haskell
data Cmd
    = ...existing constructors...
    | CmdReorganizeWizard ReorganizeWizardOpts
    | ...

cmdP :: Parser Cmd
cmdP =
    hsubparser
        ( ...existing entries...
            <> command
                "reorganize-wizard"
                ( info
                    (CmdReorganizeWizard <$> reorganizeWizardOptsP)
                    ( progDesc
                        "Produce a reorganize intent.json from registry and treasury UTxO state (devnet only; Slice 1 stubs the live path)"
                    )
                )
            <> ...existing entries...
        )
```

Alphabetical placement: between `registry-init-wizard` (line
192) and `report-render` (line 200ish) — actually in the
existing `cmdP` block, the order is not strictly alphabetical
(it groups by feature family). The S2 executor places the
new entry adjacent to the other wizard families
(after `governance-withdrawal-init-wizard`, before `tx-build`).

## Main.hs runner arm (S2)

```haskell
case c of
    ...existing arms...
    CmdReorganizeWizard rwo ->
        runReorganizeWizard g rwo
    ...
```

Reorganize does NOT use `withSocket g` because the stub runner
never opens a socket (the network pre-flight rejects non-devnet
before socket open). #187's slice will widen this to
`withSocket g $ \socket -> runReorganizeWizard g{goSocketPath =
Just socket} rwo` once the runner body queries chain.
