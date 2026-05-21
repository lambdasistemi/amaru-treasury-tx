#!/usr/bin/env bash
# CLI DevNet smoke entrypoint for issue #161.
#
# This script is the operator/CLI proof layer for the
# amaru-treasury-tx bootstrap + disburse play. It drives
# the shipped CLI (wizards, tx-build, vault create,
# witness, attach-witness, submit). It must never call
# in-process Haskell runners.
#
# The default scaffold phase keeps argument parsing cheap for static
# checks. Live phases route through the Haskell DevNet host unless the
# script is already running inside that host callback.

set -euo pipefail

PROG=cli-devnet-smoke
DEFAULT_PHASE=scaffold
DEFAULT_TIMEOUT_SECONDS=900
AMARU_EXE=""
CLI_SMOKE_REGISTRY_TIMEOUT_SECONDS="${CLI_SMOKE_REGISTRY_TIMEOUT_SECONDS:-60}"
GOVERNANCE_WITHDRAWAL_LOVELACE=2000000
DISBURSE_LOVELACE=1000000
GOVERNANCE_ANCHOR_URL="https://example.invalid/amaru-devnet-governance.json"
GOVERNANCE_ANCHOR_HASH="000000000000000000000000000000000000000000000000000000000000002a"

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

Live phases route through devnet-cli-smoke-host, bring up a patched local
DevNet, create DevNet vaults, drive the shipped wizard -> tx-build ->
witness -> attach-witness -> submit pipeline, and write run-dir artifacts
plus host chain assertions. Use --phase full for the complete registry,
stake/reward, governance materialization, and disburse proof.

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
            require_tool cardano-node
            require_tool amaru-treasury-tx
            ;;
        vault-preflight)
            require_tool jq
            require_tool diff
            require_tool amaru-treasury-tx
            ;;
        registry-stake)
            # Branch-built amaru-treasury-tx is resolved via cabal
            # list-bin inside registry_stake_phase to avoid stale
            # PATH binaries (#161 mandate). Only jq/cabal/tr are
            # required here.
            require_tool jq
            require_tool cabal
            require_tool tr
            ;;
        governance | disburse | full)
            require_tool jq
            require_tool cabal
            require_tool tr
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

resolve_amaru_exe() {
    if [[ -n "${AMARU_TREASURY_TX_EXE:-}" ]]; then
        printf '%s\n' "$AMARU_TREASURY_TX_EXE"
        return 0
    fi
    if ! command -v cabal >/dev/null 2>&1; then
        die "cannot resolve amaru-treasury-tx exe: cabal missing"
    fi
    cabal build exe:amaru-treasury-tx -O0 >/dev/null 2>&1 \
        || die "cabal build exe:amaru-treasury-tx failed"
    cabal list-bin exe:amaru-treasury-tx -O0
}

require_inside_devnet() {
    local inside=$1
    local phase=$2
    local run_dir=$3
    local timeout_seconds=$4
    local force=$5
    if [[ "$inside" -eq 1 ]]; then
        return 0
    fi
    log "phase '$phase' requires a live DevNet; routing through devnet-cli-smoke-host"
    if ! command -v cabal >/dev/null 2>&1; then
        die "cabal missing; cannot run devnet-cli-smoke-host"
    fi
    cabal build exe:devnet-cli-smoke-host -O0 >/dev/null 2>&1 \
        || die "cabal build exe:devnet-cli-smoke-host failed"
    local host_exe
    host_exe=$(cabal list-bin exe:devnet-cli-smoke-host -O0)
    # Always pass --force to the host: the shell smoke has already
    # gated on its own --force flag via create_run_dir, and the host
    # would otherwise refuse to reuse the run-dir we just created.
    local host_args=(--run-dir "$run_dir" --phase "$phase" \
        --timeout-seconds "$timeout_seconds" --force)
    exec "$host_exe" "${host_args[@]}"
}

# Shared shipped-CLI tx pipeline used by every registry-stake build.
#
# Reads inputs from positional arguments; persists artifacts under the
# run-dir's unsigned/, witnesses/, signed/, submits/, and diagnostics/
# trees; checks pre-submission tx-id (from tx-build's --report) against
# post-submission tx-id (from submit stdout). Echoes only the submitted
# tx-id on stdout so callers can capture it via command substitution.
#
# Required global env: AMARU_EXE, CARDANO_NODE_SOCKET_PATH, run_dir.
# Args: label intent_path vault_path identity expected_key_hash
#       passphrase_file
build_sign_submit() {
    local label=$1
    local intent_path=$2
    local vault_path=$3
    local identity=$4
    local expected_key_hash=$5
    local passphrase_file=$6

    local cbor_path="$run_dir/unsigned/${label}.cbor.hex"
    local report_path="$run_dir/diagnostics/${label}.report.json"
    local witness_path="$run_dir/witnesses/${label}.${identity}.witness.hex"
    local signed_path="$run_dir/signed/${label}.signed.cbor.hex"
    local txid_path="$run_dir/submits/${label}.txid"
    local outcome_path="$run_dir/submits/${label}.outcome"
    local build_log="$run_dir/diagnostics/${label}.build.log"

    # Every step uses `|| return $?` because this function is
    # invoked under command substitution; bash's `set -e` is
    # suppressed for assignment-from-command-substitution, so
    # explicit propagation is what surfaces the failure to the
    # caller and stops the cascade dead.

    log "$label: tx-build"
    "$AMARU_EXE" --network devnet \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        tx-build \
        -i "$intent_path" \
        -o "$cbor_path" \
        --log "$build_log" \
        --report "$report_path" \
        || return $?

    log "$label: witness (identity=$identity)"
    {
        exec 9<"$passphrase_file" || return $?
        local witness_status=0
        "$AMARU_EXE" --network devnet witness \
            --tx "$cbor_path" \
            --vault "$vault_path" \
            --identity "$identity" \
            --expected-key-hash "$expected_key_hash" \
            --allow-unlisted-key \
            --force \
            --out "$witness_path" \
            --vault-passphrase-fd 9 \
            || witness_status=$?
        # Close fd 9 unconditionally before propagating, so the
        # original witness exit status is not overwritten by the
        # `exec 9<&-` status.
        exec 9<&-
        if [[ "$witness_status" -ne 0 ]]; then
            return "$witness_status"
        fi
    } || return $?

    log "$label: attach-witness"
    local witness_hex
    witness_hex=$(tr -d '\n' <"$witness_path") || return $?
    "$AMARU_EXE" attach-witness \
        --tx "$cbor_path" \
        --witness "$witness_hex" \
        --out "$signed_path" \
        || return $?

    log "$label: submit"
    "$AMARU_EXE" --network devnet \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        submit --tx "$signed_path" \
        >"$txid_path" 2>"$outcome_path" \
        || return $?

    # The shipped `submit` returns SubmitAccepted as soon as the
    # node enqueues the tx in its mempool. Downstream tx-build calls
    # need the outputs visible in the acquired ledger snapshot, which
    # only happens after block inclusion. DevNet's pinned genesis
    # produces blocks every ~100ms; a 2-second settle is many block
    # ticks of headroom and keeps the smoke determined without
    # introducing a new shipped wait surface.
    sleep 2

    local submitted_tx_id
    submitted_tx_id=$(tr -d '\n' <"$txid_path") || return $?
    if [[ -z "$submitted_tx_id" ]]; then
        log "$label: submit produced empty tx id (see $outcome_path)"
        return 64
    fi

    local report_tx_id
    report_tx_id=$(jq -r '.result.report.identity.txId' "$report_path") \
        || return $?
    if [[ -z "$report_tx_id" || "$report_tx_id" == "null" ]]; then
        log "$label: tx-build report missing identity.txId (see $report_path)"
        return 65
    fi
    if [[ "$submitted_tx_id" != "$report_tx_id" ]]; then
        log "$label: tx-id mismatch (submit=$submitted_tx_id report=$report_tx_id)"
        return 66
    fi

    log "$label: tx-id $submitted_tx_id"
    printf '%s' "$submitted_tx_id"
}

