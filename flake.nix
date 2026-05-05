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
        "github:input-output-hk/haskell.nix/ef52c36b9835c77a255befe2a20075ba71e3bfab";
      inputs.hackage.follows = "hackageNix";
    };
    hackageNix = {
      url =
        "github:input-output-hk/hackage.nix/55ba0ca4bcc9690f2ea45335cb2b9e95d8219a04";
      flake = false;
    };
    nixpkgs.follows = "haskellNix/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
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
  };

  outputs = inputs@{ self, nixpkgs, flake-parts, haskellNix, hackageNix
    , iohkNix, CHaP, ... }:
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
          indexState = "2026-02-17T10:15:41Z";
          indexTool = { index-state = indexState; };
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
            compiler-nix-name = "ghc9122";
            shell = {
              withHoogle = false;
              tools = { cabal = indexTool; };
              buildInputs = [
                pkgs.haskellPackages.cabal-fmt
                pkgs.haskellPackages.fourmolu
                pkgs.haskellPackages.hlint
                pkgs.just
                pkgs.curl
                pkgs.cacert
                pkgs.lmdb
              ] ++ pkgs.lib.optionals pkgs.stdenv.isLinux [
                pkgs.liburing
              ];
              shellHook = ''
                export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
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
            inherit pkgs components;
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
          swap-probe = mkExe "swap-probe";
          capture-swap-context = mkExe "capture-swap-context";
        in {
          packages = {
            default = amaru-treasury-tx;
            inherit amaru-treasury-tx swap-probe capture-swap-context;
          };
          inherit checks;
          apps = checkApps // {
            default = {
              type = "app";
              program =
                "${amaru-treasury-tx}/bin/amaru-treasury-tx";
            };
          };
          devShells.default = project.shell;
        };
    };
}
