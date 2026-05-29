{
  description = "Blender from local source";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [
            (final: prev: {
              ccacheWrapper = prev.ccacheWrapper.override {
                extraConfig = ''
                  export CCACHE_COMPRESS=1
                  export CCACHE_SLOPPINESS=random_seed
                  export CCACHE_DIR=''${CCACHE_DIR:-/tmp/ccache}
                  export CCACHE_UMASK=007
                '';
              };
            })
          ];
        };

        clangCcacheStdenv = pkgs.ccacheStdenv.override {
          stdenv = pkgs.clangStdenv;
        };

        rocmPackages = pkgs.rocmPackages;

        rocmAvailable = pkgs.lib.hasSuffix "linux" system && pkgs.stdenv.hostPlatform.isx86_64;

        src = builtins.path {
          path = ./.;
          name = "blender-source";
          filter = path: type:
            (baseNameOf path != ".git")
            && (baseNameOf path != "flake.nix")
            && (baseNameOf path != "flake.lock");
        };

        # Official release tarball provides real files for LFS pointers in the repo
        blenderDataSrc = pkgs.fetchzip {
          name = "blender-data";
          url = "https://download.blender.org/source/blender-5.1.2.tar.xz";
          hash = "sha256-FnReSNsP8U1/4jSgZN3cMQV2qkP7OZPh0f/9JA1lAxs=";
        };

        commonPreConfigure = ''
          # Replace remaining Git LFS pointer files with real ones from the release tarball
          find . -type f -exec grep -l "git-lfs.github.com" {} + 2>/dev/null \
            | while IFS= read -r f; do
                relpath=$(echo "$f" | sed 's|^\./||')
                datafile="${blenderDataSrc}/$relpath"
                if [ -f "$datafile" ]; then
                  cp "$datafile" "$f"
                  echo "Replaced: $relpath"
                fi
              done || true
        '';

        commonMeta = {
          description = "3D Creation/Animation/Publishing System (local build)";
        };

        mkBlender =
          {
            rocmSupport ? false,
            pnameSuffix ? "",
          }:
          let
            bname = "blender${pnameSuffix}";
          in
          (pkgs.blender.override {
            stdenv = clangCcacheStdenv;
            inherit rocmSupport;
            python313Packages = pkgs.python313Packages;
            rocmPackages = pkgs.rocmPackages;
          }).overrideAttrs (old: {
            inherit src;
            version = "5.2.0-alpha";
            pname = bname;

            patches = pkgs.lib.optionals rocmSupport [
              # Backport of hiprt 3.x support
              ./hiprt-3-compat.patch
            ];

            dontUnpack = true;

            prePatch = ''
              cp -a "$src"/* .
              chmod -R u+w .
            '';

            preConfigure = commonPreConfigure;

            postPatch = pkgs.lib.optionalString rocmSupport ''
              substituteInPlace extern/hipew/src/hipew.c \
                --replace-fail '"/opt/rocm/hip/lib/libamdhip64.so.${pkgs.lib.versions.major pkgs.rocmPackages.clr.version}"' \
                '"${pkgs.rocmPackages.clr}/lib/libamdhip64.so"'
              substituteInPlace extern/hipew/src/hipew.c \
                --replace-fail '"opt/rocm/hip/bin"' \
                '"${pkgs.rocmPackages.clr}/bin"'
            '';

            cmakeFlags =
              old.cmakeFlags
              ++ [
                "-DWITH_HYDRA:BOOL=FALSE"
                "-DWITH_STRICT_BUILD_OPTIONS:BOOL=FALSE"
              ];

            meta = old.meta // commonMeta // {
              description = "${commonMeta.description}${pkgs.lib.optionalString rocmSupport " (with HIP/ROCm support)"}";
            };
          });
      in
      {
        packages.default = mkBlender {
          rocmSupport = rocmAvailable;
        };
        devShells.default = pkgs.mkShell {
          inputsFrom = [ self.packages.${system}.default ];
          nativeBuildInputs = with pkgs; [ cmake git-lfs pkg-config ];
        };
      }
    );
}