# Variant for governance proposal transactions that require more than
# one detached witness. Positional triples after passphrase_file are:
# vault_path identity expected_key_hash. Echoes the submitted tx-id.
build_sign_submit_multi() {
    local label=$1
    local intent_path=$2
    local passphrase_file=$3
    shift 3

    if [[ "$#" -eq 0 || $(( $# % 3 )) -ne 0 ]]; then
        log "$label: build_sign_submit_multi needs witness triples"
        return 67
    fi

    local cbor_path="$run_dir/unsigned/${label}.cbor.hex"
    local report_path="$run_dir/diagnostics/${label}.report.json"
    local signed_path="$run_dir/signed/${label}.signed.cbor.hex"
    local txid_path="$run_dir/submits/${label}.txid"
    local outcome_path="$run_dir/submits/${label}.outcome"
    local build_log="$run_dir/diagnostics/${label}.build.log"

    log "$label: tx-build"
    "$AMARU_EXE" --network devnet \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        tx-build \
        -i "$intent_path" \
        -o "$cbor_path" \
        --log "$build_log" \
        --report "$report_path" \
        || return $?

    local attach_args=(attach-witness --tx "$cbor_path" --out "$signed_path")
    while [[ "$#" -gt 0 ]]; do
        local vault_path=$1
        local identity=$2
        local expected_key_hash=$3
        shift 3

        local witness_path="$run_dir/witnesses/${label}.${identity}.witness.hex"
        log "$label: witness (identity=$identity)"
        {
            exec 9<"$passphrase_file" || return $?
            local witness_status=0
            "$AMARU_EXE" --network devnet witness \
                --tx "$cbor_path" \
                --vault "$vault_path" \
                --identity "$identity" \
                --expected-key-hash "$expected_key_hash" \
                --force \
                --out "$witness_path" \
                --vault-passphrase-fd 9 \
                || witness_status=$?
            exec 9<&-
            if [[ "$witness_status" -ne 0 ]]; then
                return "$witness_status"
            fi
        } || return $?

        local witness_hex
        witness_hex=$(tr -d '\n' <"$witness_path") || return $?
        attach_args+=(--witness "$witness_hex")
    done

    log "$label: attach-witness"
    "$AMARU_EXE" "${attach_args[@]}" || return $?

    log "$label: submit"
    "$AMARU_EXE" --network devnet \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        submit --tx "$signed_path" \
        >"$txid_path" 2>"$outcome_path" \
        || return $?

    sleep 2

    local submitted_tx_id
    submitted_tx_id=$(tr -d '\n' <"$txid_path") || return $?
    if [[ -z "$submitted_tx_id" ]]; then
        log "$label: submit produced empty tx id (see $outcome_path)"
        return 64
    fi

    local report_tx_id
    report_tx_id=$(jq -r '.result.report.identity.txId' "$report_path") \
        || return $?
    if [[ -z "$report_tx_id" || "$report_tx_id" == "null" ]]; then
        log "$label: tx-build report missing identity.txId (see $report_path)"
        return 65
    fi
    if [[ "$submitted_tx_id" != "$report_tx_id" ]]; then
        log "$label: tx-id mismatch (submit=$submitted_tx_id report=$report_tx_id)"
        return 66
    fi

    log "$label: tx-id $submitted_tx_id"
    printf '%s' "$submitted_tx_id"
}

create_devnet_vault() {
    local signing_key=$1
    local identity=$2
    local description=$3
    local out_path=$4
    local passphrase_file=$5

    {
        exec 9<"$passphrase_file"
        "$AMARU_EXE" --network devnet vault create \
            --signing-key-file "$signing_key" \
            --label "$identity" \
            --description "$description" \
            --out "$out_path" \
            --vault-work-factor 1 \
            --vault-passphrase-fd 9
        exec 9<&-
    }
}

registry_stake_phase() {
    local run_dir=$1
    local phase_dir="$run_dir/phases/registry-stake"
    mkdir -p "$phase_dir"

    require_env CARDANO_NODE_SOCKET_PATH
    require_env CLI_SMOKE_FUNDING_ADDR
    require_env CLI_SMOKE_FUNDING_SKEY
    require_env CLI_SMOKE_FUNDING_KEY_HASH
    require_file "funding signing key" "$CLI_SMOKE_FUNDING_SKEY"

    AMARU_EXE=$(resolve_amaru_exe)
    log "registry-stake: using $AMARU_EXE"

    local metadata="test/fixtures/metadata.json"
    require_file "metadata fixture" "$metadata"

    local wallet_addr="$CLI_SMOKE_FUNDING_ADDR"
    log "registry-stake: funding wallet addr = $wallet_addr"

    local passphrase_file="$phase_dir/funding.passphrase"
    printf 'cli-smoke-registry-stake' >"$passphrase_file"
    chmod 0600 "$passphrase_file"

    local funding_vault="$phase_dir/funding.vault.age"
    log "registry-stake: create funding vault"
    {
        exec 9<"$passphrase_file"
        "$AMARU_EXE" --network devnet vault create \
            --signing-key-file "$CLI_SMOKE_FUNDING_SKEY" \
            --label devnet_funding \
            --description "DevNet funding key (registry-stake)" \
            --out "$funding_vault" \
            --vault-work-factor 1 \
            --vault-passphrase-fd 9
        exec 9<&-
    }

    local scope="core_development"
    local intents_dir="$phase_dir/intents"
    local diag_dir="$phase_dir/diagnostics"
    mkdir -p "$intents_dir" "$diag_dir"

    # --- T014: registry-init-wizard --bootstrap pipeline ---

    local seed_split_intent="$intents_dir/seed-split.intent.json"
    log "registry-stake: registry-init-wizard seed-split --bootstrap"
    "$AMARU_EXE" --network devnet \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        registry-init-wizard seed-split \
        --bootstrap \
        --wallet-addr "$wallet_addr" \
        --metadata "$metadata" \
        --scope "$scope" \
        --log "$diag_dir/seed-split.intent.log" \
        --out "$seed_split_intent"

    local seed_split_txid
    seed_split_txid=$(build_sign_submit \
        "seed-split" \
        "$seed_split_intent" \
        "$funding_vault" \
        "devnet_funding" \
        "$CLI_SMOKE_FUNDING_KEY_HASH" \
        "$passphrase_file") \
        || die "seed-split: build/sign/submit failed"

    # Derive scopes/registry/funding seed TxIns from the seed-split
    # tx-build report. Registry-init build runners do not currently
    # tag their walletChange output in BuildResult (the change role
    # comes out as "unknown" — see
    # lib/Amaru/Treasury/Build/RegistryInit.hs:brWalletChangeOutput
    # = Nothing). The contract of Cardano.Tx.Build.build appends the
    # change output last, so the highest-index output is the change
    # / funding seed and the remaining ones in declaration order are
    # the two explicit payTo outputs (scopes seed, registry seed).
    local seed_split_report="$run_dir/diagnostics/seed-split.report.json"
    local out_count
    out_count=$(jq -r '.result.report.outputs | length' \
        "$seed_split_report") \
        || die "seed-split: cannot read outputs from $seed_split_report"
    if [[ "$out_count" != "3" ]]; then
        die "seed-split: expected 3 outputs (2 seeds + change), got $out_count"
    fi
    local scopes_seed_txin="${seed_split_txid}#0"
    local registry_seed_txin="${seed_split_txid}#1"
    local funding_seed_txin="${seed_split_txid}#2"

    local mint_intent="$intents_dir/mint.intent.json"
    log "registry-stake: registry-init-wizard mint --bootstrap"
    "$AMARU_EXE" --network devnet \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        registry-init-wizard mint \
        --bootstrap \
        --wallet-addr "$wallet_addr" \
        --metadata "$metadata" \
        --scope "$scope" \
        --scopes-seed-txin "$scopes_seed_txin" \
        --registry-seed-txin "$registry_seed_txin" \
        --owner-key-hash "$CLI_SMOKE_FUNDING_KEY_HASH" \
        --log "$diag_dir/mint.intent.log" \
        --out "$mint_intent"

    local mint_txid
    mint_txid=$(build_sign_submit \
        "mint" \
        "$mint_intent" \
        "$funding_vault" \
        "devnet_funding" \
        "$CLI_SMOKE_FUNDING_KEY_HASH" \
        "$passphrase_file") \
        || die "mint: build/sign/submit failed"

    local refscripts_intent="$intents_dir/reference-scripts.intent.json"
    log "registry-stake: registry-init-wizard reference-scripts --bootstrap"
    "$AMARU_EXE" --network devnet \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        registry-init-wizard reference-scripts \
        --bootstrap \
        --wallet-addr "$wallet_addr" \
        --metadata "$metadata" \
        --scope "$scope" \
        --scopes-seed-txin "$scopes_seed_txin" \
        --registry-seed-txin "$registry_seed_txin" \
        --funding-seed-txin "$funding_seed_txin" \
        --log "$diag_dir/reference-scripts.intent.log" \
        --out "$refscripts_intent"

    local refscripts_txid
    refscripts_txid=$(build_sign_submit \
        "reference-scripts" \
        "$refscripts_intent" \
        "$funding_vault" \
        "devnet_funding" \
        "$CLI_SMOKE_FUNDING_KEY_HASH" \
        "$passphrase_file") \
        || die "reference-scripts: build/sign/submit failed"

    log "registry-stake: registry-init-wizard write-artifacts"
    "$AMARU_EXE" --network devnet \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        registry-init-wizard write-artifacts \
        --run-dir "$run_dir" \
        --seed-split-txid "$seed_split_txid" \
        --registry-mint-txid "$mint_txid" \
        --reference-scripts-txid "$refscripts_txid" \
        --scopes-seed-txin "$scopes_seed_txin" \
        --registry-seed-txin "$registry_seed_txin" \
        --owner-key-hash "$CLI_SMOKE_FUNDING_KEY_HASH"

    local registry_json="$run_dir/registry-init/registry.json"
    require_file "registry.json produced by write-artifacts" "$registry_json"

    # --- T015: stake-reward-init-wizard pipeline ---

    # The registry-init / stake-reward-init build runners do not tag
    # their walletChange output in the tx-build report (see comment
    # above the seed-split derivation). The change index is therefore
    # taken from each builder's known output ordering:
    #   - reference-scripts: permissions ref (#0), treasury ref (#1),
    #     change (#2);
    #   - script-account:    change only (#0);
    #   - plain-account:     change only (#0).
    # An output-count guard keeps the smoke honest if the builder
    # layout ever shifts.
    local refscripts_report="$run_dir/diagnostics/reference-scripts.report.json"
    local refscripts_out_count
    refscripts_out_count=$(jq -r \
        '.result.report.outputs | length' "$refscripts_report") \
        || die "reference-scripts: cannot read outputs"
    if [[ "$refscripts_out_count" != "3" ]]; then
        die "reference-scripts: expected 3 outputs (perms+treas+change), got $refscripts_out_count"
    fi
    local script_account_funding_txin="${refscripts_txid}#2"

    local script_account_intent="$intents_dir/stake-reward-script-account.intent.json"
    log "registry-stake: stake-reward-init-wizard script-account"
    "$AMARU_EXE" --network devnet \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        stake-reward-init-wizard script-account \
        --wallet-addr "$wallet_addr" \
        --registry "$registry_json" \
        --funding-seed-txin "$script_account_funding_txin" \
        --log "$diag_dir/stake-reward-script-account.intent.log" \
        --out "$script_account_intent"

    local script_account_txid
    script_account_txid=$(build_sign_submit \
        "stake-reward-script-account" \
        "$script_account_intent" \
        "$funding_vault" \
        "devnet_funding" \
        "$CLI_SMOKE_FUNDING_KEY_HASH" \
        "$passphrase_file") \
        || die "stake-reward-script-account: build/sign/submit failed"

    local script_account_report="$run_dir/diagnostics/stake-reward-script-account.report.json"
    local script_account_out_count
    script_account_out_count=$(jq -r \
        '.result.report.outputs | length' "$script_account_report") \
        || die "stake-reward-script-account: cannot read outputs"
    if [[ "$script_account_out_count" != "1" ]]; then
        die "stake-reward-script-account: expected 1 output (change), got $script_account_out_count"
    fi
    local plain_account_funding_txin="${script_account_txid}#0"

    local plain_account_intent="$intents_dir/stake-reward-plain-account.intent.json"
    log "registry-stake: stake-reward-init-wizard plain-account"
    "$AMARU_EXE" --network devnet \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        stake-reward-init-wizard plain-account \
        --wallet-addr "$wallet_addr" \
        --registry "$registry_json" \
        --funding-seed-txin "$plain_account_funding_txin" \
        --log "$diag_dir/stake-reward-plain-account.intent.log" \
        --out "$plain_account_intent"

    local plain_account_txid
    plain_account_txid=$(build_sign_submit \
        "stake-reward-plain-account" \
        "$plain_account_intent" \
        "$funding_vault" \
        "devnet_funding" \
        "$CLI_SMOKE_FUNDING_KEY_HASH" \
        "$passphrase_file") \
        || die "stake-reward-plain-account: build/sign/submit failed"

    # Derive accounts.json from the shipped registry.json plus the two
    # submitted stake-reward tx ids. Input is Amaru-owned (registry.json
    # is the write-artifacts output); no external node-CLI fallback and
    # no in-process runner. Both reward accounts are scripted on DevNet,
    # so the rewardAccount and scriptHash fields collapse to the same
    # hex under dsraScriptHash/dsraRewardAccount (mirrors the library
    # accountValue projection). The top-level artifact network stays as
    # the operator label ("devnet"), while ledgerNetwork carries the
    # ledger constructor text expected by the governance reader.
    local accounts_dir="$run_dir/stake-reward-init"
    mkdir -p "$accounts_dir"
    local accounts_json="$accounts_dir/accounts.json"
    jq -n \
        --slurpfile reg "$registry_json" \
        --arg scriptAccountTxId "$script_account_txid" \
        --arg plainAccountTxId "$plain_account_txid" \
        '{
            phase: "stake-reward-init",
            network: "devnet",
            accounts: {
                treasury: {
                    scriptHash: $reg[0].scripts.treasuryScriptHash,
                    rewardAccount: $reg[0].scripts.treasuryScriptHash,
                    ledgerNetwork: "Testnet",
                    registered: true,
                    rewardsLovelace: 0,
                    setupTxId: $scriptAccountTxId
                },
                permissions: {
                    scriptHash: $reg[0].scripts.permissionsScriptHash,
                    rewardAccount: $reg[0].scripts.permissionsScriptHash,
                    ledgerNetwork: "Testnet",
                    registered: true,
                    rewardsLovelace: 0,
                    setupTxId: $plainAccountTxId
                }
            }
        }' >"$accounts_json"

    # --- T016: chain-assertion request handoff to the host ---
    #
    # The host owns chain queries (it already brought DevNet up). The
    # smoke writes a request listing every anchor TxIn and reward
    # account the host must verify; the host runs the assertions after
    # this script exits successfully and writes
    # chain/assertions.{json,log} under the run-dir.
    local chain_dir="$run_dir/chain"
    mkdir -p "$chain_dir"
    local assert_request="$chain_dir/assertions.request.json"
    jq -n \
        --slurpfile reg "$registry_json" \
        --slurpfile acc "$accounts_json" \
        --arg seedSplitTxId "$seed_split_txid" \
        --arg registryMintTxId "$mint_txid" \
        --arg referenceScriptsTxId "$refscripts_txid" \
        --arg scriptAccountTxId "$script_account_txid" \
        --arg plainAccountTxId "$plain_account_txid" \
        '{
            phase: "registry-stake",
            anchors: {
                scopesDeployedAt:
                    $reg[0].anchors.scopesDeployedAt,
                registryDeployedAt:
                    $reg[0].anchors.registryDeployedAt,
                permissionsDeployedAt:
                    $reg[0].anchors.permissionsDeployedAt,
                treasuryDeployedAt:
                    $reg[0].anchors.treasuryDeployedAt
            },
            rewardAccounts: {
                treasury: $acc[0].accounts.treasury.rewardAccount,
                permissions:
                    $acc[0].accounts.permissions.rewardAccount
            },
            submittedTxIds: {
                seedSplit: $seedSplitTxId,
                registryMint: $registryMintTxId,
                referenceScripts: $referenceScriptsTxId,
                stakeRewardScriptAccount: $scriptAccountTxId,
                stakeRewardPlainAccount: $plainAccountTxId
            }
        }' >"$assert_request"

    cat >"$phase_dir/summary.json" <<JSON
{
  "phase": "registry-stake",
  "scope": "$scope",
  "status": "ok",
  "seedSplitTxId": "$seed_split_txid",
  "registryMintTxId": "$mint_txid",
  "referenceScriptsTxId": "$refscripts_txid",
  "stakeRewardScriptAccountTxId": "$script_account_txid",
  "stakeRewardPlainAccountTxId": "$plain_account_txid",
  "registryJson": "$registry_json",
  "accountsJson": "$accounts_json",
  "chainAssertionsRequest": "$assert_request"
}
JSON
    log "registry-stake: complete (summary in $phase_dir/summary.json)"
}

governance_phase() {
    local run_dir=$1
    local timeout_seconds=$2
    local phase_dir="$run_dir/phases/governance"
    mkdir -p "$phase_dir"

    registry_stake_phase "$run_dir"

    require_env CARDANO_NODE_SOCKET_PATH
    require_env CLI_SMOKE_FUNDING_ADDR
    require_env CLI_SMOKE_FUNDING_SKEY
    require_env CLI_SMOKE_FUNDING_KEY_HASH
    require_env CLI_SMOKE_VOTER_SKEY
    require_env CLI_SMOKE_VOTER_KEY_HASH
    require_file "funding signing key" "$CLI_SMOKE_FUNDING_SKEY"
    require_file "voter signing key" "$CLI_SMOKE_VOTER_SKEY"

    AMARU_EXE=$(resolve_amaru_exe)
    log "governance: using $AMARU_EXE"

    local registry_json="$run_dir/registry-init/registry.json"
    local accounts_json="$run_dir/stake-reward-init/accounts.json"
    local registry_summary="$run_dir/phases/registry-stake/summary.json"
    require_file "registry.json" "$registry_json"
    require_file "accounts.json" "$accounts_json"
    require_file "registry-stake summary" "$registry_summary"

    local proposal_funding_seed_txin
    proposal_funding_seed_txin="$(jq -r \
        '.stakeRewardPlainAccountTxId + "#0"' "$registry_summary")" \
        || die "governance: cannot read proposal funding seed"
    if [[ "$proposal_funding_seed_txin" == "null#0" ]]; then
        die "governance: registry-stake summary missing stakeRewardPlainAccountTxId"
    fi

    local passphrase_file="$phase_dir/governance.passphrase"
    printf 'cli-smoke-governance' >"$passphrase_file"
    chmod 0600 "$passphrase_file"

    local funding_vault="$phase_dir/funding.vault.age"
    local voter_vault="$phase_dir/voter.vault.age"
    log "governance: create funding vault"
    create_devnet_vault \
        "$CLI_SMOKE_FUNDING_SKEY" \
        "devnet_funding" \
        "DevNet funding key (governance)" \
        "$funding_vault" \
        "$passphrase_file"
    log "governance: create voter vault"
    create_devnet_vault \
        "$CLI_SMOKE_VOTER_SKEY" \
        "devnet_voter" \
        "DevNet voter key (governance)" \
        "$voter_vault" \
        "$passphrase_file"

    local intents_dir="$phase_dir/intents"
    local diag_dir="$phase_dir/diagnostics"
    mkdir -p "$intents_dir" "$diag_dir"

    local proposal_intent="$intents_dir/proposal.intent.json"
    log "governance: governance-withdrawal-init-wizard proposal"
    "$AMARU_EXE" --network devnet \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        governance-withdrawal-init-wizard proposal \
        --wallet-addr "$CLI_SMOKE_FUNDING_ADDR" \
        --registry "$registry_json" \
        --stake-reward-accounts "$accounts_json" \
        --funding-seed-txin "$proposal_funding_seed_txin" \
        --funding-stake-key-hash "$CLI_SMOKE_FUNDING_KEY_HASH" \
        --voter-key-hash "$CLI_SMOKE_VOTER_KEY_HASH" \
        --withdrawal-amount-lovelace "$GOVERNANCE_WITHDRAWAL_LOVELACE" \
        --anchor-url "$GOVERNANCE_ANCHOR_URL" \
        --anchor-hash "$GOVERNANCE_ANCHOR_HASH" \
        --log "$diag_dir/proposal.intent.log" \
        --force \
        --out "$proposal_intent"

    local proposal_txid
    proposal_txid=$(build_sign_submit_multi \
        "governance-proposal" \
        "$proposal_intent" \
        "$passphrase_file" \
        "$funding_vault" \
        "devnet_funding" \
        "$CLI_SMOKE_FUNDING_KEY_HASH" \
        "$voter_vault" \
        "devnet_voter" \
        "$CLI_SMOKE_VOTER_KEY_HASH") \
        || die "governance-proposal: build/sign/submit failed"

    local proposal_report="$run_dir/diagnostics/governance-proposal.report.json"
    local proposal_out_count
    proposal_out_count=$(jq -r '.result.report.outputs | length' \
        "$proposal_report") \
        || die "governance-proposal: cannot read outputs"
    if [[ "$proposal_out_count" != "2" ]]; then
        die "governance-proposal: expected 2 outputs (voter + change), got $proposal_out_count"
    fi

    # Governance proposal output roles remain "unknown" in the
    # tx-build report because the governance build runner does not
    # currently tag brWalletChangeOutput. The underlying builder emits
    # the declared payTo voterBaseAddr output first and appends wallet
    # change last, so #0 is the voter base UTxO and #1 is the funding
    # change carried forward for materialization. The output-count guard
    # above catches layout drift before this convention can go stale.
    local voter_base_txin="${proposal_txid}#0"
    local materialization_funding_seed_txin="${proposal_txid}#1"
    local voter_base_address
    local voter_base_lovelace
    voter_base_address=$(jq -r '.result.report.outputs[0].address' \
        "$proposal_report") \
        || die "governance-proposal: cannot read voter output address"
    voter_base_lovelace=$(jq -r '.result.report.outputs[0].value.lovelace' \
        "$proposal_report") \
        || die "governance-proposal: cannot read voter output lovelace"

    local treasury_reward_account
    treasury_reward_account=$(jq -r '.accounts.treasury.rewardAccount' \
        "$accounts_json") \
        || die "governance: cannot read treasury reward account"
    if [[ -z "$treasury_reward_account" || "$treasury_reward_account" == "null" ]]; then
        die "governance: accounts.json missing treasury reward account"
    fi

    local governance_action_id="${proposal_txid}#0"
    local chain_dir="$run_dir/chain"
    mkdir -p "$chain_dir"
    local gov_request="$chain_dir/governance.assertions.request.json"
    jq -n \
        --arg proposalTxId "$proposal_txid" \
        --arg governanceActionId "$governance_action_id" \
        --arg proposalFundingSeedTxIn "$proposal_funding_seed_txin" \
        --arg materializationFundingSeedTxIn "$materialization_funding_seed_txin" \
        --arg voterBaseTxIn "$voter_base_txin" \
        --arg voterBaseAddress "$voter_base_address" \
        --argjson voterBaseLovelace "$voter_base_lovelace" \
        --arg treasuryRewardAccount "$treasury_reward_account" \
        --argjson expectedRewardLovelace "$GOVERNANCE_WITHDRAWAL_LOVELACE" \
        --argjson timeoutSeconds "$timeout_seconds" \
        --arg anchorUrl "$GOVERNANCE_ANCHOR_URL" \
        --arg anchorHash "$GOVERNANCE_ANCHOR_HASH" \
        '{
            phase: "governance",
            status: "proposal-submitted",
            proposalTxId: $proposalTxId,
            governanceActionId: $governanceActionId,
            proposalFundingSeedTxIn: $proposalFundingSeedTxIn,
            materializationFundingSeedTxIn: $materializationFundingSeedTxIn,
            voterBaseOutput: {
                txIn: $voterBaseTxIn,
                address: $voterBaseAddress,
                lovelace: $voterBaseLovelace
            },
            treasuryRewardAccount: $treasuryRewardAccount,
            expectedRewardLovelace: $expectedRewardLovelace,
            rewardPollTimeoutSeconds: $timeoutSeconds,
            anchor: {
                url: $anchorUrl,
                hash: $anchorHash
            }
        }' >"$gov_request"

    local materialization_intent="$intents_dir/materialization.intent.json"
    local materialization_txid=""
    local materialization_deadline=$((SECONDS + timeout_seconds))
    local materialization_attempt=1
    while [[ -z "$materialization_txid" && "$SECONDS" -lt "$materialization_deadline" ]]; do
        log "governance: governance-withdrawal-init-wizard materialization (attempt $materialization_attempt)"
        "$AMARU_EXE" --network devnet \
            --node-socket "$CARDANO_NODE_SOCKET_PATH" \
            governance-withdrawal-init-wizard materialization \
            --wallet-addr "$CLI_SMOKE_FUNDING_ADDR" \
            --registry "$registry_json" \
            --stake-reward-accounts "$accounts_json" \
            --funding-seed-txin "$materialization_funding_seed_txin" \
            --rewards-lovelace "$GOVERNANCE_WITHDRAWAL_LOVELACE" \
            --log "$diag_dir/materialization.intent.log" \
            --force \
            --out "$materialization_intent"

        if materialization_txid=$(build_sign_submit \
            "governance-materialization" \
            "$materialization_intent" \
            "$funding_vault" \
            "devnet_funding" \
            "$CLI_SMOKE_FUNDING_KEY_HASH" \
            "$passphrase_file"); then
            break
        fi
        log "governance-materialization: not accepted yet; retrying after reward settlement"
        materialization_txid=""
        materialization_attempt=$((materialization_attempt + 1))
        sleep 2
    done
    if [[ -z "$materialization_txid" ]]; then
        die "governance-materialization: build/sign/submit failed before timeout"
    fi

    local materialization_report="$run_dir/diagnostics/governance-materialization.report.json"
    local materialization_out_count
    materialization_out_count=$(jq -r '.result.report.outputs | length' \
        "$materialization_report") \
        || die "governance-materialization: cannot read outputs"
    if [[ "$materialization_out_count" != "2" ]]; then
        die "governance-materialization: expected 2 outputs (treasury + change), got $materialization_out_count"
    fi

    # Materialization mirrors the proposal output convention: the
    # declared treasury payTo output is emitted first and wallet change
    # is appended last. The build runner leaves roles as "unknown", so
    # the count guard above protects the #0 treasury / #1 change split.
    local treasury_materialized_txin="${materialization_txid}#0"
    local materialization_change_txin="${materialization_txid}#1"
    local treasury_materialized_address
    local treasury_materialized_lovelace
    treasury_materialized_address=$(jq -r '.result.report.outputs[0].address' \
        "$materialization_report") \
        || die "governance-materialization: cannot read treasury output address"
    treasury_materialized_lovelace=$(jq -r \
        '.result.report.outputs[0].value.lovelace' \
        "$materialization_report") \
        || die "governance-materialization: cannot read treasury output lovelace"
    if [[ "$treasury_materialized_lovelace" != "$GOVERNANCE_WITHDRAWAL_LOVELACE" ]]; then
        die "governance-materialization: expected treasury output $GOVERNANCE_WITHDRAWAL_LOVELACE lovelace, got $treasury_materialized_lovelace"
    fi

    local materialized_dir="$run_dir/governance-withdrawal-init"
    mkdir -p "$materialized_dir"
    local materialized_json="$materialized_dir/materialized.json"
    jq -n \
        --arg governanceActionId "$governance_action_id" \
        --arg treasuryRewardAccount "$treasury_reward_account" \
        --arg submittedTxId "$materialization_txid" \
        --arg treasuryMaterializedTxIn "$treasury_materialized_txin" \
        --arg treasuryAddress "$treasury_materialized_address" \
        --argjson materializedAdaLovelace "$treasury_materialized_lovelace" \
        --arg registryPath "$registry_json" \
        --arg stakeRewardPath "$accounts_json" \
        '{
            phase: "governance-withdrawal-init",
            network: "devnet",
            governanceActionId: $governanceActionId,
            treasuryRewardAccount: $treasuryRewardAccount,
            submittedTxId: $submittedTxId,
            treasuryMaterializedTxIn: $treasuryMaterializedTxIn,
            treasuryAddress: $treasuryAddress,
            materializedAdaLovelace: $materializedAdaLovelace,
            registryPath: $registryPath,
            stakeRewardPath: $stakeRewardPath
        }' >"$materialized_json"

    jq -n \
        --arg proposalTxId "$proposal_txid" \
        --arg governanceActionId "$governance_action_id" \
        --arg proposalFundingSeedTxIn "$proposal_funding_seed_txin" \
        --arg materializationFundingSeedTxIn "$materialization_funding_seed_txin" \
        --arg voterBaseTxIn "$voter_base_txin" \
        --arg voterBaseAddress "$voter_base_address" \
        --argjson voterBaseLovelace "$voter_base_lovelace" \
        --arg treasuryRewardAccount "$treasury_reward_account" \
        --argjson expectedRewardLovelace "$GOVERNANCE_WITHDRAWAL_LOVELACE" \
        --argjson timeoutSeconds "$timeout_seconds" \
        --arg anchorUrl "$GOVERNANCE_ANCHOR_URL" \
        --arg anchorHash "$GOVERNANCE_ANCHOR_HASH" \
        --arg materializationTxId "$materialization_txid" \
        --arg treasuryMaterializedTxIn "$treasury_materialized_txin" \
        --arg treasuryAddress "$treasury_materialized_address" \
        --argjson materializedAdaLovelace "$treasury_materialized_lovelace" \
        --arg materializationChangeTxIn "$materialization_change_txin" \
        --arg materializedJson "$materialized_json" \
        '{
            phase: "governance",
            status: "materialization-submitted",
            proposalTxId: $proposalTxId,
            governanceActionId: $governanceActionId,
            proposalFundingSeedTxIn: $proposalFundingSeedTxIn,
            materializationFundingSeedTxIn: $materializationFundingSeedTxIn,
            voterBaseOutput: {
                txIn: $voterBaseTxIn,
                address: $voterBaseAddress,
                lovelace: $voterBaseLovelace
            },
            treasuryRewardAccount: $treasuryRewardAccount,
            expectedRewardLovelace: $expectedRewardLovelace,
            rewardPollTimeoutSeconds: $timeoutSeconds,
            anchor: {
                url: $anchorUrl,
                hash: $anchorHash
            },
            materialization: {
                txId: $materializationTxId,
                treasuryMaterializedTxIn: $treasuryMaterializedTxIn,
                treasuryAddress: $treasuryAddress,
                materializedAdaLovelace: $materializedAdaLovelace,
                materializationChangeTxIn: $materializationChangeTxIn,
                materializedJson: $materializedJson
            }
        }' >"$gov_request"

    jq -n \
        --arg registryPath "$registry_json" \
        --arg stakeRewardPath "$accounts_json" \
        --arg governancePath "$materialized_dir/governance.json" \
        --arg withdrawalPath "$materialized_dir/withdrawal.json" \
        --arg materializationPath "$materialized_json" \
        --arg proposalTxId "$proposal_txid" \
        --arg governanceActionId "$governance_action_id" \
        --arg materializationTxId "$materialization_txid" \
        --argjson amountLovelace "$GOVERNANCE_WITHDRAWAL_LOVELACE" \
        '{
            phase: "governance-withdrawal-init",
            status: "passed",
            network: "devnet",
            registryPath: $registryPath,
            stakeRewardPath: $stakeRewardPath,
            amountLovelace: $amountLovelace,
            proposalTxId: $proposalTxId,
            governanceActionId: $governanceActionId,
            materializationTxId: $materializationTxId,
            governancePath: $governancePath,
            withdrawalPath: $withdrawalPath,
            materializationPath: $materializationPath
        }' >"$materialized_dir/summary.json"

    cat >"$phase_dir/summary.json" <<JSON
{
  "phase": "governance",
  "status": "materialization-submitted",
  "proposalTxId": "$proposal_txid",
  "governanceActionId": "$governance_action_id",
  "proposalFundingSeedTxIn": "$proposal_funding_seed_txin",
  "materializationFundingSeedTxIn": "$materialization_funding_seed_txin",
  "voterBaseTxIn": "$voter_base_txin",
  "voterBaseAddress": "$voter_base_address",
  "voterBaseLovelace": $voter_base_lovelace,
  "treasuryRewardAccount": "$treasury_reward_account",
  "expectedRewardLovelace": $GOVERNANCE_WITHDRAWAL_LOVELACE,
  "materializationTxId": "$materialization_txid",
  "treasuryMaterializedTxIn": "$treasury_materialized_txin",
  "treasuryMaterializedAddress": "$treasury_materialized_address",
  "treasuryMaterializedLovelace": $treasury_materialized_lovelace,
  "materializedJson": "$materialized_json",
  "proposalIntent": "$proposal_intent",
  "materializationIntent": "$materialization_intent",
  "chainAssertionsRequest": "$gov_request"
}
JSON
    log "governance: materialization submitted; host will verify chain state"
}

