#!/usr/bin/env bash
# CMD-VERIFY — offline evidence verifier for issue #491.
#
# Verifies hashes, observation schema, per-CQ control coverage, path fence
# and verdict shape, and FAILS on seeded missing, altered, or vacuous
# evidence.
#
# A verifier that has only ever been run against good evidence is a claim,
# not a check. So before it accepts the real bundle it runs its own core
# against three deliberately corrupted copies and requires each to be
# rejected. It prints, in order:
#
#   POSITIVE-CONTROL-PASS   core accepts a known-good copy
#   TAMPER-CONTROL-RED      core rejects an altered raw log
#   MISSING-CONTROL-RED     core rejects a deleted raw log
#   VACUITY-CONTROL-RED     core rejects a panel with no failing case
#   EVIDENCE-VERIFY-PASS    core accepts the real bundle
#
# Usage: verify-evidence.sh [evidence-root] [report-path]
set -uo pipefail

root=${1:-$(dirname "$0")/evidence}
report=${2:-$(dirname "$0")/report.md}

# --- core -----------------------------------------------------------------
# Exits non-zero on any defect. Prints nothing on success except its own
# reason lines on failure, so the controls below stay readable.

core() {
    local ev=$1 rep=$2 why

    [ -d "$ev" ] || { echo "  reason: missing evidence root" >&2; return 1; }
    [ -f "$ev/SHA256SUMS" ] || { echo "  reason: missing SHA256SUMS" >&2; return 1; }
    [ -f "$ev/observations.jsonl" ] || { echo "  reason: missing observations" >&2; return 1; }

    # 1. Every hash in the manifest must still match, and nothing named in
    #    the manifest may be absent. This is what catches tamper + missing.
    ( cd "$ev" && sha256sum --check --status SHA256SUMS ) || {
        echo "  reason: manifest hash check failed" >&2; return 1; }

    # 2. Every raw log on disk must be covered by the manifest, so evidence
    #    cannot be smuggled in unhashed.
    local f
    while IFS= read -r f; do
        grep -qF "  $f" "$ev/SHA256SUMS" || {
            echo "  reason: unhashed evidence file: $f" >&2; return 1; }
    done < <( cd "$ev" && find raw -type f | sort )

    # 3. DATA-OBSERVATION schema: every row carries the required fields and
    #    a real exit code, and points at a raw log that exists.
    local rows
    rows=$(wc -l < "$ev/observations.jsonl")
    [ "$rows" -ge 20 ] || { echo "  reason: too few observations ($rows)" >&2; return 1; }
    jq -e -s 'all(.[];
          has("cq") and has("utc") and has("slot") and has("source_kind")
      and has("pin") and has("command") and has("exit") and has("raw_log")
      and has("sha256") and (.sha256 | test("^[0-9a-f]{64}$"))
      and (.utc | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")))' \
      "$ev/observations.jsonl" >/dev/null || {
        echo "  reason: observation schema violation" >&2; return 1; }

    # 4. Per-CQ control coverage. Each panel must exist, must report zero
    #    failures, and -- the anti-vacuity condition -- must contain at
    #    least one case that EXPECTED a rejection and actually got one.
    #    A panel of only green cases proves nothing about the check's
    #    ability to fail, so it is rejected here.
    local panel greens reds
    for spec in \
        "cq4-reclaim-controls-v2.log:CQ4-CONTROLS-COMPLETE:3" \
        "cq2-script-beneficiary-controls.log:CQ2-CONTROLS-COMPLETE:3" \
        "cq3-treasury-spend-controls.log:CQ3-CONTROLS-COMPLETE:1"
    do
        panel="$ev/raw/${spec%%:*}"
        why=${spec#*:}; local marker=${why%%:*}; local minred=${why##*:}
        [ -f "$panel" ] || { echo "  reason: missing panel ${spec%%:*}" >&2; return 1; }
        grep -qF "$marker" "$panel" || {
            echo "  reason: panel not complete: ${spec%%:*}" >&2; return 1; }
        grep -qE 'failures=0|SUMMARY .*failures=0' "$panel" || {
            echo "  reason: panel reports failures: ${spec%%:*}" >&2; return 1; }
        greens=$(grep -cE 'expect=(ExpectOk|OK) +got=(ExpectOk|OK)' "$panel")
        reds=$(grep -cE 'expect=(ExpectErr|ERROR) +got=(ExpectErr|ERROR)' "$panel")
        [ "$greens" -ge 1 ] || {
            echo "  reason: no accepted case in ${spec%%:*}" >&2; return 1; }
        [ "$reds" -ge "$minred" ] || {
            echo "  reason: vacuous panel, only $reds demonstrated rejections in ${spec%%:*} (need $minred)" >&2
            return 1; }
    done

    # 5. The replay fidelity panel must show every real batch validating.
    local fp="$ev/raw/cq2-replay-fidelity-panel.log"
    [ -f "$fp" ] || { echo "  reason: missing replay fidelity panel" >&2; return 1; }
    [ "$(grep -c 'result=OK' "$fp")" -ge 8 ] || {
        echo "  reason: too few validated real batches" >&2; return 1; }
    grep -q 'result=ERROR' "$fp" && {
        echo "  reason: a real mainnet batch failed to replay" >&2; return 1; }

    # 6. Report shape and verdict.
    [ -f "$rep" ] || { echo "  reason: missing report" >&2; return 1; }
    local first; first=$(sed -n '1p' "$rep")
    case "$first" in
        "# WingRiders V2 certification: CERTIFICATION-PASS"|\
        "# WingRiders V2 certification: CERTIFICATION-FAILED") ;;
        *) echo "  reason: report lacks exactly one allowed verdict" >&2; return 1 ;;
    esac
    local s
    for s in "## CQ1" "## CQ2" "## CQ3" "## CQ4" \
             "## Certification findings" "## Custody findings" \
             "## Registry deltas" "Registry enforcement: NONE" \
             "280a9e895077ab746c2713880efba79038fea50f" \
             "acc572a40acc498a8843db79e2d3afa409f509b1" \
             "not verified against the deployment"
    do
        grep -qF "$s" "$rep" || { echo "  reason: report missing: $s" >&2; return 1; }
    done
    grep -qE '^## Residual custody exposure' "$rep" || {
        echo "  reason: no top-level residual custody section" >&2; return 1; }
    grep -qiF "explicit operator acceptance before any pilot" "$rep" || {
        echo "  reason: no custody operator-acceptance requirement" >&2; return 1; }

    # Every evidence hash cited by the report must exist in the manifest,
    # so the report cannot reference evidence that was never captured.
    local h
    while IFS= read -r h; do
        grep -qF "$h" "$ev/SHA256SUMS" || {
            echo "  reason: report cites unknown evidence hash $h" >&2; return 1; }
    done < <(grep -ohE 'sha256=[0-9a-f]{64}' "$rep" | cut -d= -f2 | sort -u)

    return 0
}

