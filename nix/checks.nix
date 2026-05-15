{ pkgs, src, components, lintPkgs ? pkgs }:
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
      runtimeInputs = [ components.tests.unit-tests ];
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
  schema = mkCheck "schema" scripts.schema;
  unit = mkCheck "unit" scripts.unit;
  golden = mkCheck "golden" scripts.golden;
  lint = mkCheck "lint" scripts.lint;
  smoke = mkCheck "smoke" scripts.smoke;
  vault-tty-smoke = mkCheck "vault-tty-smoke" scripts.vault-tty-smoke;

  # The same writeShellApplication apps the checks invoke,
  # re-exported for `nix/apps.nix` to expose under
  # `flake.apps.<sys>.<name>`.
  inherit apps;
}
