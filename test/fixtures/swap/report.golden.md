# swap on network_compliance

- Transaction id: f285cbd2e3e0e90b0593a5ffda82bcadef3f598ec26f66dc40c74e7aca7954b7
- Transaction type: swap
- Scope: network_compliance
- Explorer: https://cardanoscan.io/transaction/f285cbd2e3e0e90b0593a5ffda82bcadef3f598ec26f66dc40c74e7aca7954b7
- CBOR fingerprint: 84ac00d901028282...6b6532622d323536 (29974 hex chars)
- Validity: invalid before none; invalid hereafter slot 186796799 (2026-05-09T21:44:50Z)
- Conservation: inputs 1500007239276 lovelace (1500007.239276 ADA) = outputs 1500006215897 lovelace (1500006.215897 ADA) + fee 1023379 lovelace (1.023379 ADA), residual 0 lovelace (0.000000 ADA)
- CIP-1694 rationale: Swap ADA<->USDM - Swapping ADA for $100k at a rate of $0.245 per ADA; Required to pay Antithesis as vendor; destination Network Compliance's treasury
- Auxiliary data: CIP-1694 label present; hash 1163dfe0f06e30a30353b706b988721fb0a6f5168db22402ef6a76b8e677868d

## Consumed Inputs
- operator wallet input 42e4c279...442da0#0: 50007239276 lovelace (50007.239276 ADA)
- network_compliance treasury input 64f27254...267cf0#0: 1450000000000 lovelace (1450000.000000 ADA)

## Produced Outputs
- 32 x swapOrder -> Sundae swap-order [network_compliance]: 12503280000 lovelace (12503.280000 ADA)
- 1 x swapOrder -> Sundae swap-order [network_compliance]: 8166545306 lovelace (8166.545306 ADA)
- 1 x treasuryLeftover -> network_compliance treasury: 1041728494694 lovelace (1041728.494694 ADA)
- 1 x walletChange -> operator wallet: 50006215897 lovelace (50006.215897 ADA)

## Reference Inputs
- scope owners registry (11ace24a...e4cf54#0)
- network_compliance permissions reference script (25ba96f5...861095#2)
- network_compliance treasury reference script (810bfcbd...330b3c#0)
- network_compliance registry reference (e7b395a9...e6311c#2)

## Required Signers
- network_compliance scope owner (selected scope owner)
- ops_and_use_cases scope owner (extra signer)
