{ pkgs, src, components, lintPkgs ? pkgs
, treasuryMetadata, recentTxs, buildIdentity, frontend, image
, rdfRuntimeInputs ? [ ] }:
# Each verification step is built as a single
# `writeShellApplication` app, then exposed twice:
#
#   * `flake.checks.<sys>.<name>` — a `runCommand` that
#     **invokes** the app inside the nix sandbox, so
#     `nix flake check` and `nix build .#checks.<sys>.<name>`
#     execute the script under the same strict PATH that
#     `nix run` uses;
#   * `flake.apps.<sys>.<name>` — the app directly (re-exported
#     via `apps`), so `nix run .#<name>` runs the same bytes
#     (and the same PATH) that the check just verified.
#
# Inlining the script body into a `runCommand` instead would
# pull in `stdenv` defaults (coreutils, diffutils, etc.) that
# are NOT available to `writeShellApplication`'s strict PATH —
# the check would pass while CI's `nix run` would 127 on a
# missing tool. Always invoke the app.
let
  scripts = {
    build = {
      runtimeInputs = [ ];
      text = ''
        test -e ${components.library}
        test -e ${components.exes.amaru-treasury-tx}
        test -e ${components.exes.amaru-treasury-intent-schema}
        echo "build outputs realized"
      '';
    };

    # #239 T001 — Asserts that the metadata baked into the
    # deployed image at build time matches the expected
    # sha256. Lives here so a flake-input bump that changes
    # the bytes fails `nix flake check` loudly and prompts
    # an explicit `pinnedSha256` update in nix/metadata.nix.
    metadata-pin = {
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        observed=$(sha256sum '${treasuryMetadata.metadataFile}' \
          | cut -d' ' -f1)
        expected='${treasuryMetadata.pinnedSha256}'
        if [ "$observed" != "$expected" ]; then
          printf 'metadata-pin: sha256 mismatch\n' >&2
          printf '  observed: %s\n' "$observed" >&2
          printf '  expected: %s\n' "$expected" >&2
          printf 'Bump nix/metadata.nix: pinnedSha256 to match.\n' \
            >&2
          exit 1
        fi
        printf 'metadata-pin: OK (sha256=%s)\n' "$observed"
      '';
    };

    # #239 T003 — Asserts the build-identity JSON carries
    # the five required fields, the sha256 hex shape holds,
    # the recent-txs count equals the manifest's, and the
    # metadata sha256 matches the value in nix/metadata.nix
    # so a flake-input bump always touches both.
    build-identity = {
      runtimeInputs = [ pkgs.jq pkgs.coreutils ];
      text = ''
        f='${buildIdentity}/build-identity.json'
        m='${recentTxs}/recent-txs.json'

        # Shape (all keys present, correct types).
        if ! jq -e '
          (.biBuildTime|type)       == "string" and
          (.biGitCommit|type)       == "string" and
          (.biMetadataSha256|test("^[0-9a-f]{64}$")) and
          (.biMetadataSource|type)  == "string" and
          (.biRecentTxsCount|type)  == "number"
        ' "$f" > /dev/null; then
          echo "build-identity: shape mismatch" >&2
          jq . "$f" >&2
          exit 1
        fi

        # Cross-checks against the rest of the slice.
        observed_sha=$(jq -r '.biMetadataSha256' "$f")
        expected_sha='${treasuryMetadata.pinnedSha256}'
        if [ "$observed_sha" != "$expected_sha" ]; then
          echo "build-identity: metadata sha drift" >&2
          echo "  identity says: $observed_sha" >&2
          echo "  pin says:      $expected_sha" >&2
          exit 1
        fi

        observed_count=$(jq '.biRecentTxsCount' "$f")
        expected_count=$(jq '.rtmEntries | length' "$m")
        if [ "$observed_count" != "$expected_count" ]; then
          echo "build-identity: recentTxsCount drift" >&2
          echo "  identity says: $observed_count" >&2
          echo "  manifest:      $expected_count" >&2
          exit 1
        fi

        printf 'build-identity: OK\n'
        jq -c . "$f"
      '';
    };

    # #239 T012 — Asserts the Halogen frontend bundle builds
    # reproducibly and emits the two files the image expects.
    frontend-bundle = {
      runtimeInputs = [ pkgs.coreutils ];
      text = ''
        test -e '${frontend}/index.html'
        test -e '${frontend}/index.js'
        size=$(stat -c %s '${frontend}/index.js')
        if [ "$size" -lt 10000 ]; then
          echo "frontend-bundle: index.js suspiciously small ($size bytes)" >&2
          exit 1
        fi
        printf 'frontend-bundle: OK (index.js=%s bytes)\n' "$size"
      '';
    };

    # #239 T002 — Asserts the build-time recent-txs manifest
    # parses as JSON, surfaces at most 10 entries, each entry
    # has all four required fields, every txid is 64 hex
    # chars, the scope is one of the registered values, and
    # the list is sorted by submitted_at descending.
    recent-txs-manifest = {
      runtimeInputs = [ pkgs.jq pkgs.coreutils ];
      text = ''
        m='${recentTxs}/recent-txs.json'

        # Valid JSON envelope.
        count=$(jq '.rtmEntries | length' "$m")
        if [ "$count" -gt 10 ]; then
          echo "recent-txs-manifest: too many entries ($count)" >&2
          exit 1
        fi

        # Every entry shape.
        bad=$(jq -r '
          .rtmEntries[] |
          select(
            (.rteScope|type) != "string" or
            (.rteTxid|test("^[0-9a-f]{64}$")|not) or
            (.rteSubmittedAt|type) != "string" or
            (.rteCardanoscanUrl|test("^https://cardanoscan.io/transaction/[0-9a-f]{64}$")|not) or
            ([.rteScope] | inside(["core_development","ops_and_use_cases","network_compliance","middleware","contingency"]) | not)
          ) |
          .rteTxid
        ' "$m")
        if [ -n "$bad" ]; then
          echo "recent-txs-manifest: malformed entries:" >&2
          printf '  %s\n' "$bad" >&2
          exit 1
        fi

        # Descending submitted_at order.
        if [ "$count" -gt 1 ]; then
          if ! jq -e '
            .rtmEntries
            | map(.rteSubmittedAt)
            | . == (sort | reverse)
          ' "$m" > /dev/null; then
            echo "recent-txs-manifest: not sorted desc" >&2
            jq '.rtmEntries | map(.rteSubmittedAt)' "$m" >&2
            exit 1
          fi
        fi

        printf 'recent-txs-manifest: OK (%d entries)\n' "$count"
      '';
    };

    schema = {
      runtimeInputs = [
        components.exes.amaru-treasury-intent-schema
        pkgs.diffutils
        pkgs.coreutils
      ];
      text = ''
        tmp="$(mktemp)"
        trap 'rm -f "$tmp"' EXIT
        amaru-treasury-intent-schema > "$tmp"
        diff -u ${src}/docs/assets/intent-schema.json "$tmp"
      '';
    };

    unit = {
      # The history RDF tests shell out to Apache Jena (`arq`,
      # `shacl`) and the `cq-rdf` emitter, so the hermetic check
      # needs them on PATH. Keep this in sync with the dev
      # shell so local `nix develop -c just unit` runs the same
      # RDF/Jena-backed specs as CI.
      runtimeInputs = [ components.tests.unit-tests ] ++ rdfRuntimeInputs;
      # No `exec` — the check derivation needs the script to
      # return so the wrapping `runCommand` can `touch $out`.
      text = ''
        unit-tests
      '';
    };

    golden = {
      runtimeInputs = [ components.tests.golden-tests ];
      text = ''
        golden-tests
      '';
    };

    lint = {
      runtimeInputs =
        (with lintPkgs.haskellPackages; [ cabal-fmt fourmolu hlint ])
        # `writeShellApplication` restricts PATH to
        # `runtimeInputs`; pull `diff` and `find` in
        # explicitly so the lint script doesn't 127.
        ++ [ pkgs.diffutils pkgs.findutils ];
      text = ''
        # `cabal-fmt -c` only writes "error: ... not formatted"
        # to stderr and may exit 0 on some versions; diff gives
        # us a strict, version-independent failure signal.
        diff -u amaru-treasury-tx.cabal \
          <(cabal-fmt amaru-treasury-tx.cabal)
        find . -type f -name '*.hs' \
          -not -path '*/dist-newstyle/*' \
          -exec fourmolu -m check {} +
        find . -type f -name '*.hs' \
          -not -path '*/dist-newstyle/*' \
          -exec hlint {} +
      '';
    };

    smoke = {
      runtimeInputs = [
        components.exes.amaru-treasury-tx
        components.tests.unit-tests
        components.tests.golden-tests
        pkgs.coreutils
        pkgs.diffutils
        pkgs.expect
        pkgs.gnugrep
      ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
        pkgs.util-linux
      ];
      text = ''
        # ---- swap-wizard signer UX (carried over from feature 002) ----
        unit-tests \
          --match "infers the scope owner and appends extra signer scopes"

        help_text="$(amaru-treasury-tx swap-wizard --help)"
        printf '%s\n' "$help_text"

        grep -F -- '[--extra-signer|--signer SCOPE|HEX]' \
          <<<"$help_text" >/dev/null
        grep -F -- '--extra-signer,--signer SCOPE|HEX' \
          <<<"$help_text" >/dev/null

        # ---- tx-build-pipe (feature 005 T026) ----------------------
        # Both subcommands are wired and snappy (< 10 s startup,
        # carrying feature 004 SC-002 forward), the unified
        # intent JSON round-trips through the parser, and the
        # SC-004 byte-identity gate still holds.

        wizard_start=$(date +%s)
        wizard_help="$(amaru-treasury-tx swap-wizard --help)"
        wizard_elapsed=$(( $(date +%s) - wizard_start ))

        for needle in \
          '--metadata PATH' \
          '--scope NAME' \
          '--usdm USDM' \
          '--validity-hours HOURS' \
          '--extra-signer,--signer SCOPE|HEX'
        do
          if ! grep -F -- "$needle" >/dev/null <<<"$wizard_help"; then
            printf 'smoke: missing wizard flag: %s\n' "$needle" >&2
            exit 1
          fi
        done

        build_start=$(date +%s)
        build_help="$(amaru-treasury-tx tx-build --help)"
        build_elapsed=$(( $(date +%s) - build_start ))

        for needle in \
          '--intent' \
          '--out' \
          '--log' \
          '--report'
        do
          if ! grep -F -- "$needle" >/dev/null <<<"$build_help"; then
            printf 'smoke: missing tx-build flag: %s\n' "$needle" >&2
            exit 1
          fi
        done

        render_start=$(date +%s)
        render_help="$(amaru-treasury-tx report-render --help)"
        render_elapsed=$(( $(date +%s) - render_start ))

        for needle in \
          '--in PATH' \
          '--out PATH' \
          '--metadata PATH' \
          'Render a tx-build report envelope as Markdown'
        do
          if ! grep -F -- "$needle" >/dev/null <<<"$render_help"; then
            printf 'smoke: missing report-render help text: %s\n' "$needle" >&2
            exit 1
          fi
        done

        withdraw_start=$(date +%s)
        withdraw_help="$(amaru-treasury-tx withdraw-wizard --help)"
        withdraw_elapsed=$(( $(date +%s) - withdraw_start ))

        for needle in \
          '--wallet-addr BECH32' \
          '--metadata PATH' \
          '--scope NAME' \
          '--validity-hours HOURS' \
          'Produce a withdraw intent.json'
        do
          if ! grep -F -- "$needle" >/dev/null <<<"$withdraw_help"; then
            printf 'smoke: missing withdraw-wizard flag: %s\n' "$needle" >&2
            exit 1
          fi
        done

        for pair in "swap-wizard:$wizard_elapsed" "withdraw-wizard:$withdraw_elapsed" "tx-build:$build_elapsed" "report-render:$render_elapsed"; do
          name="''${pair%%:*}"
          secs="''${pair#*:}"
          if [[ "$secs" -gt 10 ]]; then
            printf 'smoke: SLOW %s --help (%ss > 10s)\n' \
              "$name" "$secs" >&2
            exit 1
          fi
        done

        # Parser round-trip + SC-004 byte-identity (golden CBOR).
        unit-tests --match "IntentJSON"
        golden-tests --match "swap golden"

        rendered_report="$(amaru-treasury-tx report-render < test/fixtures/swap/report.golden.json)"
        expected_report="$(< test/fixtures/swap/report.golden.md)"
        if [[ "$rendered_report" != "$expected_report" ]]; then
          printf 'smoke: report-render output differs from swap Markdown golden\n' >&2
          exit 1
        fi

        helper_tmp="$(mktemp -d)"
        trap 'rm -rf "$helper_tmp"' EXIT
        mock_exe="$helper_tmp/amaru-treasury-tx"
        cat > "$mock_exe" <<'EOF'
        #!/usr/bin/env sh
        set -eu

        cmd=$1
        shift
        case "$cmd" in
          tx-build)
            out_path=
            report_path=
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --out)
                  out_path=$2
                  shift 2
                  ;;
                --report)
                  report_path=$2
                  shift 2
                  ;;
                --intent|--log)
                  shift 2
                  ;;
                *)
                  shift
                  ;;
              esac
            done
            test -n "$out_path"
            test -n "$report_path"
            printf '84a4\n' > "$out_path"
            cat test/fixtures/swap/report.golden.json > "$report_path"
            ;;
          report-render)
            exec amaru-treasury-tx report-render "$@"
            ;;
          *)
            printf 'mock amaru-treasury-tx: unexpected command %s\n' "$cmd" >&2
            exit 99
            ;;
        esac