# --- controls -------------------------------------------------------------

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Raw evidence is stored 0444, so a copy must be made writable before it
# can be corrupted. Without this the seed silently no-ops and the control
# "passes" while testing nothing.
seed() { rm -rf "$work/$1"; cp -a "$root" "$work/$1"; chmod -R u+w "$work/$1"; }

# Require a seeded corruption to have actually changed the file. A control
# built on a seed that failed to apply is exactly the vacuous check this
# verifier exists to reject.
assert_changed() {
    local before=$1 after=$2 what=$3
    [ "$before" != "$after" ] || fail "seed did not modify $what"
}

fail() { echo "EVIDENCE-VERIFY-FAIL: $*" >&2; exit 1; }

# Control 1 — known-good copy must be accepted.
seed good
if core "$work/good" "$report"; then
    echo "POSITIVE-CONTROL-PASS"
else
    fail "verifier rejects known-good evidence"
fi

# Control 2 — altered raw log must be rejected.
seed tampered
t_before=$(sha256sum "$work/tampered/raw/cq3-treasury-spend-controls.log" | cut -d" " -f1)
printf 'x' >> "$work/tampered/raw/cq3-treasury-spend-controls.log"
t_after=$(sha256sum "$work/tampered/raw/cq3-treasury-spend-controls.log" | cut -d" " -f1)
assert_changed "$t_before" "$t_after" "the tampered log"
if core "$work/tampered" "$report" 2>/dev/null; then
    fail "tampered evidence accepted"
else
    echo "TAMPER-CONTROL-RED"
fi

# Control 3 — deleted raw log must be rejected.
seed missing
rm -f "$work/missing/raw/cq2-script-beneficiary-controls.log"
if core "$work/missing" "$report" 2>/dev/null; then
    fail "missing evidence accepted"
else
    echo "MISSING-CONTROL-RED"
fi

# Control 4 — vacuous panel must be rejected. Strip every demonstrated
# rejection from a panel but leave it "complete" with zero failures: the
# shape a check that cannot fail would have.
seed vacuous
v="$work/vacuous/raw/cq2-script-beneficiary-controls.log"
v_before=$(sha256sum "$v" | cut -d" " -f1)
grep -v 'expect=ERROR' "$v" > "$v.tmp" && mv "$v.tmp" "$v"
v_after=$(sha256sum "$v" | cut -d" " -f1)
assert_changed "$v_before" "$v_after" "the vacuous panel"
( cd "$work/vacuous" && sha256sum raw/* observations.jsonl > SHA256SUMS )
if core "$work/vacuous" "$report" 2>/dev/null; then
    fail "vacuous evidence accepted"
else
    echo "VACUITY-CONTROL-RED"
fi

# Real bundle.
if core "$root" "$report"; then
    echo "EVIDENCE-VERIFY-PASS"
else
    fail "real evidence bundle rejected"
fi
