{ pkgs, src, components, lintPkgs ? pkgs }:
let
  build = pkgs.writeShellApplication {
    name = "build";
    text = ''
      test -e ${components.library}
      test -e ${components.exes.amaru-treasury-tx}
      echo "build outputs realized"
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
    ];
    text = ''
      unit-tests \
        --match "infers the scope owner and appends extra signer scopes"

      help_text="$(amaru-treasury-tx swap-wizard --help)"
      printf '%s\n' "$help_text"

      grep -F -- '[--extra-signer|--signer SCOPE|HEX]' \
        <<<"$help_text" >/dev/null
      grep -F -- '--extra-signer,--signer SCOPE|HEX' \
        <<<"$help_text" >/dev/null
    '';
  };
in
{
  inherit build golden lint smoke unit;
}