disburse_phase() {
    local run_dir=$1
    local timeout_seconds=$2
    local phase_dir="$run_dir/phases/disburse"
    mkdir -p "$phase_dir"

    governance_phase "$run_dir" "$timeout_seconds"

    require_env CARDANO_NODE_SOCKET_PATH
    require_env CLI_SMOKE_FUNDING_ADDR
    require_env CLI_SMOKE_FUNDING_SKEY
    require_env CLI_SMOKE_FUNDING_KEY_HASH
    require_env CLI_SMOKE_BENEFICIARY_ADDR
    require_file "funding signing key" "$CLI_SMOKE_FUNDING_SKEY"

    AMARU_EXE=$(resolve_amaru_exe)
    log "disburse: using $AMARU_EXE"

    local registry_json="$run_dir/registry-init/registry.json"
    local materialized_json="$run_dir/governance-withdrawal-init/materialized.json"
    local governance_summary="$run_dir/phases/governance/summary.json"
    require_file "registry.json" "$registry_json"
    require_file "governance materialization" "$materialized_json"
    require_file "governance summary" "$governance_summary"

    local materialized_lovelace
    materialized_lovelace=$(jq -r '.materializedAdaLovelace' \
        "$materialized_json") \
        || die "disburse: cannot read materialized lovelace"
    if [[ "$materialized_lovelace" -le "$DISBURSE_LOVELACE" ]]; then
        die "disburse: materialized lovelace $materialized_lovelace must exceed disburse amount $DISBURSE_LOVELACE"
    fi
    local treasury_leftover_lovelace=$((materialized_lovelace - DISBURSE_LOVELACE))

    local treasury_input
    local treasury_address
    treasury_input=$(jq -r '.treasuryMaterializedTxIn' \
        "$materialized_json") \
        || die "disburse: cannot read treasury input"
    treasury_address=$(jq -r '.treasuryAddress' "$materialized_json") \
        || die "disburse: cannot read treasury address"
    if [[ -z "$treasury_input" || "$treasury_input" == "null" ]]; then
        die "disburse: materialized.json missing treasuryMaterializedTxIn"
    fi
    if [[ -z "$treasury_address" || "$treasury_address" == "null" ]]; then
        die "disburse: materialized.json missing treasuryAddress"
    fi

    local passphrase_file="$phase_dir/disburse.passphrase"
    printf 'cli-smoke-disburse' >"$passphrase_file"
    chmod 0600 "$passphrase_file"

    local funding_vault="$phase_dir/funding.vault.age"
    log "disburse: create funding vault"
    create_devnet_vault \
        "$CLI_SMOKE_FUNDING_SKEY" \
        "devnet_funding" \
        "DevNet funding key (disburse)" \
        "$funding_vault" \
        "$passphrase_file"

    local intents_dir="$phase_dir/intents"
    local diag_dir="$phase_dir/diagnostics"
    mkdir -p "$intents_dir" "$diag_dir"

    local disburse_submit_dir="$run_dir/disburse-submit"
    mkdir -p "$disburse_submit_dir"
    local metadata="$disburse_submit_dir/metadata.json"
    jq -n \
        --slurpfile reg "$registry_json" \
        --argjson budget "$materialized_lovelace" \
        '{
            scope_owners: $reg[0].anchors.scopesDeployedAt,
            treasuries: {
                core_development: {
                    owner: $reg[0].owners.scopeOwnerKeyHash,
                    budget: $budget,
                    address: $reg[0].addresses.treasuryAddress,
                    treasury_script: {
                        hash: $reg[0].scripts.treasuryScriptHash,
                        deployed_at: $reg[0].anchors.treasuryDeployedAt
                    },
                    permissions_script: {
                        hash: $reg[0].scripts.permissionsScriptHash,
                        deployed_at: $reg[0].anchors.permissionsDeployedAt
                    },
                    registry_script: {
                        hash: $reg[0].policies.registryPolicyId,
                        deployed_at: $reg[0].anchors.registryDeployedAt
                    }
                }
            }
        }' >"$metadata"

    local disburse_intent="$intents_dir/disburse.intent.json"
    log "disburse: disburse-wizard"
    "$AMARU_EXE" --network devnet \
        --node-socket "$CARDANO_NODE_SOCKET_PATH" \
        disburse-wizard \
        --wallet-addr "$CLI_SMOKE_FUNDING_ADDR" \
        --metadata "$metadata" \
        --scope core_development \
        --treasury-txin "$treasury_input" \
        --unit ada \
        --amount "$DISBURSE_LOVELACE" \
        --beneficiary-addr "$CLI_SMOKE_BENEFICIARY_ADDR" \
        --description "CLI DevNet smoke beneficiary payment" \
        --justification "Issue 161 disburse-after-materialization proof" \
        --destination-label "CLI smoke beneficiary" \
        --log "$diag_dir/disburse.intent.log" \
        --out "$disburse_intent"

    local disburse_txid
    disburse_txid=$(build_sign_submit \
        "disburse-submit" \
        "$disburse_intent" \
        "$funding_vault" \
        "devnet_funding" \
        "$CLI_SMOKE_FUNDING_KEY_HASH" \
        "$passphrase_file") \
        || die "disburse-submit: build/sign/submit failed"

    local disburse_report="$run_dir/diagnostics/disburse-submit.report.json"
    local summary_json="$disburse_submit_dir/summary.json"
    local disburse_json="$disburse_submit_dir/disburse.json"
    local beneficiary_json="$disburse_submit_dir/beneficiary.json"
    local treasury_json="$disburse_submit_dir/treasury.json"
    local provenance_json="$disburse_submit_dir/provenance.json"
    local tx_body="$run_dir/unsigned/disburse-submit.cbor.hex"
    local signed_tx="$run_dir/signed/disburse-submit.signed.cbor.hex"
    local submit_log="$run_dir/submits/disburse-submit.outcome"

    local out_count
    out_count=$(jq -r '.result.report.outputs | length' \
        "$disburse_report") \
        || die "disburse-submit: cannot read outputs"
    if [[ "$out_count" != "3" ]]; then
        die "disburse-submit: expected 3 outputs (treasury + beneficiary + wallet change), got $out_count"
    fi

    local treasury_output_txin="${disburse_txid}#0"
    local beneficiary_txin="${disburse_txid}#1"
    local wallet_change_txin="${disburse_txid}#2"
    local observed_treasury_address
    local observed_treasury_lovelace
    local observed_beneficiary_address
    local observed_beneficiary_lovelace
    local fee_lovelace
    observed_treasury_address=$(jq -r \
        '.result.report.outputs[0].address' "$disburse_report") \
        || die "disburse-submit: cannot read treasury output address"
    observed_treasury_lovelace=$(jq -r \
        '.result.report.outputs[0].value.lovelace' "$disburse_report") \
        || die "disburse-submit: cannot read treasury output lovelace"
    observed_beneficiary_address=$(jq -r \
        '.result.report.outputs[1].address' "$disburse_report") \
        || die "disburse-submit: cannot read beneficiary output address"
    observed_beneficiary_lovelace=$(jq -r \
        '.result.report.outputs[1].value.lovelace' "$disburse_report") \
        || die "disburse-submit: cannot read beneficiary output lovelace"
    fee_lovelace=$(jq -r '.result.report.identity.feeLovelace' \
        "$disburse_report") \
        || die "disburse-submit: cannot read fee"

    if [[ "$observed_treasury_address" != "$treasury_address" ]]; then
        die "disburse-submit: treasury output address mismatch"
    fi
    if [[ "$observed_treasury_lovelace" != "$treasury_leftover_lovelace" ]]; then
        die "disburse-submit: expected treasury leftover $treasury_leftover_lovelace lovelace, got $observed_treasury_lovelace"
    fi
    if [[ "$observed_beneficiary_address" != "$CLI_SMOKE_BENEFICIARY_ADDR" ]]; then
        die "disburse-submit: beneficiary output address mismatch"
    fi
    if [[ "$observed_beneficiary_lovelace" != "$DISBURSE_LOVELACE" ]]; then
        die "disburse-submit: expected beneficiary $DISBURSE_LOVELACE lovelace, got $observed_beneficiary_lovelace"
    fi

    jq -n \
        --arg intentPath "$disburse_intent" \
        --arg txBodyPath "$tx_body" \
        --arg reportJsonPath "$disburse_report" \
        --arg reportMarkdownPath "" \
        --arg signedTxPath "$signed_tx" \
        --arg submitLogPath "$submit_log" \
        --arg txId "$disburse_txid" \
        --argjson amountLovelace "$DISBURSE_LOVELACE" \
        --argjson feeLovelace "$fee_lovelace" \
        '{
            phase: "disburse-submit",
            network: "devnet",
            intentPath: $intentPath,
            txBodyPath: $txBodyPath,
            reportJsonPath: $reportJsonPath,
            reportMarkdownPath: $reportMarkdownPath,
            signedTxPath: $signedTxPath,
            submitLogPath: $submitLogPath,
            txId: $txId,
            submittedTxId: $txId,
            amountLovelace: $amountLovelace,
            feeLovelace: $feeLovelace
        }' >"$disburse_json"

    jq -n \
        --arg address "$CLI_SMOKE_BENEFICIARY_ADDR" \
        --arg txIn "$beneficiary_txin" \
        --argjson lovelace "$DISBURSE_LOVELACE" \
        '{
            phase: "disburse-submit",
            network: "devnet",
            address: $address,
            txIn: $txIn,
            lovelace: $lovelace
        }' >"$beneficiary_json"

    jq -n \
        --arg input "$treasury_input" \
        --arg output "$treasury_output_txin" \
        --arg address "$treasury_address" \
        --argjson lovelaceBefore "$materialized_lovelace" \
        --argjson lovelaceAfter "$treasury_leftover_lovelace" \
        '{
            phase: "disburse-submit",
            network: "devnet",
            input: $input,
            output: $output,
            address: $address,
            lovelaceBefore: $lovelaceBefore,
            lovelaceAfter: $lovelaceAfter,
            consumed: true
        }' >"$treasury_json"

    jq -n \
        '{
            phase: "disburse-submit",
            source: "amaru-treasury-tx",
            issue: 161,
            dependsOnIssues: [147, 149, 150, 151]
        }' >"$provenance_json"

    local chain_dir="$run_dir/chain"
    mkdir -p "$chain_dir"
    local disburse_request="$chain_dir/disburse.assertions.request.json"
    jq -n \
        --arg disburseTxId "$disburse_txid" \
        --arg treasuryInput "$treasury_input" \
        --arg treasuryOutputTxIn "$treasury_output_txin" \
        --arg treasuryAddress "$treasury_address" \
        --argjson treasuryOutputLovelace "$treasury_leftover_lovelace" \
        --arg beneficiaryTxIn "$beneficiary_txin" \
        --arg beneficiaryAddress "$CLI_SMOKE_BENEFICIARY_ADDR" \
        --argjson beneficiaryLovelace "$DISBURSE_LOVELACE" \
        '{
            phase: "disburse-submit",
            disburseTxId: $disburseTxId,
            treasuryInput: $treasuryInput,
            treasuryOutputTxIn: $treasuryOutputTxIn,
            treasuryAddress: $treasuryAddress,
            treasuryOutputLovelace: $treasuryOutputLovelace,
            beneficiaryTxIn: $beneficiaryTxIn,
            beneficiaryAddress: $beneficiaryAddress,
            beneficiaryLovelace: $beneficiaryLovelace
        }' >"$disburse_request"

    jq -n \
        --arg runDirectory "$run_dir" \
        --arg registryPath "$registry_json" \
        --arg materializedPath "$materialized_json" \
        --arg disbursePath "$disburse_json" \
        --arg beneficiaryPath "$beneficiary_json" \
        --arg treasuryPath "$treasury_json" \
        --arg provenancePath "$provenance_json" \
        --arg disburseIntent "$disburse_intent" \
        --arg disburseTxId "$disburse_txid" \
        --arg beneficiaryTxIn "$beneficiary_txin" \
        --arg walletChangeTxIn "$wallet_change_txin" \
        --arg treasuryInput "$treasury_input" \
        --arg treasuryOutputTxIn "$treasury_output_txin" \
        --arg chainAssertionsRequest "$disburse_request" \
        --argjson amountLovelace "$DISBURSE_LOVELACE" \
        '{
            phase: "disburse-submit",
            status: "passed",
            network: "devnet",
            runDirectory: $runDirectory,
            registryPath: $registryPath,
            materializedPath: $materializedPath,
            amountLovelace: $amountLovelace,
            disbursePath: $disbursePath,
            beneficiaryPath: $beneficiaryPath,
            treasuryPath: $treasuryPath,
            provenancePath: $provenancePath,
            disburseIntent: $disburseIntent,
            disburseTxId: $disburseTxId,
            beneficiaryTxIn: $beneficiaryTxIn,
            walletChangeTxIn: $walletChangeTxIn,
            treasuryInput: $treasuryInput,
            treasuryOutputTxIn: $treasuryOutputTxIn,
            chainAssertionsRequest: $chainAssertionsRequest
        }' >"$summary_json"

    cp "$summary_json" "$phase_dir/summary.json"
    log "disburse: complete (summary in $summary_json)"
}

