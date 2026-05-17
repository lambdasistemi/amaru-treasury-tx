# Requirements Checklist — #157

Mapping from the issue body's acceptance criteria to spec.md
functional requirements (FR) and success criteria (SC). Tracks
completeness of the spec phase before plan / tasks authoring.

| Issue AC | Spec FR / SC | Status |
|---|---|---|
| Parser no longer exposes `devnet`. None of the four bootstrap actions appear as shipped CLI subcommands. | FR-001, FR-006, SC-001 | covered |
| `SomeTreasuryIntent` gains three new constructors with JSON round-trip. | FR-002, FR-003, SC-003 | covered |
| `tx-build --intent <bootstrap-intent.json>` produces the same unsigned tx CBOR hex the library function builds today (golden coverage per action). | FR-004, SC-002 | covered |
| End-to-end runners no longer reachable from the shipped CLI; relocated under `lib/Amaru/Treasury/Devnet/` consumed only by `SmokeSpec`. | FR-005, NFR-002 | covered |
| Network-safety guards remain on every entry; mainnet/preprod fail closed. | FR-007 | covered |
| `SmokeSpec` continues to compile and pass, calling production library functions through `withDevnet`. No CLI shelling. | User Story 3, SC-005 | covered |
| README and `docs/local-devnet-smoke.md` describe the new operator path; wizard mentions point to #158–#160. | FR-009, SC-006 | covered |
| PR is bisect-safe; each commit passes `./gate.sh`. | FR-010, SC-004 | covered |

Non-goals (from issue and parent #156), explicitly excluded:

- New wizard commands (#158–#160).
- Bash `smoke.sh` (#161).
- Mainnet / preprod work.

Open clarifications: none at spec phase. The producer side of the
`bootstrap-intent.json` (wizard or hand-rolled JSON) is intentionally
out of scope; planning will need to decide whether to ship a tiny
test-support helper to materialize fixture intents for the golden
proof, or to commit static fixture JSON. That is a plan-phase
decision, not a spec-phase ambiguity.
