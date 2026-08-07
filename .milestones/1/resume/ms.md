# Resume milestone 1 — WingRiders USDM treasury execution

You own milestone 1 in `lambdasistemi/amaru-treasury-tx`. Load `orchestrator-contract`, `milestone-orchestrator`, `context-compiler`, `worker-protocol`, `tmux-orchestrator`, and `invariants`. Read `.milestones/1/{ledger,registry,description,state,session}.md` in full, then verify the current on-chain pending-order count before any state claim.

Current stage: milestone founded from completed read-only research; no child issue or lane has been dispatched; no treasury transaction has been mutated.

Load-bearing finding: deployed WingRiders V2 reclaim requires one pubkey owner and allows that signer to redirect reclaimed value. Script/native multisig ownership is not supported. Upstream smart-contract modification is permanently forbidden scope. The milestone therefore uses a visible, bounded operational exception and may not claim equivalence to Amaru's two-of-four Sundae cancellation policy.

Next action: publish/verify the milestone ledger and public state, then ask an epic owner to bootstrap Epic A from the boundary research packet. Do not file the epic's issues or create its lane from the milestone desk.

Human decisions still required before a mainnet pilot: reclaim-key identity, pilot cap, and explicit submit authorization. The eight outputs of `57faba5b7d213649b118052e5ac4f48d9730f6d1a9f71af1b46d15d09b6c4519` remain live and must not be cancelled without a separate explicit go.
