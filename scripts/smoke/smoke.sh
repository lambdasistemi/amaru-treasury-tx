#!/usr/bin/env bash
# CLI DevNet smoke entrypoint for issue #161.
#
# This script is the operator/CLI proof layer for the
# amaru-treasury-tx bootstrap + disburse play. It drives
# the shipped CLI (wizards, tx-build, vault create,
# witness, attach-witness, submit). It must never call
# in-process Haskell runners.
#
# Slice 1 ships scaffold only:
#   * argument parsing for the public flags;
#   * dependency preflight for the chosen phase;
#   * run-dir layout creation.
#
# Live DevNet lifecycle, key fixtures, vault preflight,
# registry/stake/governance/disburse phases land in
# later slices on this same entrypoint.

set -euo pipefail

PROG=cli-devnet-smoke
DEFAULT_PHASE=scaffold
DEFAULT_TIMEOUT_SECONDS=900

print_help() {
    cat <<'HELP'
cli-devnet-smoke: shipped CLI DevNet smoke proof for amaru-treasury-tx (#161)

Usage:
  scripts/smoke/smoke.sh [options]

Options:
  --run-dir <path>           Run directory (default: runs/devnet-cli/<timestamp>).
  --inside-devnet            Mark that the script runs inside the DevNet host callback;
                             skips DevNet bring-up and trusts CARDANO_NODE_SOCKET_PATH.
  --phase <name>             scaffold | preflight | vault-preflight | registry-stake |
                             governance | disburse | full (default: scaffold).
  --timeout-seconds <int>    Per-phase polling timeout in seconds (default: 900).
  --force                    Allow a non-empty existing --run-dir.
  --help                     Show this help and exit.

Slice 2 implements scaffold, preflight, and vault-preflight (the shipped
vault create / witness / attach-witness round-trip). Later slices wire the
full bootstrap + disburse CLI pipeline on the same flags.

This script drives only shipped amaru-treasury-tx CLI commands. See
specs/161-cli-devnet-smoke/ for the no-in-process-runner contract and the
static guard that enforces it.
HELP
}

log() {
    printf '%s: %s\n' "$PROG" "$*" >&2
}

die() {
    log "$*"
    exit 1
}

require_tool() {
    local tool=$1
    if ! command -v "$tool" >/dev/null 2>&1; then
        die "missing required tool: $tool"
    fi
}

preflight_for_phase() {
    local phase=$1
    case "$phase" in
        scaffold)
            ;;
        preflight)
            require_tool jq
            require_tool cardano-cli
            require_tool cardano-node
            require_tool amaru-treasury-tx
            ;;
        vault-preflight)
            require_tool jq
            require_tool diff
            require_tool amaru-treasury-tx
            ;;
        registry-stake | governance | disburse | full)
            require_tool jq
            require_tool cardano-cli
            require_tool cardano-node
            require_tool amaru-treasury-tx
            ;;
        *)
            die "unknown phase: $phase (try --help)"
            ;;
    esac
}

require_env() {
    local name=$1
    if [[ -z "${!name:-}" ]]; then
        die "missing required environment variable: $name (the host owns this)"
    fi
}

require_file() {
    local label=$1
    local path=$2
    if [[ ! -e "$path" ]]; then
        die "$label not found at: $path"
    fi
}

