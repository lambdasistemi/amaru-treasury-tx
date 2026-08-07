# Session fragment — Epic A (#485), active ticket #492

Contributed by the epic owner for the milestone desk to sweep. **Supersedes**
`.milestones/1/session-epic-a.md`, which describes the completed certification lane and is stale for
the active run. Runtime contribution only — the desk owns aggregation into `milestones`.

Compiled 2026-08-07T12:32Z from live tmux and process state, not from memory.

## Lane — PARKED topology as of OMNIA PAUSA 2026-08-07T15:28Z

All four panes **alive and idle**. Nothing killed. Verified from `ps` and `/proc/<pid>/cwd`, not
assumed.

| pane | role | cwd | launch |
|---|---|---|---|
| `%5810` | epic owner | `/code` | `claude --dangerously-skip-permissions --model claude-opus-5` |
| `%5842` | #492 ticket owner | `/code/amaru-treasury-tx` | `codex-raw --dangerously-bypass-approvals-and-sandbox -m gpt-5.6-sol -c model_reasoning_effort=high` |
| `%5845` | #492 commit owner | `/code/amaru-treasury-tx-issue-492` | `claude --dangerously-skip-permissions --model claude-opus-5 --effort high` |
| `%5852` | #492 commit auditor | `/code/amaru-treasury-tx-audit-492-1` | `codex-raw --dangerously-bypass-approvals-and-sandbox -C /code/amaru-treasury-tx-audit-492-1 …` |

| | |
|---|---|
| tmux session | `treasury-ms1` (stable ID `$1006`) |
| window | `@4015` — **`amaru-treasury-tx-e485-t492-cross-venue-survey`**, quadrant layout repaired |
| epic runtime root | `/tmp/ms-amaru-treasury-1/epic-a` |
| epic worktree | `/code/amaru-treasury-tx-epic-a485`, branch `e485-certification@3f913693` |

Alternation holds end to end: claude epic → **codex** T.O. → **claude** commit owner → **codex**
auditor.

### Note for a resurrector

`%5822` (ticket #491's finished commit owner) was **reaped** during the layout repair — its lane was
complete, accepted and preserved, and its supervisor pane had already been killed. It no longer
exists; earlier fragments that mention it are superseded by this one.

## Authoritative CLI alternation

```
milestone desk   codex   %5803
  epic owner     claude  %5810
    ticket #492  codex   %5842
      commit owner  claude
        auditor       codex
```

Derived with `tmux-orchestrator/scripts/alternate-authoritative-cli`, not copied by eye. `agy` and
`qwen` are one draft-only category: never an authoritative seat, at most one bounded invocation per
slice, secrets a hard bar. No mid-slice reseats. An exhausted provider bucket is reported, never
silently substituted.

## GitHub

| Item | State |
|---|---|
| epic #485 | open, planner WIP |
| **#492 cross-venue USDM execution survey** | **open, ACTIVE, planner WIP** |
| #491 certification | `CERTIFICATION-PASS`, accepted, closed out |
| #486–#490 | filed, planner Backlog, **undispatched** prepared implementation map |
| milestone | https://github.com/lambdasistemi/amaru-treasury-tx/milestone/1 |

## Preserved artifacts (signed, pushed, remote-read-back verified)

| Branch | Head | Contents |
|---|---|---|
| `491-wingriders-certification` | `4a01c34349d00cb2eaf99717f69e5a46f0a6162b` | accepted certification bundle — **immutable, read-only** |
| `e485-certification` | `3f9136934427f7853bb57c1cad74ad18be4d7a98` | epic session + resume + A-002 closure duties |

`491-wingriders-certification` is **CI-red by construction**: only `format-check` fails, on four
accepted harness `.hs` files inside the immutable manifest `f41fb591…`. Reformatting them voids the
provenance. It can never be merged or PR'd as-is. If it ever must live in `main`, that needs a
deliberate `certification/**` formatter exclusion, **not** a reformat.

## Host notes

- Mainnet node socket `/code/cardano-mainnet/ipc/node.socket` — authoritative for verification.
  Verify freshness; a socket existing is not liveness.
- GPG and SSH both recovered after a host-wide outage (~09:05–11:10Z). A valid signature on this host
  reports `%G? = U` (good signature, untrusted key), **not** `G`. `N` means unsigned. Never chase `G`
  by editing the GPG trustdb.
- Escalation to the machine owner is **inbox-only**:
  `/tmp/machine/owner-opus5-takeover/inbox/NOTE-<lane>-<slug>.md`, then send nothing. `%5234` is
  reserved for the four incident classes in `/tmp/machine/RULE-inbox-not-input-2026-08-07.md`.
  Never inject into `%5803` or `%5234` from a child lane.
