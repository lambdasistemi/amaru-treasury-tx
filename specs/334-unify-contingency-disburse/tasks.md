# Tasks — #334

## Slice A — CLI unify
- [X] T334-SA1 RED: parser/wizard tests for `disburse-wizard --scope
      contingency --to <scope>:<ada>` + rejection of beneficiary-addr/no-`--to`.
- [X] T334-SA2 GREEN: fold contingency into disburse-wizard; remove the
      separate subcommand; same intent.json; non-contingency unchanged.
- [X] T334-SA3 `just ci` green; intent.json parity check vs old command.

## Slice B — UI unify
- [X] T334-SB1 Remove ModeContingencyDisburse; 3-mode selector; fold all
      case sites into ModeDisburse.
- [X] T334-SB2 Disburse form branches on scope (Contingency → dest rows +
      contingency endpoint; else address + disburse endpoint); scopePicker
      mode-aware (Swap/Reorganize exclude Contingency).
- [X] T334-SB3 `nix build .#frontend` green; browser smoke.
