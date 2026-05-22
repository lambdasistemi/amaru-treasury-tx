# Input parent CBORs

Acceptance criteria for #202 calls for `<parent-txid>.cbor` files for
every spent input — the full Conway tx body of each parent tx, so an
auditor can verify input UTxO values at submit time without
querying a node.

The three parent txs for this disburse are:

- `3c3d5332cb159a5f0b42cf48a6f897f1603f94fb4405c6f0c1146d5feb627963` (treasury input #1)
- `77b1b046d1bfb1a09011d4606817ea45d13d8d9e0d02258984d0c6126e4cc9e9` (treasury input #2)
- `44454ed0def64621ef645958830f599b488b699b28e3797cc37c4f4dd1463a79` (wallet fuel + collateral)

These need to be fetched via a chain indexer (Blockfrost / Kupo /
Ogmios / dbsync) since `cardano-cli`'s ledger-state queries don't
return historical tx bodies. Tracked as a post-submit operator
follow-up; not blocking S5.
