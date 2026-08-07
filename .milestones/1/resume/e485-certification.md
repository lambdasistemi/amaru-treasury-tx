# Resume — Epic A (#485), active ticket #492: cross-venue USDM execution survey

Supersedes `.milestones/1/resume/e485-certification.md` for the active run. That file remains correct
about the **completed** certification and its closure duties; this one describes what is live.

Load `orchestrator-contract`, `epic-orchestrator`, `resolve-epic`, `context-compiler`,
`worker-protocol`, `tmux-orchestrator`, `invariants`. Read `.milestones/1/*`,
`handoffs/session-epic-a-t492.md`, and your runtime root
`/tmp/ms-amaru-treasury-1/epic-a/{brief.md,STATUS.md,inbox/,answers/}` in full.

## Current stage

Certification is **done and accepted**:
`CERTIFICATION-PASS — NO-AIKEN-CERTIFIED; LIVE OPERATION UNPROVEN PENDING PILOT`. No Aiken, validator,
fork or redeployment change is required on either side. Its bundle is preserved, signed and pushed.

Epic A was then **stopped** by `A-002`, and subsequently **reopened for research only** by an explicit
operator ruling — *"Do it we need the full picture"*. Ticket **#492** is the sole active child.

## Why #492 exists — the finding that reordered the milestone

At reserves observed 2026-08-07 (WingRiders 1,797,524 ADA / 357,902 USDM, mid 5.0224, fee 25 bps):

| | |
|---|---|
| full 209,424.083770 ADA in one swap | **37,263 USDM** (slippage + fee 10.64 %) |
| 8 sequential chunks, no arbitrage recovery | 37,259 USDM — no better |
| ADA needed to reach 40,000 USDM | **226,740 ADA** |
| the eight resting Sundae orders demand | **≥ 40,000.000002 USDM** |

**WingRiders today is priced worse than the limit already resting on Sundae**, and reaching the target
needs 17,316 ADA more than the orders hold.

`ledger.md` parks migration go/no-go as *"decide only from fresh cross-venue executable quotes **after**
pilot."* This finding argues the comparison belongs **before the build**: Epic B's venue adapter, the
pilot, and the migration are all unstarted, and #492 may show none of them should begin.

## #492's two questions

1. **Cross-venue executable quotes** for 209,424.083770 ADA → USDM across Minswap V1/V2, SundaeSwap V3,
   WingRiders V2, Splash, MuesliSwap, VyFinance and aggregator routes — including whether a **split**
   beats any single pool, and an explicit verdict on whether *any* route reaches 40,000 USDM today.
2. **Do script-beneficiary WingRiders requests ever batch?** All three found on mainnet are expired and
   still unspent. One counter-example settles it positively; none across the pool's history would make
   the WingRiders path unusable **regardless of price**.

Concluding *abandon the WingRiders path* is a **success** of #492, not a failure.

## Instrument dead ends already paid for — do not repeat

- Blockfrost `/assets/{asset}/addresses` is **not quantity-ordered** (reported a 162 USDM holder as
  top while a 357,902 pool existed).
- Koios `asset_addresses` **caps at 1000 rows** — 16 % of USDM supply, no DEX pool script visible.
- **Venue enumeration by holder ranking does not work.** Find pools by validator / pool NFT per venue.
- Every "none found" needs a positive control proving the method finds a known-present thing.

## Pinned facts (refresh-before-acceptance)

- USDM `c48cbb3d5e57ed56e276bc45f99ab39abe94e6cd7ac39fb402da47ad.0014df105553444d`, CIP-68 labelled;
  an unlabelled name does not resolve. Supply 9,635,422 USDM.
- WingRiders request validator `c134d839…` PlutusV2 417 B; pool `af97793b…` PlutusV2 12677 B; pool
  outref observed `db95d31a…#0`.
- Amaru `network_compliance` treasury validator `32201dc1…` **PlutusV3** 5484 B. The vendored
  blueprint `3c6cf297…` in `assets/blueprints/treasury-spend.cip57.json` returns **404 on chain** — a
  live trap in the repo; consumers must not treat it as the deployed hash.
- Eight `57faba5b…` outputs: 8/8 unspent, 209,450.323770 ADA locked / 209,424.083770 ADA swap offer;
  delta 26.24 ADA = 8 × (2 ADA min-UTxO + 1.28 ADA Sundae V3 fee). Re-verify before any state claim.

## Exact parked boundary — where #492 stopped (OMNIA PAUSA 15:28Z)

The lane is **mid-audit of its first submission**. Nothing is pushed and no verdict exists.

```
12:52:28Z  SLICE-START   slug=usdm-survey mode=OWNER child=commit-owner-1 pane=%5845
                         gate=6b2e5a7c998e7f3e0af47e0709c4abc02476b25f703eef6b6b311e8c6be4457a
13:59:49Z  GREEN-COMMIT  e3104a422c0cee6d4b7d1772c6f136c640272a02  parent=8bae2b2f  sig=U
                         (commit owner then parked write-idle; worktree + index clean, unpushed)
14:04:30Z  AUDIT-START   submission=1 candidate=e3104a42 child=commit-auditor-1 pane=%5852
                         cli=codex owner_cli=claude alternate=true
14:20:24Z  auditor PARKED  gates complete, just-ci exit=0 sha256=e0d7dc82, candidate clean
14:21:19Z  ticket PARKED   evidence manifest 23/23 OK, audit CI exit=0, NO verdict, NO COMPLETE
```

**Resume boundary:** the fresh auditor `%5852` had completed its required gates but had **not issued a
verdict** when it parked. On RELEASE, the ticket owner resumes by obtaining that verdict for candidate
`e3104a42`, then deciding acceptance. Do not restart the audit from scratch and do not re-run the
slice — the candidate and its gate hash are frozen and clean.

**Do not `COMPLETE` #492 on resume** — the survey questions are not yet answered; only the first
submission was proved.

## Exact next action

Supervise ticket #492 in pane `%5842` through `worker-protocol`. On `COMPLETE`, **independently
re-derive** its headline quotes on a second instrument before accepting — the certification acceptance
did exactly this and it is what makes acceptance mean anything. Then report to the milestone desk
`%5803` and stop.

## Safety fence — unchanged and absolute

Research-only. **No** product code, contract change, implementation, pilot, dispatch of #486–#490,
signing of transactions, submission, cancellation, or treasury-value movement. The eight `57faba5b…`
outputs stay untouched. The accepted certification bundle on `491-wingriders-certification@4a01c343`
is immutable. Reclaim key identity and cap values remain parked operator decisions and must not be
chosen here.

Read-only chain observation through the local node or an index is not a mutation. Anything that writes
is, and routes to the machine owner's inbox first.