write_full_summary() {
    local run_dir=$1
    local summary_path="$run_dir/summary.json"
    local registry_summary="$run_dir/phases/registry-stake/summary.json"
    local governance_summary="$run_dir/phases/governance/summary.json"
    local disburse_summary="$run_dir/disburse-submit/summary.json"
    require_file "registry-stake summary" "$registry_summary"
    require_file "governance summary" "$governance_summary"
    require_file "disburse summary" "$disburse_summary"
    jq -n \
        --arg registrySummary "$registry_summary" \
        --arg governanceSummary "$governance_summary" \
        --arg disburseSummary "$disburse_summary" \
        --arg runDir "$run_dir" \
        --arg socketPath "${CARDANO_NODE_SOCKET_PATH:-}" \
        '{
            phase: "full",
            status: "passed",
            registrySummary: $registrySummary,
            governanceSummary: $governanceSummary,
            disburseSummary: $disburseSummary,
            runDir: $runDir,
            socketPath: $socketPath,
            verificationStatus: "pending-host-assertions"
        }' >"$summary_path"
    log "full: summary written to $summary_path"
}

full_phase() {
    local run_dir=$1
    local timeout_seconds=$2
    disburse_phase "$run_dir" "$timeout_seconds"
    write_full_summary "$run_dir"
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
            require_inside_devnet "$inside_devnet" "$phase" \
                "$run_dir" "$timeout_seconds" "$force"
            vault_preflight "$run_dir"
            ;;
        registry-stake)
            require_inside_devnet "$inside_devnet" "$phase" \
                "$run_dir" "$timeout_seconds" "$force"
            registry_stake_phase "$run_dir"
            ;;
        governance)
            require_inside_devnet "$inside_devnet" "$phase" \
                "$run_dir" "$timeout_seconds" "$force"
            governance_phase "$run_dir" "$timeout_seconds"
            ;;
        disburse)
            require_inside_devnet "$inside_devnet" "$phase" \
                "$run_dir" "$timeout_seconds" "$force"
            disburse_phase "$run_dir" "$timeout_seconds"
            ;;
        full)
            require_inside_devnet "$inside_devnet" "$phase" \
                "$run_dir" "$timeout_seconds" "$force"
            full_phase "$run_dir" "$timeout_seconds"
            ;;
    esac
}

main "$@"