EOF
        chmod +x "$mock_exe"

        helper_default="$helper_tmp/default"
        AMARU_TREASURY_TX="$mock_exe" \
          ${pkgs.bash}/bin/bash ${src}/scripts/ops/build-swop --out "$helper_default" \
          < test/fixtures/swap/intent.json
        test -s "$helper_default/swap.cbor.hex"
        diff -u test/fixtures/swap/report.golden.json "$helper_default/report.json"
        diff -u test/fixtures/swap/report.golden.md "$helper_default/report.md"

        helper_optout="$helper_tmp/no-markdown"
        mkdir -p "$helper_optout"
        printf 'stale\n' > "$helper_optout/report.md"
        AMARU_TREASURY_TX="$mock_exe" \
          ${pkgs.bash}/bin/bash ${src}/scripts/ops/build-swop --out "$helper_optout" --no-markdown \
          < test/fixtures/swap/intent.json
        test -s "$helper_optout/swap.cbor.hex"
        diff -u test/fixtures/swap/report.golden.json "$helper_optout/report.json"
        if [[ -e "$helper_optout/report.md" ]]; then
          printf 'smoke: build-swop --no-markdown left report.md behind\n' >&2
          exit 1
        fi

        for needle in \
          'pre-signing review artifact' \
          'top-level intent plus top-level result' \
          'treasury metadata, built-in constants, script-hash derivation, embedded intent, and unresolved fallback' \
          'scripts/ops/build-swop' \
          '--no-markdown'
        do
          if ! grep -F -- "$needle" docs/report-render.md >/dev/null; then
            printf 'smoke: docs/report-render.md missing text: %s\n' "$needle" >&2
            exit 1
          fi
        done

        grep -F -- 'no intermediate files' docs/quickstart.md >/dev/null
        grep -F -- 'tx-build --out /dev/null --report -' docs/quickstart.md >/dev/null
        grep -F -- 'result.tx-cbor' docs/quickstart.md >/dev/null
        grep -F -- 'swap-wizard' docs/swap.md >/dev/null
        grep -F -- 'tx-build --out /dev/null --report -' docs/swap.md >/dev/null

        AMARU_TREASURY_TX_EXE=amaru-treasury-tx \
          ${pkgs.bash}/bin/bash scripts/smoke/vault-witness
        AMARU_TREASURY_TX_EXE=amaru-treasury-tx \
          ${pkgs.bash}/bin/bash scripts/smoke/vault-witness-tty

        printf 'smoke: OK (swap-wizard --help %ss, withdraw-wizard --help %ss, tx-build --help %ss, report-render --help %ss)\n' \
          "$wizard_elapsed" "$withdraw_elapsed" "$build_elapsed" "$render_elapsed"
      '';
    };

    # #242 T007/T008 — Asserts the dockerTools.streamLayeredImage
    # carries the embedded indexer's persistent volume mount
    # point and the matching `--indexer-db` Cmd flag.
    #
    # streamLayeredImage produces a small bash wrapper that
    # exec's a `stream` binary with a generated
    # `…-conf.json` describing the image config. The Volumes
    # object and Cmd array we want to assert on live in that
    # conf.json — not in the wrapper itself. We extract the
    # store path of the conf out of the wrapper, then grep
    # the conf for the two strings FR-013 / FR-014 require.
    #
    # The check is intentionally a substring assertion
    # rather than a full `docker inspect` — running a daemon
    # in the nix sandbox is too heavyweight, and the string
    # identity is what the spec requires.
    indexer-volume = {
      runtimeInputs = [ pkgs.gnugrep ];
      text = ''
        conf=$(grep -oE '/nix/store/[^ ]+-conf\.json' '${image}' \
          | head -n 1)
        if [ -z "$conf" ] || [ ! -e "$conf" ]; then
          echo \
            'indexer-volume: could not locate conf.json from streamLayeredImage wrapper' \
            >&2
          exit 1
        fi
        if ! grep -F -- \
          '/var/lib/amaru-treasury/indexer-rocksdb' \
          "$conf" > /dev/null; then
          echo \
            'indexer-volume: conf.json missing volume path /var/lib/amaru-treasury/indexer-rocksdb' \
            >&2
          exit 1
        fi
        if ! grep -F -- '--indexer-db' \
          "$conf" > /dev/null; then
          echo \
            'indexer-volume: conf.json missing --indexer-db Cmd flag' \
            >&2
          exit 1
        fi
        printf 'indexer-volume: OK (conf=%s)\n' "$conf"
      '';
    };

    vault-tty-smoke = {
      runtimeInputs = [
        components.exes.amaru-treasury-tx
        pkgs.bash
        pkgs.coreutils
        pkgs.diffutils
        pkgs.expect
        pkgs.gnugrep
        pkgs.gnused
      ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
        pkgs.util-linux
      ];
      text = ''
        AMARU_TREASURY_TX_EXE=amaru-treasury-tx \
          ${pkgs.bash}/bin/bash scripts/smoke/vault-witness-tty
      '';
    };
  };

  # Build the writeShellApplication app once. Both the check
  # derivation and the `nix run` app point at this same
  # store path, so they share the same strict PATH (only
  # `runtimeInputs`, no `stdenv` leak) and any missing tool
  # surfaces in both.
  mkApp = name: { runtimeInputs, text }:
    pkgs.writeShellApplication { inherit name text runtimeInputs; };

  # Wrap the app in a `runCommand` so `nix flake check` and
  # `nix build .#checks.<sys>.<name>` actually invoke the
  # script under the strict PATH.
  mkCheck = name: spec:
    let
      app = mkApp name spec;
    in
    pkgs.runCommand name {
      nativeBuildInputs = [ pkgs.glibcLocales ];
      # Tests print non-ASCII (em-dashes etc.) and would
      # otherwise crash with `cannot encode character` in the
      # bare runCommand sandbox.
      LANG = "C.UTF-8";
      LC_ALL = "C.UTF-8";
    } ''
      set -euo pipefail
      # Run from the project root so test fixtures referenced
      # as `test/fixtures/...` resolve. `${src}` is the
      # read-only flake source in the store — checks that need
      # to write (`UPDATE_GOLDENS`) won't work here, but
      # byte-identity goldens do.
      cd ${src}
      ${pkgs.lib.getExe app}
      touch $out
    '';

  apps = builtins.mapAttrs mkApp scripts;
in
{
  # Sandboxed checks (nix flake check / nix build).
  build = mkCheck "build" scripts.build;
  build-identity = mkCheck "build-identity" scripts.build-identity;
  frontend-bundle =
    mkCheck "frontend-bundle" scripts.frontend-bundle;
  metadata-pin = mkCheck "metadata-pin" scripts.metadata-pin;
  recent-txs-manifest =
    mkCheck "recent-txs-manifest" scripts.recent-txs-manifest;
  schema = mkCheck "schema" scripts.schema;
  unit = mkCheck "unit" scripts.unit;
  golden = mkCheck "golden" scripts.golden;
  lint = mkCheck "lint" scripts.lint;
  smoke = mkCheck "smoke" scripts.smoke;
  indexer-volume = mkCheck "indexer-volume" scripts.indexer-volume;
  vault-tty-smoke = mkCheck "vault-tty-smoke" scripts.vault-tty-smoke;

  # The same writeShellApplication apps the checks invoke,
  # re-exported for `nix/apps.nix` to expose under
  # `flake.apps.<sys>.<name>`.
  inherit apps;
}
