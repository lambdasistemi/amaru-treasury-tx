# Session reconstruction

## Milestone desk

- tmux session: `treasury-ms1` (stable session ID `$1006`)
- window: `amaru-treasury-tx-ms1-wingriders-usdm` (stable window ID `@4008`)
- pane: `%5803`
- role: `orchestrator-contract` → `milestone-orchestrator` → `context-compiler` → `worker-protocol` → `tmux-orchestrator` → `invariants`
- cwd: `/home/paolino`
- runtime root: `/tmp/ms-amaru-treasury-1`
- launch: `codex-raw --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust`
- resume pointer: `.milestones/1/resume/ms.md`

## Epic A — read-only market and agent investigation

- window: `amaru-treasury-tx-e485-t492-cross-venue-survey` (stable window ID `@4015`)
- epic owner pane: `%5810`, Claude `claude-opus-5`, cwd `/code`
- ticket #492 owner pane: `%5842`, Codex `gpt-5.6-sol` high, cwd `/code/amaru-treasury-tx`
- commit-owner pane: `%5845`, Claude `claude-opus-5` high, cwd `/code/amaru-treasury-tx-issue-492`
- commit-auditor pane: `%5852`, Codex `gpt-5.6-sol` high, cwd `/code/amaru-treasury-tx-audit-492-1`
- epic runtime root: `/tmp/ms-amaru-treasury-1/epic-a`
- epic worktree: `/code/amaru-treasury-tx-epic-a485`, branch `e485-certification`
- accepted evidence branch: `491-wingriders-certification@4a01c343`
- resume pointer: `.milestones/1/resume/e485-certification.md`
- contributed fragment: `.milestones/1/session-epic-a.md`

Epic A's accepted certification remains frozen. Ticket #492 is parked mid-audit under OMNIA PAUSA:
candidate `e3104a42` is local, signed, clean, and unpushed; the auditor completed full CI but issued no
verdict. All four panes are alive and idle. Resume only on machine-owner RELEASE, using
`.milestones/1/resume/e485-certification.md`; do not restart the slice or infer implementation or live
operation authority.
