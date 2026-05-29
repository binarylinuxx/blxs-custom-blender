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
            (final: prev: let
              ccacheStdenvClang = prev.ccacheStdenv.override {
                stdenv = prev.clangStdenv;
              };

              rocmLLVM    = prev.rocmPackages.llvm.llvm;
              rocmClang   = prev.rocmPackages.llvm.clang;
              rocmClangUW = prev.rocmPackages.llvm.clang-unwrapped;

              openshadinglanguage = (prev.openshadinglanguage.override {
                stdenv = prev.stdenv;
                llvmPackages_19 = prev.rocmPackages.llvm // {
                  libclang = rocmClangUW;
                };
              }).overrideAttrs (old: {
                cmakeFlags = (old.cmakeFlags or []) ++ [
                  "-DCMAKE_C_COMPILER=${rocmClang}/bin/clang"
                  "-DCMAKE_CXX_COMPILER=${rocmClang}/bin/clang++"
                  "-DLLVM_DIR=${rocmLLVM.dev}/lib/cmake/llvm"
                  "-DClang_DIR=${rocmClangUW.dev}/lib/cmake/clang"
                  "-DCMAKE_CXX_FLAGS=-I${rocmClangUW.dev}/include"
                  "-DCMAKE_C_FLAGS=-I${rocmClangUW.dev}/include"
                ];
                NIX_LDFLAGS = "${old.NIX_LDFLAGS or ""} -L${rocmClangUW.lib}/lib";
              });

            in {
              inherit openshadinglanguage;
              clangCcacheStdenv = ccacheStdenvClang;
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

        clangCcacheStdenv = pkgs.clangCcacheStdenv;
        rocmPackages      = pkgs.rocmPackages;
        rocmLLVM          = rocmPackages.llvm.llvm;
        rocmClangUW       = rocmPackages.llvm.clang-unwrapped;

        rocmAvailable = pkgs.lib.hasSuffix "linux" system && pkgs.stdenv.hostPlatform.isx86_64;

        src = builtins.path {
          path = ./.;
          name = "blender-source";
          filter = path: type:
            (baseNameOf path != ".git")
            && (baseNameOf path != "flake.nix")
            && (baseNameOf path != "flake.lock");
        };

        blenderDataSrc = pkgs.fetchzip {
          name = "blender-data";
          url = "https://download.blender.org/source/blender-5.1.2.tar.xz";
          hash = "sha256-FnReSNsP8U1/4jSgZN3cMQV2qkP7OZPh0f/9JA1lAxs=";
        };

        commonPreConfigure = ''
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
            rocmPackages      = pkgs.rocmPackages;
          }).overrideAttrs (old: {
            inherit src;
            version = "5.2.0-alpha";
            pname   = bname;

            patches = pkgs.lib.optionals rocmSupport [
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

            postFixup = pkgs.lib.optionalString rocmSupport ''
              patchelf --add-rpath \
                "${rocmLLVM.lib}/lib:${rocmClangUW.lib}/lib" \
                "$out/bin/.blender-wrapped"
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
