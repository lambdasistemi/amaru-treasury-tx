# Plan — UI/UX readability + consistency (#338)

Spec = issue #338 AC (P1 + P2). Pure frontend (PureScript/Halogen + CSS).
No backend/API/CLI/on-chain change. No frontend unit harness → proof is
`nix build .#frontend` + browser smoke.

## Slice A — P1 readability core
1. New `frontend/src/Format.purs`: `formatThousands :: Int -> String`,
   `showAda :: Int -> String` (lovelace→ADA, separators, "ADA"),
   `showUsdm`, `shortAddr`/`shortHex` (head…tail + title). Move the
   existing App.purs copies here; replace App.purs + BooksPage
   `truncateMid` usages to import from Format.
2. OperatePage result panels: pass a value-formatter to the `JsonView`
   trees (intent.json ~2190, report ~2236) so keys matching
   `*lovelace`/`amount` render as `1,556,478.04 ADA` and
   `address`/`txId`/hash values truncate + carry a title/copy.
3. Amount inputs (USDM target 647, min-rate 673, disburse amount 730,
   contingency ADA 945) — on-blur thousands-separator formatting + a
   lovelace-equivalent hint under the field.
4. Contrast: `scope-pill__slug`, `field__label`, `stat-tile__label`,
   `copy-row__label` → `on-surface`; `scope-card__slug` explicit
   font-size (12px). (styles.css / style-build.css.)
- Proof: `nix build .#frontend`; browser smoke shows formatted amounts.

## Slice B — P2 consistency & mobile
1. AuditPage: slot numbers via `formatThousands` (380/423/452); fee with
   "lovelace" unit (458); txid/address truncate+copy; responsive table
   ≤390px (drop the 680px min-width scroll-strip).
2. App (View): integer relative-time (1062–1064); JSON-tree hashes
   truncated.
3. CSS mobile: stat-grid → 2 cols ≤390px; scope-picker pills tighten
   ≤600px.
4. Discoverability: hint near the scope picker that choosing Contingency
   turns Disburse into multi-scope destination rows; Books import button
   title + post-import success summary (counts).
- Proof: `nix build .#frontend`; browser smoke on /, /audit, /operate,
  /books (incl. ≤390px viewport).
