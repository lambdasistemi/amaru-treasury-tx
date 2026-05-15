{
  description =
    "Build Amaru treasury transactions (disburse, reorganize, withdraw)";
  nixConfig = {
    extra-substituters = [ "https://cache.iog.io" ];
    extra-trusted-public-keys =
      [ "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ=" ];
  };
  inputs = {
    haskellNix = {
      url =
        "github:input-output-hk/haskell.nix/8b447d7f57d62fab9249f79bb916bc891e29b9d0";
      inputs.hackage.follows = "hackageNix";
    };
    hackageNix = {
      url =
        "github:input-output-hk/hackage.nix/b6b4aa4bd699f743238da45c7f43da5a26a822f7";
      flake = false;
    };
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    lintNixpkgs.url =
      "github:NixOS/nixpkgs/647e5c14cbd5067f44ac86b74f014962df460840";
    flake-parts.url = "github:hercules-ci/flake-parts";
    bundlers = {
      url = "github:NixOS/bundlers";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    dev-assets.url = "github:paolino/dev-assets";
    iohkNix = {
      url =
        "github:input-output-hk/iohk-nix/f444d972c301ddd9f23eac4325ffcc8b5766eee9";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    CHaP = {
      url =
        "github:intersectmbo/cardano-haskell-packages/887d73ce434831e3a67df48e070f4f979b3ac5a6";
      flake = false;
    };
    cardano-node = {
      url = "github:IntersectMBO/cardano-node/10.7.0";
    };
  };

  outputs = inputs@{ self, nixpkgs, lintNixpkgs, flake-parts
    , haskellNix, hackageNix, iohkNix, CHaP, cardano-node, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-darwin" ];
      perSystem = { system, ... }:
        let
          pkgs = import nixpkgs {
            overlays = [
              iohkNix.overlays.crypto
              haskellNix.overlay
              iohkNix.overlays.haskell-nix-crypto
              iohkNix.overlays.cardano-lib
            ];
            inherit system;
          };
          lintPkgs = import lintNixpkgs { inherit system; };
          indexState = "2026-02-17T10:15:41Z";
          indexTool = { index-state = indexState; };
          cardanoNodeClientsSrc = pkgs.fetchgit {
            url = "https://github.com/lambdasistemi/cardano-node-clients";
            rev = "38fc1917ba475b90edd974576e1c71790d165532";
            sha256 = "09i3ysv7650imhd4b26cwybjckfs8qfv75kh1r6511zyjvmxykrh";
          };
          devnetGenesis =
            pkgs.runCommand "cardano-node-clients-devnet-genesis" { } ''
              cp -r ${cardanoNodeClientsSrc}/e2e-test/genesis $out
            '';
          cabalLines =
            pkgs.lib.splitString "\n"
            (builtins.readFile ./amaru-treasury-tx.cabal);
          packageVersionLine = pkgs.lib.findFirst
            (line: builtins.match "version:[[:space:]]*.*" line != null)
            (builtins.throw "missing version field in amaru-treasury-tx.cabal")
            cabalLines;
          packageVersion = builtins.elemAt
            (builtins.match
              "version:[[:space:]]*([0-9]+(\\.[0-9]+)*)"
              packageVersionLine)
            0;
          fix-libs = { lib, pkgs, ... }: {
            packages.cardano-crypto-praos.components.library.pkgconfig =
              lib.mkForce [ [ pkgs.libsodium-vrf ] ];
            packages.cardano-crypto-class.components.library.pkgconfig =
              lib.mkForce
              [ [ pkgs.libsodium-vrf pkgs.secp256k1 pkgs.libblst ] ];
            packages.cardano-lmdb.components.library.pkgconfig =
              lib.mkForce [ [ pkgs.lmdb ] ];
            packages.cardano-ledger-binary.components.library.doHaddock =
              lib.mkForce false;
            packages.plutus-core.components.library.doHaddock =
              lib.mkForce false;
            packages.plutus-ledger-api.components.library.doHaddock =
              lib.mkForce false;
            packages.plutus-tx.components.library.doHaddock =
              lib.mkForce false;
          };
          fix-libs-linux = { lib, pkgs, ... }: {
            packages.blockio-uring.components.library.pkgconfig =
              lib.mkForce [ [ pkgs.liburing ] ];
          };
          project = pkgs.haskell-nix.cabalProject' {
            name = "amaru-treasury-tx";
            src = ./.;
            compiler-nix-name = "ghc9123";
            shell = {
              withHoogle = true;
              tools = { cabal = indexTool; };
              buildInputs = [
                lintPkgs.haskellPackages.cabal-fmt
                lintPkgs.haskellPackages.fourmolu
                lintPkgs.haskellPackages.hlint
                pkgs.just
                pkgs.curl
                pkgs.cacert
                pkgs.lmdb
                cardano-node.packages.${system}.cardano-cli
                cardano-node.packages.${system}.cardano-node
              ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
                pkgs.liburing
              ];
              shellHook = ''
                export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
                export E2E_GENESIS_DIR=${devnetGenesis}
              '';
            };
            modules = [ fix-libs ]
              ++ pkgs.lib.optionals pkgs.stdenv.isLinux
                [ fix-libs-linux ];
            inputMap = {
              "https://chap.intersectmbo.org/" = CHaP;
            };
          };
          components = project.hsPkgs.amaru-treasury-tx.components;
          checks = import ./nix/checks.nix {
            inherit pkgs components lintPkgs;
            src = ./.;
          };
          checkApps = import ./nix/apps.nix { inherit pkgs checks; };
          mkExe = name:
            pkgs.symlinkJoin {
              name = "${name}-${packageVersion}";
              version = packageVersion;
              paths = [ components.exes.${name} ];
              meta.mainProgram = name;
            };
          amaru-treasury-tx = mkExe "amaru-treasury-tx";
          amaru-treasury-intent-schema =
            mkExe "amaru-treasury-intent-schema";
          swap-probe = mkExe "swap-probe";
          capture-swap-context = mkExe "capture-swap-context";
          sourceRevision = self.shortRev or (self.dirtyShortRev or "dirty");
          devArtifactVersion = "${packageVersion}-${sourceRevision}";
          mkDarwinHomebrewBundle =
            inputs.dev-assets.lib.mkDarwinHomebrewBundle { inherit pkgs; };
          darwinExecutables = {
            inherit amaru-treasury-tx swap-probe capture-swap-context;
          };
          darwinExecutableNames = [
            "amaru-treasury-tx"
            "swap-probe"
            "capture-swap-context"
          ];
          darwinFormulaTest = ''
            assert_predicate bin/"swap-probe", :executable?
            system "#{bin}/amaru-treasury-tx", "--help"
            system "#{bin}/capture-swap-context", "--help"
            system "#{bin}/amaru-treasury-tx", "swap-wizard", "--help"
            system "#{bin}/amaru-treasury-tx", "withdraw-wizard", "--help"
          '';
          mkAmaruDarwinHomebrewBundle = args:
            mkDarwinHomebrewBundle ({
              pname = "amaru-treasury-tx";
              version = packageVersion;
              owner = "lambdasistemi";
              desc =
                "Build unsigned Amaru treasury transactions (disburse, swap, withdraw)";
              homepage = "https://github.com/lambdasistemi/amaru-treasury-tx";
              formulaClass = "AmaruTreasuryTx";
              executables = darwinExecutables;
              executableNames = darwinExecutableNames;
              formulaTest = darwinFormulaTest;
              smokeCommands = [ "amaru-treasury-tx --help >/dev/null" ];
            } // args);
          darwinReleasePackages = pkgs.lib.optionalAttrs
            pkgs.stdenv.isDarwin
            {
              darwin-release-artifacts = mkAmaruDarwinHomebrewBundle { };
              darwin-dev-homebrew-artifacts = mkAmaruDarwinHomebrewBundle {
                artifactVersion = devArtifactVersion;
                releaseTag = "dev-homebrew";
                formulaName = "amaru-treasury-tx-dev";
                formulaClass = "AmaruTreasuryTxDev";
                formulaVersion = devArtifactVersion;
                formulaExtraLines =
                  "\n  conflicts_with \"amaru-treasury-tx\", because: \"both install the same command-line tools\"";
              };
            };
          linuxReleasePackages = pkgs.lib.optionalAttrs
            pkgs.stdenv.isLinux
            {
              linux-release-artifacts =
                import ./nix/linux-release.nix {
                  inherit pkgs system packageVersion;
                  package = amaru-treasury-tx;
                  bundlers = inputs.bundlers;
                };
              linux-dev-release-artifacts =
                import ./nix/linux-release.nix {
                  inherit pkgs system packageVersion;
                  artifactVersion = devArtifactVersion;
                  package = amaru-treasury-tx;
                  bundlers = inputs.bundlers;
                };
              linux-artifact-smoke =
                import ./nix/linux-artifact-smoke.nix {
                  inherit pkgs system;
                };
            };
        in {
          packages = {
            default = amaru-treasury-tx;
            inherit
              amaru-treasury-tx
              amaru-treasury-intent-schema
              swap-probe
              capture-swap-context
              ;
          } // darwinReleasePackages // linuxReleasePackages;
          # Drop the internal `scripts` attr (raw text bodies
          # shared with apps.nix) before exposing checks to the
          # flake — `nix flake check` would otherwise try to
          # build it as a derivation.
          checks = builtins.removeAttrs checks [ "apps" ];
          apps = checkApps // {
            default = {
              type = "app";
              program =
                "${amaru-treasury-tx}/bin/amaru-treasury-tx";
            };
          } // pkgs.lib.optionalAttrs pkgs.stdenv.isLinux {
            linux-artifact-smoke = {
              type = "app";
              program =
                "${linuxReleasePackages.linux-artifact-smoke}/bin/linux-artifact-smoke";
            };
          };
          devShells.default = project.shell;
        };
    };
}
