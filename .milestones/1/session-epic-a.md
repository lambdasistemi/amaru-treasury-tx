# Session fragment — Epic A (issue #485)

Contributed by the epic owner. The milestone desk sweeps this; it does not invent it.

## Lane

- tmux session: `treasury-ms1` (stable session ID `$1006`)
- window: `amaru-treasury-tx-e485-t-certify-no-aiken` (stable window ID `@4015`)
- pane: `%5810`
- CLI family: **Claude** (`claude-opus-5`) — alternates from the Codex milestone desk `%5803`
- role chain: `orchestrator-contract` → `epic-orchestrator` → `resolve-epic` → `context-compiler` → `worker-protocol` → `tmux-orchestrator` → `invariants`
- runtime root: `/tmp/ms-amaru-treasury-1/epic-a`
- worktree: `/code/amaru-treasury-tx-epic-a485`, branch `e485-certification` (tracks `milestones`)
- resume pointer: `.milestones/1/resume/e485-certification.md`

## Authoritative CLI alternation for this lane

```
milestone desk (codex, %5803)
  └─ epic owner      claude   %5810
       └─ ticket owner   codex
            └─ commit owner  claude
                 └─ auditor       codex
```

Derived mechanically via `tmux-orchestrator/scripts/alternate-authoritative-cli`, not copied by eye.
`agy` and `qwen` are one draft-only category: never an authoritative seat, one bounded invocation
per slice at most, secrets a hard bar. No mid-slice reseats. An exhausted provider bucket is
reported, never silently substituted.

## GitHub

- parent epic: https://github.com/lambdasistemi/amaru-treasury-tx/issues/485
- children (ordered, **not dispatched**): #486 → #487 → #488 → #489 → #490
- milestone: https://github.com/lambdasistemi/amaru-treasury-tx/milestone/1

## Current terminal condition

Operator, 2026-08-07: *stop when you have certified we can operate without aiken modifications.*

This run is **research/certification only**. Children #486–#490 are the prepared future
implementation map and are explicitly not dispatched.
