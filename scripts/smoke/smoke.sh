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
  --phase <name>             scaffold | preflight | host | registry-stake | governance |
                             disburse | full (default: scaffold).
  --timeout-seconds <int>    Per-phase polling timeout in seconds (default: 900).
  --force                    Allow a non-empty existing --run-dir.
  --help                     Show this help and exit.

Slice 1 implements scaffold and preflight only. Later slices wire host bring-up,
vault preflight, and the full bootstrap + disburse CLI pipeline on the same flags.

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
        preflight | host | registry-stake | governance | disburse | full)
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
            log "preflight complete; host bring-up lands in slice 2"
            ;;
        host | registry-stake | governance | disburse | full)
            die "phase '$phase' not implemented yet in slice 1; see specs/161-cli-devnet-smoke/plan.md"
            ;;
    esac
}

main "$@"
