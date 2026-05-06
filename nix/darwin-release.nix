{ pkgs
, lib ? pkgs.lib
, packageVersion
, executables
, artifactVersion ? packageVersion
, releaseTag ? "v${packageVersion}"
, formulaName ? "amaru-treasury-tx"
, formulaClass ? "AmaruTreasuryTx"
, formulaVersion ? artifactVersion
, formulaExtraLines ? ""
}:
let
  executableNames = [
    "amaru-treasury-tx"
    "swap-probe"
    "capture-swap-context"
  ];
  packageName = "amaru-treasury-tx";
  system = pkgs.stdenv.hostPlatform.system;
  artifactName = "${packageName}-${artifactVersion}-${system}.tar.gz";
  releaseUrl =
    "https://github.com/lambdasistemi/${packageName}/releases/download/${releaseTag}/${artifactName}";
  copyExecutableCommands = lib.concatMapStringsSep "\n"
    (name: ''
      copy_executable "${name}" "${executables.${name}}/bin/${name}"
    '')
    executableNames;
in
assert pkgs.stdenv.isDarwin;
pkgs.runCommand "${formulaName}-${artifactVersion}-${system}-artifacts"
  {
    nativeBuildInputs = [
      pkgs.coreutils
      pkgs.darwin.cctools
      pkgs.gnutar
      pkgs.gzip
    ];
    passthru = {
      inherit artifactName executableNames formulaName releaseTag;
    };
    meta = {
      description = "Darwin release tarball and Homebrew formula";
      platforms = lib.platforms.darwin;
    };
  }
  ''
    set -euo pipefail

    bundle="$TMPDIR/bundle"
    queue="$TMPDIR/dylib-queue"
    seen="$TMPDIR/dylib-seen"

    mkdir -p "$bundle/bin" "$bundle/libexec/lib" "$out"
    : > "$queue"
    : > "$seen"

    list_non_system_dylibs() {
      otool -L "$1" \
        | awk 'NR > 1 { print $1 }' \
        | while IFS= read -r lib; do
          case "$lib" in
            "" | /usr/lib/* | /System/* | @*)
              ;;
            *)
              printf '%s\n' "$lib"
              ;;
          esac
        done
    }

    queue_dylib() {
      lib="$1"
      if ! grep -Fxq "$lib" "$seen"; then
        printf '%s\n' "$lib" >> "$seen"
        printf '%s\n' "$lib" >> "$queue"
      fi
    }

    patch_loads() {
      binary="$1"
      replacement_prefix="$2"
      own_install_name="''${3:-}"

      list_non_system_dylibs "$binary" | while IFS= read -r lib; do
        if [ -n "$own_install_name" ] && [ "$lib" = "$own_install_name" ]; then
          continue
        fi

        libname="$(basename "$lib")"
        queue_dylib "$lib"
        install_name_tool \
          -change "$lib" "$replacement_prefix/$libname" \
          "$binary"
      done
    }

    copy_executable() {
      name="$1"
      src="$2"
      target="$bundle/bin/$name"

      if [ ! -x "$src" ]; then
        echo "missing executable: $name at $src" >&2
        exit 1
      fi

      cp -L "$src" "$target"
      chmod u+w "$target"
      patch_loads "$target" "@executable_path/../libexec/lib"
      otool -L "$target"
    }

    copy_dylib() {
      lib="$1"
      libname="$(basename "$lib")"
      target="$bundle/libexec/lib/$libname"

      if [ ! -f "$target" ]; then
        cp -L "$lib" "$target"
        chmod u+w "$target"
      fi

      install_name_tool -id "@loader_path/$libname" "$target"
      patch_loads "$target" "@loader_path" "$lib"
    }

    ${copyExecutableCommands}

    while [ -s "$queue" ]; do
      lib="$(head -n 1 "$queue")"
      tail -n +2 "$queue" > "$queue.next"
      mv "$queue.next" "$queue"
      copy_dylib "$lib"
    done

    "$bundle/bin/amaru-treasury-tx" --help >/dev/null

    tarball="$out/${artifactName}"
    tar --sort=name \
      --mtime='@1' \
      --owner=0 \
      --group=0 \
      --numeric-owner \
      -cf - \
      -C "$bundle" . \
      | gzip -n > "$tarball"

    sha="$(sha256sum "$tarball" | cut -d' ' -f1)"
    printf '%s  %s\n' "$sha" "${artifactName}" > "$out/SHA256SUMS"

    cat > "$out/${formulaName}.rb" <<EOF
class ${formulaClass} < Formula
  desc "Build unsigned Amaru treasury transactions (disburse, swap, withdraw)"
  homepage "https://github.com/lambdasistemi/amaru-treasury-tx"
  url "${releaseUrl}"
  sha256 "$sha"
  version "${formulaVersion}"
${formulaExtraLines}

  def install
    bin.install "bin/amaru-treasury-tx", "bin/swap-probe", "bin/capture-swap-context"
    (libexec/"lib").install Dir["libexec/lib/*"]
  end

  test do
    assert_predicate bin/"swap-probe", :executable?
    system "#{bin}/amaru-treasury-tx", "--help"
    system "#{bin}/capture-swap-context", "--help"
    system "#{bin}/amaru-treasury-tx", "swap-wizard", "--help"
  end
end
EOF

    ls -lh "$out"
  ''