vault_preflight() {
    local run_dir=$1
    local phase_dir="$run_dir/phases/vault-preflight"
    mkdir -p "$phase_dir"

    require_env CLI_SMOKE_FUNDING_SKEY
    require_env CLI_SMOKE_VOTER_SKEY
    require_file "funding signing key" "$CLI_SMOKE_FUNDING_SKEY"
    require_file "voter signing key" "$CLI_SMOKE_VOTER_SKEY"

    local fixture="test/fixtures/118-vault-witness"
    require_file "vault-witness fixture payment.skey" \
        "$fixture/payment.skey"
    require_file "vault-witness fixture unsigned tx" \
        "$fixture/unsigned.cbor.hex"
    require_file "vault-witness fixture expected signed tx" \
        "$fixture/signed.expected.cbor.hex"

    local passphrase="cli-smoke-preflight-passphrase"
    local funding_vault="$phase_dir/funding.vault.age"
    local voter_vault="$phase_dir/voter.vault.age"
    local fixture_vault="$phase_dir/fixture.vault.age"
    local fixture_witness="$phase_dir/fixture.owner.witness.hex"
    local fixture_signed="$phase_dir/fixture.signed.cbor.hex"

    log "vault-preflight: vault create on funding key"
    {
        exec 9< <(printf '%s' "$passphrase")
        amaru-treasury-tx --network devnet vault create \
            --signing-key-file "$CLI_SMOKE_FUNDING_SKEY" \
            --label devnet_funding \
            --description "DevNet funding key (smoke)" \
            --out "$funding_vault" \
            --vault-work-factor 1 \
            --vault-passphrase-fd 9
        exec 9<&-
    }
    [[ -s "$funding_vault" ]] \
        || die "vault create did not write funding vault"

    log "vault-preflight: vault create on voter key"
    {
        exec 9< <(printf '%s' "$passphrase")
        amaru-treasury-tx --network devnet vault create \
            --signing-key-file "$CLI_SMOKE_VOTER_SKEY" \
            --label devnet_voter \
            --description "DevNet voter key (smoke)" \
            --out "$voter_vault" \
            --vault-work-factor 1 \
            --vault-passphrase-fd 9
        exec 9<&-
    }
    [[ -s "$voter_vault" ]] \
        || die "vault create did not write voter vault"

    log "vault-preflight: vault create on fixture key"
    {
        exec 9< <(printf '%s' "$passphrase")
        amaru-treasury-tx --network preprod vault create \
            --signing-key-file "$fixture/payment.skey" \
            --label core_development \
            --description "118 vault-witness fixture" \
            --out "$fixture_vault" \
            --vault-work-factor 1 \
            --vault-passphrase-fd 9
        exec 9<&-
    }

    log "vault-preflight: witness fixture unsigned tx"
    {
        exec 9< <(printf '%s' "$passphrase")
        amaru-treasury-tx --network preprod witness \
            --tx "$fixture/unsigned.cbor.hex" \
            --vault "$fixture_vault" \
            --identity core_development \
            --out "$fixture_witness" \
            --vault-passphrase-fd 9
        exec 9<&-
    }
    [[ -s "$fixture_witness" ]] \
        || die "witness did not write a witness hex"

    log "vault-preflight: attach-witness fixture"
    local witness_hex
    witness_hex=$(tr -d '\n' <"$fixture_witness")
    amaru-treasury-tx attach-witness \
        --tx "$fixture/unsigned.cbor.hex" \
        --witness "$witness_hex" \
        --out "$fixture_signed"

    diff -u "$fixture/signed.expected.cbor.hex" "$fixture_signed" \
        || die "attach-witness output diverged from expected fixture"

    cat >"$phase_dir/summary.json" <<JSON
{
  "phase": "vault-preflight",
  "fundingVault": "$funding_vault",
  "voterVault": "$voter_vault",
  "fixtureVault": "$fixture_vault",
  "fixtureWitness": "$fixture_witness",
  "fixtureSigned": "$fixture_signed",
  "fundingKeyHash": "${CLI_SMOKE_FUNDING_KEY_HASH:-}",
  "voterKeyHash": "${CLI_SMOKE_VOTER_KEY_HASH:-}",
  "networkMagic": "${CLI_SMOKE_NETWORK_MAGIC:-}",
  "socket": "${CLI_SMOKE_SOCKET:-}"
}
JSON
    log "vault-preflight: complete (summary in $phase_dir/summary.json)"
}

create_run_dir() {
    local run_dir=$1
    local force=$2
    if [[ -e "$run_dir" ]]; then
        if [[ "$force" != "1" ]]; then
            die "run-dir already exists (pass --force to reuse): $run_dir"
        fi
    fi
    mkdir -p "$run_dir"
    mkdir -p \
        "$run_dir/phases" \
        "$run_dir/intents" \
        "$run_dir/unsigned" \
        "$run_dir/witnesses" \
        "$run_dir/signed" \
        "$run_dir/submits" \
        "$run_dir/chain" \
        "$run_dir/diagnostics"
    printf '%s\n' "$run_dir"
}

main() {
    local run_dir=""
    local inside_devnet=0
    local phase="$DEFAULT_PHASE"
    local timeout_seconds="$DEFAULT_TIMEOUT_SECONDS"
    local force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --run-dir)
                [[ $# -ge 2 ]] || die "--run-dir needs a value"
                run_dir=$2
                shift 2
                ;;
            --run-dir=*)
                run_dir=${1#--run-dir=}
                shift
                ;;
            --inside-devnet)
                inside_devnet=1
                shift
                ;;
            --phase)
                [[ $# -ge 2 ]] || die "--phase needs a value"
                phase=$2
                shift 2
                ;;
            --phase=*)
                phase=${1#--phase=}
                shift
                ;;
            --timeout-seconds)
                [[ $# -ge 2 ]] || die "--timeout-seconds needs a value"
                timeout_seconds=$2
                shift 2
                ;;
            --timeout-seconds=*)
                timeout_seconds=${1#--timeout-seconds=}
                shift
                ;;
            --force)
                force=1
                shift
                ;;
            --help | -h)
                print_help
                exit 0
                ;;
            --)
                shift
                break
                ;;
            *)
                die "unknown option: $1 (try --help)"
                ;;
        esac
    done

    if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || [[ "$timeout_seconds" -le 0 ]]; then
        die "--timeout-seconds must be a positive integer (got: $timeout_seconds)"
    fi

    if [[ -z "$run_dir" ]]; then
        local stamp
        stamp=$(date -u +%Y%m%dT%H%M%SZ)
        run_dir="runs/devnet-cli/$stamp"
    fi

    preflight_for_phase "$phase"
    create_run_dir "$run_dir" "$force" >/dev/null

    if [[ "$inside_devnet" -eq 1 ]]; then
        log "inside-devnet mode (host-provided DevNet)"
    fi

    log "phase=$phase run-dir=$run_dir timeout=${timeout_seconds}s"

    case "$phase" in
        scaffold)
            log "scaffold complete; live phases land in later #161 slices"
            ;;
        preflight)
            log "preflight complete; tools are reachable"
            ;;
        vault-preflight)
            vault_preflight "$run_dir"
            ;;
        registry-stake | governance | disburse | full)
            die "phase '$phase' not implemented yet in this slice; see specs/161-cli-devnet-smoke/plan.md"
            ;;
    esac
}

main "$@"
