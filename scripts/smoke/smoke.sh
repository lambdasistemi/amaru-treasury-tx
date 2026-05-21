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
AMARU_EXE=""
CLI_SMOKE_REGISTRY_TIMEOUT_SECONDS="${CLI_SMOKE_REGISTRY_TIMEOUT_SECONDS:-60}"

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
    # accountValue projection).
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
                    ledgerNetwork: $reg[0].network,
                    registered: true,
                    rewardsLovelace: 0,
                    setupTxId: $scriptAccountTxId
                },
                permissions: {
                    scriptHash: $reg[0].scripts.permissionsScriptHash,
                    rewardAccount: $reg[0].scripts.permissionsScriptHash,
                    ledgerNetwork: $reg[0].network,
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
        governance | disburse | full)
            die "phase '$phase' not implemented yet in this slice; see specs/161-cli-devnet-smoke/plan.md"
            ;;
    esac
}

main "$@"
