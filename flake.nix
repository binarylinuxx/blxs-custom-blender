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
                  export CCACHE_DIR=''${CCACHE_DIR:-/var/cache/ccache}
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
          cp -a "$src"/* .
          chmod -R u+w .

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

            patches = [ ] ++ pkgs.lib.optionals rocmSupport [
              # Backport of hiprt 3.x support
              ./hiprt-3-compat.patch
            ];

            dontUnpack = true;

            preConfigure = commonPreConfigure;

            cmakeFlags =
              old.cmakeFlags
              ++ [
                "-DWITH_HYDRA:BOOL=FALSE"
                "-DWITH_STRICT_BUILD_OPTIONS:BOOL=FALSE"
              ]
              ++ pkgs.lib.optionals rocmSupport [
                "-DWITH_CYCLES_DEVICE_HIP:BOOL=TRUE"
                "-DWITH_CYCLES_DEVICE_HIPRT:BOOL=TRUE"
                "-DWITH_CYCLES_HIP_BINARIES:BOOL=TRUE"
              ];

            meta = old.meta // commonMeta // {
              description = "${commonMeta.description}${pkgs.lib.optionalString rocmSupport " (with HIP/ROCm support)"}";
            };
          });
      in
      let
        hipPkg = pkgs.lib.optionals rocmAvailable [
          (mkBlender {
            rocmSupport = true;
            pnameSuffix = "-hip";
          })
        ];
      in
      {
        packages = {
          default = mkBlender { };
        } // pkgs.lib.optionalAttrs rocmAvailable {
          hip = mkBlender {
            rocmSupport = true;
            pnameSuffix = "-hip";
          };
        };
        devShells.default = pkgs.mkShell {
          inputsFrom = [ self.packages.${system}.default ];
          nativeBuildInputs = with pkgs; [ cmake git-lfs pkg-config ];
        };
      }
    );
}
