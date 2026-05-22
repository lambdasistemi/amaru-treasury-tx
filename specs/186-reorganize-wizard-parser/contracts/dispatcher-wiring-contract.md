# Dispatcher Wiring Contract — `reorganize-wizard`

Defines the exact `Cli.hs` + `Main.hs` edits S2 must produce.
Any drift from this contract is a slice-level defect and is
caught by the `ReorganizeWizardDispatchSpec`.

## `lib/Amaru/Treasury/Cli.hs`

### Import block

Add (alphabetical position after the existing
`RegistryInitWizard` import):

```haskell
import Amaru.Treasury.Cli.ReorganizeWizard
    ( ReorganizeWizardOpts
    , reorganizeWizardOptsP
    )
```

### `Cmd` sum

Add `CmdReorganizeWizard ReorganizeWizardOpts` (positional
placement: alphabetical / family-grouped — between
`CmdGovernanceWithdrawalInitWizard` and `CmdTxBuild`):

```haskell
data Cmd
    = ...
    | CmdRegistryInitWizard RegistryInitWizardOpts
    | CmdStakeRewardInitWizard StakeRewardInitWizardOpts
    | CmdGovernanceWithdrawalInitWizard GovernanceWithdrawalInitWizardOpts
    | CmdReorganizeWizard ReorganizeWizardOpts                                          -- NEW
    | CmdTxBuild TxBuildOpts
    | ...
```

### `cmdP` parser

Add the matching `command "reorganize-wizard"` entry (positional
placement adjacent to other wizards, after
`governance-withdrawal-init-wizard`):

```haskell
cmdP =
    hsubparser
        ( ...
            <> command
                "governance-withdrawal-init-wizard"
                ( info ... )
            <> command
                "reorganize-wizard"
                ( info
                    (CmdReorganizeWizard <$> reorganizeWizardOptsP)
                    ( progDesc
                        "Produce a reorganize intent.json from registry and treasury UTxO state (devnet only; Slice 1 stubs the live path)"
                    )
                )
            <> ...
        )
```

The `progDesc` is the single line agreed in
[`parser-flag-contract.md`](./parser-flag-contract.md).

## `app/amaru-treasury-tx/Main.hs`

### Import block

Add (alphabetical position):

```haskell
import Amaru.Treasury.Cli.ReorganizeWizard
    ( runReorganizeWizard
    )
```

### Runner case

Add the `CmdReorganizeWizard` arm. Reorganize does NOT use
`withSocket g` because the stub runner never opens a socket
(the network pre-flight rejects non-devnet before socket open):

```haskell
case c of
    ...
    CmdGovernanceWithdrawalInitWizard gwo ->
        runGovernanceWithdrawalInitWizard g gwo
    CmdReorganizeWizard rwo ->                          -- NEW
        runReorganizeWizard g rwo                       -- NEW
    CmdTxBuild to ->
        ...
```

#187 will widen this arm to `withSocket g $ \socket ->
runReorganizeWizard g{goSocketPath = Just socket} rwo` once the
runner body queries chain. The S2 commit does NOT need to predict
that change.

## Dispatch test

`test/unit/Amaru/Treasury/Cli/ReorganizeWizardDispatchSpec.hs`
asserts:

1. **`reorganize-wizard` is a recognized subcommand**: invoking
   `Options.Applicative.execParserPure opts ["reorganize-wizard",
   "--help"]` produces a `Failure ParserFailure` whose rendered
   output includes the `reorganize-wizard` help text (the
   `progDesc` plus the flag list). `--help` always produces
   `Failure` in `execParserPure` even when it succeeds — the
   `ParserResult` carries the help text in its `Failure` payload.
2. **the flag set is reachable from the top-level parser**:
   invoking `execParserPure opts ["reorganize-wizard"]` with
   no flags produces a `Failure` whose rendered output includes
   "Missing: --wallet-addr" (or any other required flag — the
   substring assertion picks one stable representative). This
   proves the wizard parser is wired in (otherwise the failure
   would be "Unknown command 'reorganize-wizard'").

The spec MUST NOT spawn subprocesses. The `opts` value imported
from `Amaru.Treasury.Cli` is what the binary's
`Main.execParser` consumes; testing it directly is equivalent
to testing the binary at the CLI surface.

## Required imports for the dispatch spec

```haskell
import Test.Hspec (Spec, describe, it, shouldSatisfy)
import Options.Applicative
    ( ParserResult (..)
    , execParserPure
    , defaultPrefs
    , renderFailure
    )
import Data.List (isInfixOf)
import Amaru.Treasury.Cli (opts)
```

The dispatch spec lives in `test/unit/Amaru/Treasury/Cli/`, NOT
`test/unit/Amaru/Treasury/Tx/`. The directory split mirrors the
module split (parser concerns vs runner concerns).

## Sibling reference

Sibling wizards (`registry-init-wizard`, `stake-reward-init-wizard`,
`governance-withdrawal-init-wizard`) do NOT have their own
dispatch specs — they rely on parser specs for the wizard's own
flag set and on the build pass to catch missing dispatcher
arms. This slice introduces a dispatch spec because:

1. The S2 RED → GREEN proof needs a test that fails before
   the wiring exists.
2. A focused dispatch spec is the cheapest way to assert "the
   binary's `--help` includes `reorganize-wizard`" without
   spawning a subprocess.

Future wizard slices may adopt the same pattern; this slice
introduces it as a one-off because it improves the bisect-safety
of S2's RED→GREEN proof.
