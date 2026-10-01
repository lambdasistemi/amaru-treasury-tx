# spec — #514 Vault passphrase prompt echoes input typed before echo is disabled

## Problem

`readHiddenLine` (`lib/Amaru/Treasury/Cli/Passphrase.hs`) writes and
flushes the prompt to `/dev/tty`, and only then clears `EnableEcho`.
Input arriving in that window is echoed in clear by the terminal line
discipline. CI `smoke` (`scripts/smoke/vault-witness-tty`, which types
as soon as the prompt text appears) fails intermittently on `main`
with `interactive passphrase was echoed into the transcript` (runs
36909829528, 36910226263; same code passes on others).

## User story

US-1 — As an operator typing a vault passphrase at the interactive
prompt, nothing I type after the prompt is shown is ever displayed,
however quickly I type.

## Requirements

- REQ-1 — Every hidden `/dev/tty` read (`New vault passphrase: `,
  `Confirm vault passphrase: `, and the single-prompt read used by
  `readVaultPassphrase` without an fd) clears echo before the first
  prompt byte is written.
- REQ-2 — The original terminal attributes are restored on every exit
  path: normal return, EOF / read error, and an exception raised while
  writing the prompt or reading the line.
- REQ-3 — Observable behaviour is otherwise unchanged: prompt texts,
  the newline written after the hidden line, the returned bytes, error
  messages, and the `--vault-passphrase-fd` path.
- REQ-4 — `scripts/smoke/vault-witness-tty` is not modified and passes.

## Invariants

| ID | Holds when | Fails when |
|---|---|---|
| INV-1 | at the moment any prompt byte becomes observable on the terminal, echo is already off | echo is still on when the prompt is observable (current `main`) |
| INV-2 | bytes written to the terminal after the prompt is observable are never echoed back, and are returned as the read line | any such byte is echoed |
| INV-3 | the check proving INV-1/INV-2 executes the real hidden read under a pseudo-terminal and fails on `main` under every scheduling interleaving — its failure does not depend on timing luck — and passes on the fix | the check passes on `main` in some run, or is skipped/vacuous, or does not drive the real read |
| INV-4 | after the read returns or throws (including an exception during the prompt write or the line read), the terminal attributes equal those before the call | any exit path leaves echo off or attributes changed |
| INV-5 | prompt texts, trailing newline, returned bytes, error texts and the fd path are byte-identical to `main`; goldens unchanged | any of these differ |
| INV-6 | `scripts/smoke/vault-witness-tty` is byte-identical to base and the CI `smoke` job passes on the pushed head | the script is edited or smoke is red |

## Non-goals

- `--signing-key-paste` (`Amaru.Treasury.Cli.Vault.readPastedSigningKey`)
  reads through haskeline `getPassword`, not `readHiddenLine`; it does
  not share the path and is out of scope.
- Any change to `scripts/smoke/*`, the CLI surface, or vault formats.
