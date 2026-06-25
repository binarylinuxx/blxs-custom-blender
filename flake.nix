{
  description = "Blender from local source";

  nixConfig = {
    extra-substituters = [
      "https://blxs-custom-blender.cachix.org"
    ];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/4100e830e085863741bc69b156ec4ccd53ab5be0";
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
              rocmPackages = prev.rocmPackages // {
                rocm-comgr = prev.rocmPackages.rocm-comgr.overrideAttrs (old: {
                  patches = (old.patches or []) ++ [
                    ./comgr-prefer-libclang-cpp.patch
                  ];
                });
              };
              clangCcacheStdenv = ccacheStdenvClang;
              ccacheWrapper = prev.ccacheWrapper.override {
                extraConfig = ''
                  export CCACHE_COMPRESS=1
                  export CCACHE_SLOPPINESS=random_seed
                  export CCACHE_DIR=''${CCACHE_DIR:-''${TMPDIR:-/tmp}/ccache}
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

          find "${blenderDataSrc}/release/datafiles" -type f \
            | while IFS= read -r datafile; do
                relpath="''${datafile#${blenderDataSrc}/}"
                if [ ! -f "$relpath" ]; then
                  mkdir -p "$(dirname "$relpath")"
                  cp "$datafile" "$relpath"
                  echo "Restored: $relpath"
                fi
              done
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
            version = "5.3.0-alpha";
            pname   = bname;
            patches =
              builtins.filter
                (patch:
                  ! builtins.elem (baseNameOf (toString patch)) [
                    "fix-quite-clog-warning.patch"
                    "hiprt-3-compat.patch"
                  ])
                (old.patches or [ ])
              ++ pkgs.lib.optionals rocmSupport [
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
                --replace-fail '"libamdhip64.so.7"' \
                '"${pkgs.rocmPackages.clr}/lib/libamdhip64.so"'
              substituteInPlace extern/hipew/src/hipew.c \
                --replace-fail '"/opt/rocm/lib/libamdhip64.so.7"' \
                '"${pkgs.rocmPackages.clr}/lib/libamdhip64.so"'
              substituteInPlace extern/hipew/src/hipew.c \
                --replace-fail '"/opt/rocm/hip/lib/libamdhip64.so.${pkgs.lib.versions.major pkgs.rocmPackages.clr.version}"' \
                '"${pkgs.rocmPackages.clr}/lib/libamdhip64.so"'
              substituteInPlace extern/hipew/src/hipew.c \
                --replace-fail '"opt/rocm/hip/bin"' \
                '"${pkgs.rocmPackages.clr}/bin"'
            '';

            buildInputs = (old.buildInputs or []) ++ pkgs.lib.optionals rocmSupport [
              pkgs.rocmPackages.rocm-comgr
            ];

            pythonPath = (old.pythonPath or []) ++ [
              pkgs.python313Packages.cattrs
            ];

            postFixup = pkgs.lib.optionalString rocmSupport ''
              patchelf --add-rpath \
                "${rocmLLVM.lib}/lib:${rocmClangUW.lib}/lib:${pkgs.rocmPackages.rocm-comgr}/lib" \
                "$out/bin/.blender-wrapped"
              substituteInPlace "$out/bin/blender" \
                --replace-fail 'exec -a "$0" ' \
                'export LD_LIBRARY_PATH="${pkgs.rocmPackages.rocm-comgr}/lib:${rocmClangUW.lib}/lib:${rocmLLVM.lib}/lib''${LD_LIBRARY_PATH:+:}''${LD_LIBRARY_PATH}"; exec -a "$0" '
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
      let
        blender = mkBlender {
          rocmSupport = rocmAvailable;
        };
      in
      {
        packages = {
          default = blender;
          blxs-custom-blender = blender;
        };

        apps.default = {
          type = "app";
          program = "${blender}/bin/blender";
        };

        devShells.default = pkgs.mkShell {
          inputsFrom = [ self.packages.${system}.default ];
          nativeBuildInputs = with pkgs; [ cmake git-lfs pkg-config ];
        };
      }
    );
}
