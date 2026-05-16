# Next slice analysis: T021-T027

The accepted T013-T020 extraction moved reusable registry construction
into `Amaru.Treasury.Devnet.RegistryInit`, but its result type preserves
only final anchors. The registry-init artifact contract requires three
submitted transaction ids:

- seed split
- registry NFT mint
- reference-script publication

The seed-split tx id cannot be recovered from the final anchors because
the seed outputs are consumed by the registry mint transaction. The next
implementation brief therefore requires a richer production result that
records all three tx ids plus final anchors.

Handoff constraints:

- Production module renders registry-init artifact values.
- `SmokeSpec.hs` dispatches the phase, invokes the production entry
  point, verifies observed UTxOs through the provider, and writes the
  rendered values.
- Existing `prepareDevnetWithdrawalRegistry` remains available for the
  withdrawal path by projecting the richer result.
- No docs, README, spec, plan, tasks, PR metadata, or issue metadata
  edits in the subagent slice.
