# Contract — CLI Surface

The `treasury-inspect` subcommand of `amaru-treasury-tx`.

## Synopsis

```
amaru-treasury-tx --node-socket PATH --network NAME \
  treasury-inspect
    --metadata PATH                       # required
    [--scope NAME]                        # optional filter
    [--format human|json]                 # default: human on TTY, json on pipe
    [--out PATH]                          # optional file destination for JSON
```

## Flag reference

| Flag                 | Default                                     | Meaning |
|----------------------|---------------------------------------------|---------|
| `--metadata PATH`    | *required*                                  | Path to the metadata.json the wizards already consume. |
| `--scope NAME`       | *all scopes in metadata, in stable order*  | Restrict report to a single scope. Names: `core_development`, `ops_and_use_cases`, `network_compliance`, `middleware`, `contingency`. |
| `--format FORMAT`    | `human` on TTY, `json` otherwise            | Force the output format. `FORMAT` is `human` or `json`. |
| `--out PATH`         | *not set*                                   | Write the JSON document to PATH. The human view still renders on stdout when `--format human`. When `--format json` and `--out` is set, stdout is silent. |

`--node-socket` and `--network` are inherited from the top-level
`amaru-treasury-tx` parser; no change needed.

## Exit codes

| Code | Meaning                                                          |
|:----:|------------------------------------------------------------------|
| 0    | Success — report rendered.                                       |
| 2    | Bad invocation: unknown scope, missing required flag, malformed metadata. Diagnosis goes to stderr. |
| 3    | Node-side problem: socket unreachable, network-magic mismatch.   |

## Stdout / stderr / file behaviour matrix

| Format requested | `--out` set? | stdout                | stderr                          | file at `--out` |
|------------------|:------------:|-----------------------|---------------------------------|-----------------|
| human            | no           | human-rendered report | (errors only)                   | —               |
| human            | yes          | human-rendered report | (errors only)                   | JSON document   |
| json             | no           | JSON document         | (errors only)                   | —               |
| json             | yes          | (silent)              | (errors only)                   | JSON document   |

## Argument validation order

1. **Parse** the command-line. Reject unknown flags / unknown `--format` values with optparse-applicative's standard error → exit 2.
2. **Load `--metadata`**. Missing file or JSON decode failure → "metadata: <one-line message>" to stderr → exit 2.
3. **Validate `--scope`** if set: must be a key in `tmTreasuries`. Otherwise: `scope: <name> not in metadata; available: …` → exit 2.
4. **Connect to the node**. Failure → "node: <message>" → exit 3.
5. **Confirm network magic** matches `--network` and the metadata. Mismatch → "network: metadata expects N, connected node reports M" → exit 3.
6. **Query, build report, render**. Always exit 0 on success.

Steps 1–3 happen before any I/O against the node. Step 5 is best-effort
(some N2C providers report magic only after handshake; the check happens
as soon as the value is available).

## Human format (sketch)

Section per scope; one-line summary at top. Empty pending lists render
as `(no pending orders)`. Lengths/values are placeholders.

```
Chain tip:        slot 142_300_412  block <hash16>…
Deployment NFT:   policy <policy28>…

[network_compliance] addr1q…7xv
  Treasury UTxOs (2):
    <txid12>…#0    1 234.567890 ADA   3 200.000 USDM
    <txid12>…#2  120 000.000000 ADA       0.000 USDM     ←  rest from b5716ae9…
  Totals: 121 234.567890 ADA  3 200.000 USDM  (no other assets)
  Pending SundaeSwap orders (2):
    <txid12>…#3   60 000.000000 ADA   ≥ 1 600.000 USDM  fee 0.350 ADA
    <txid12>…#4   60 000.000000 ADA   ≥ 1 600.000 USDM  fee 0.350 ADA

[contingency] addr1q…2pa
  Treasury UTxOs (0):  (no UTxOs)
  Totals: 0.000000 ADA  0.000 USDM  (no other assets)
  Pending SundaeSwap orders: (no pending orders)
```

## JSON format

See [treasury-inspect-schema.json](treasury-inspect-schema.json) for the
contract and [example-report.json](example-report.json) for a worked
example.
