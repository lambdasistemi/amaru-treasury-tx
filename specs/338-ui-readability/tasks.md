# Tasks — #338
## Slice A — P1 readability
- [X] T338-SA1 Format.purs (formatThousands/showAda/showUsdm/shortAddr) + dedup App/Books copies.
- [X] T338-SA2 OperatePage JsonView value-formatter: lovelace→ADA + hash truncation in intent/report trees.
- [X] T338-SA3 Amount inputs: thousands separators (on-blur) + lovelace-equivalent hint.
- [X] T338-SA4 Label contrast → on-surface; scope-card__slug font-size. nix build .#frontend + browser smoke.
## Slice B — P2 consistency & mobile
- [ ] T338-SB1 Audit: slot separators, fee unit, txid/address truncate+copy, responsive table.
- [ ] T338-SB2 View: integer relative time; JSON-tree hash truncation.
- [ ] T338-SB3 CSS mobile: stat-grid 2-col ≤390px; scope-picker pills ≤600px.
- [ ] T338-SB4 Discoverability: contingency-scope hint; Books import title + success summary. nix build + browser smoke.
- [ ] T338-SB5 Contingency signers UI: when scope == Contingency the signers section is INFORMATIONAL — show all four owned scope owners (core_development, ops_and_use_cases, network_compliance, middleware) as REQUIRED, NOT a selectable extra-signers picker (selecting fewer is meaningless; the tx always requires all four). Replace the picker with a read-only "all four scope owners must sign" list for this case.
