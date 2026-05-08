{ pkgs, src, components, lintPkgs ? pkgs }:
let
  build = pkgs.writeShellApplication {
    name = "build";
    text = ''
      test -e ${components.library}
      test -e ${components.exes.amaru-treasury-tx}
      test -e ${components.exes.amaru-treasury-intent-schema}
      echo "build outputs realized"
    '';
  };

  schema = pkgs.writeShellApplication {
    name = "schema";
    runtimeInputs = [ components.exes.amaru-treasury-intent-schema ];
    text = ''
      tmp="$(mktemp)"
      trap 'rm -f "$tmp"' EXIT
      amaru-treasury-intent-schema > "$tmp"
      diff -u ${src}/docs/assets/intent-schema.json "$tmp"
    '';
  };

  unit = pkgs.writeShellApplication {
    name = "unit";
    runtimeInputs = [ components.tests.unit-tests ];
    text = ''
      exec unit-tests
    '';
  };

  golden = pkgs.writeShellApplication {
    name = "golden";
    runtimeInputs = [ components.tests.golden-tests ];
    text = ''
      exec golden-tests
    '';
  };

  lint = pkgs.writeShellApplication {
    name = "lint";
    runtimeInputs = with lintPkgs.haskellPackages; [
      cabal-fmt
      fourmolu
      hlint
    ];
    text = ''
      cd ${src}
      cabal-fmt -c amaru-treasury-tx.cabal
      find . -type f -name '*.hs' \
        -not -path '*/dist-newstyle/*' \
        -exec fourmolu -m check {} +
      find . -type f -name '*.hs' \
        -not -path '*/dist-newstyle/*' \
        -exec hlint {} +
    '';
  };

  smoke = pkgs.writeShellApplication {
    name = "smoke";
    runtimeInputs = [
      components.exes.amaru-treasury-tx
      components.tests.unit-tests
      components.tests.golden-tests
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
        '--log'
      do
        if ! grep -F -- "$needle" >/dev/null <<<"$build_help"; then
          printf 'smoke: missing tx-build flag: %s\n' "$needle" >&2
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

      for pair in "swap-wizard:$wizard_elapsed" "withdraw-wizard:$withdraw_elapsed" "tx-build:$build_elapsed"; do
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

      printf 'smoke: OK (swap-wizard --help %ss, withdraw-wizard --help %ss, tx-build --help %ss)\n' \
        "$wizard_elapsed" "$withdraw_elapsed" "$build_elapsed"
    '';
  };
in
{
  inherit build golden lint schema smoke unit;
}
