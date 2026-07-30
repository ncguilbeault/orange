{
  description = "Orange – multi-camera capture, streaming and recording GUI for Emergent cameras";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixgl = {
      url = "github:nix-community/nixGL";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, nixgl }:
    (flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            # TensorRT and the NVIDIA driver packages are unfree.
            allowUnfree = true;
            # Enables CUDA-aware builds throughout nixpkgs (e.g. OpenCV with CUDA).
            cudaSupport = true;
          };
        };

        cuda = pkgs.cudaPackages;

        # nixGL bridges the Nix store / host GPU driver gap on non-NixOS.
        # Its auto-detection parses /proc/driver/nvidia/version with a regex
        # that only matches the proprietary kernel module format
        # ("... Kernel Module  595.71.05  ..."); the open kernel module,
        # default for driver >= 560 (e.g. Ubuntu 24.04), reports
        # "... Open Kernel Module for x86_64  595.71.05  ..." instead, so
        # detection fails and nixGLDefault silently falls back to the
        # Mesa-only wrapper, which provides no libcuda.  Detect the version
        # here with a regex that accepts both formats and pass it to nixGL
        # explicitly.  Reading /proc keeps the with-nixgl output impure.
        hostNvidiaVersionFile = pkgs.runCommand "impure-host-nvidia-version" {
          # Force a re-read on every evaluation so the wrapper tracks host
          # driver upgrades instead of reusing a stale cached version.
          time = builtins.currentTime;
          preferLocalBuild = true;
          allowSubstitutes = false;
        } "cp /proc/driver/nvidia/version $out 2>/dev/null || touch $out";

        hostNvidiaVersion =
          let
            data = builtins.readFile hostNvidiaVersionFile;
            m = builtins.match ".*Kernel Module( for [A-Za-z0-9_]+)? +([0-9][0-9.]*) .*" data;
          in if m == null then null else builtins.elemAt m 1;

        # Import nixGL as a plain Nix expression rather than via its flake
        # outputs so the detected version can be passed in.  Passing our pkgs
        # also means its allowUnfree covers the NVIDIA driver package nixGL
        # builds, so NIXPKGS_ALLOW_UNFREE=1 is not needed at install time.
        nixglHost = import nixgl {
          inherit pkgs;
          nvidiaVersion = hostNvidiaVersion;
        };

        # ---------------------------------------------------------------------------
        # Emergent eSDK – proprietary, installed on the host by the vendor
        # installer, and deeply coupled to host state: Rivermax licensing,
        # Mellanox/OFED user-space libraries, NIC drivers, and (for GPUDirect)
        # the nvidia_peermem kernel module.  It is therefore consumed as an
        # impure host path, not vendored into the store:
        #
        #   * Build time: the SDK tree is copied into the sandbox (via
        #     builtins.path) purely so headers resolve and the linker can see
        #     the Emergent libraries.  This requires building with --impure.
        #   * Run time: the binaries reference the real host install at
        #     /opt/EVT/eSDK/lib via DT_RPATH (see postFixup below), so the
        #     SDK runs exactly as the vendor installer set it up.
        #
        # Override the host location with ORANGE_ESDK_PATH if the SDK is
        # installed elsewhere.
        # ---------------------------------------------------------------------------
        esdkHostPath =
          let env = builtins.getEnv "ORANGE_ESDK_PATH";
          in if env != "" then env else "/opt/EVT/eSDK";
        esdk = builtins.path { path = /. + esdkHostPath; name = "evt-esdk"; };

        # Host library directories appended to the runtime search path so the
        # eSDK's own dependencies (librivermax, libibverbs, libmlx5, ...)
        # resolve from the host OFED/Rivermax installation.  They come last,
        # so they can never shadow a library the Nix store provides.
        esdkRuntimeLibDirs = [
          "${esdkHostPath}/lib"
          "/usr/lib/x86_64-linux-gnu"
          "/lib/x86_64-linux-gnu"
        ];

        # ---------------------------------------------------------------------------
        # OpenCV built with contrib modules (sfm) and CUDA support.
        # ---------------------------------------------------------------------------
        opencv = pkgs.opencv4.override {
          enableCuda    = true;
          enableContrib = true;
          enableGtk3    = false;
          enablePython  = false;
        };

        # ---------------------------------------------------------------------------
        # FFmpeg – used purely as an MP4 muxer; NVENC is driven directly
        # through the vendored src/NvEncoder classes, not through ffmpeg.
        # The stock nixpkgs build therefore suffices and matches the ffmpeg
        # OpenCV links against, avoiding libavcodec soname conflicts.  The
        # split dev/lib outputs are joined into one prefix so the CMake
        # DIR_FFMPEG cache variable points at include/ and lib/ together.
        # ---------------------------------------------------------------------------
        ffmpeg = pkgs.ffmpeg;
        ffmpegPrefix = pkgs.symlinkJoin {
          name = "ffmpeg-joined";
          paths = [ ffmpeg.dev ffmpeg.lib ];
        };

        # ---------------------------------------------------------------------------
        # Git submodules – src = self (flake archive) omits submodule content
        # because Nix uses git-archive under the hood.  The submodule repos
        # are all public, so each is fetched independently and copied into
        # the source tree via postUnpack.  Revs must match the .gitmodules
        # pins; refresh hashes with nix/update-submodule-hashes.sh.
        # third_party/imgui-filebrowser is a submodule but unused by the
        # build, so it is not fetched.
        # ---------------------------------------------------------------------------
        imgui = pkgs.fetchFromGitHub {
          owner = "ocornut"; repo = "imgui";
          rev   = "3fec562da1d5af5f5c35e236e3e843ef0eadbcf3";
          hash  = "sha256-jKCfCUr+v0bUZnc1t3GUL/vb4ywDz4nor+WWF2brofI=";
        };
        implot = pkgs.fetchFromGitHub {
          owner = "epezent"; repo = "implot";
          rev   = "f156599faefe316f7dd20fe6c783bf87c8bb6fd9";
          hash  = "sha256-+aYeQww8kql54tybGKi1LKbEQHm7RG1tetIBeiiXqE0=";
        };
        imguiFileDialog = pkgs.fetchFromGitHub {
          owner = "aiekick"; repo = "ImGuiFileDialog";
          rev   = "517a4a8b9c4a4f662f811e1f9f0e976fac546def";
          hash  = "sha256-TojBmpY7YJgd0Q6n7Dv6u6C4s6G8FMi83zAVeB5ykuQ=";
        };
        iconFontHeaders = pkgs.fetchFromGitHub {
          owner = "juliettef"; repo = "IconFontCppHeaders";
          rev   = "7d6ff1f4ba51e7a2b142be39457768abece1549c";
          hash  = "sha256-Yo9aWkNzbYc8EIcskhmWBax23Fz0eb+xNDE3J26lP70=";
        };
        flatbuffers = pkgs.fetchFromGitHub {
          owner = "google"; repo = "flatbuffers";
          rev   = "c4211538bd8b46cf321f727cc2600977c44a3b80";
          hash  = "sha256-eS5k04oHU7D+3FAV7gJsDyJKca4k25u4tcD6rjR47b0=";
        };

        orangePkg = pkgs.stdenv.mkDerivation {
          pname   = "orange";
          version = "unstable-2026";

          src = self;

          # Populate the git submodule directories that src = self leaves empty.
          postUnpack = ''
            cp -r --no-preserve=mode ${imgui}/.           "$sourceRoot/third_party/imgui/"
            cp -r --no-preserve=mode ${implot}/.          "$sourceRoot/third_party/implot/"
            cp -r --no-preserve=mode ${imguiFileDialog}/. "$sourceRoot/third_party/ImGuiFileDialog/"
            cp -r --no-preserve=mode ${iconFontHeaders}/. "$sourceRoot/third_party/IconFontCppHeaders/"
            cp -r --no-preserve=mode ${flatbuffers}/.     "$sourceRoot/third_party/flatbuffers/"
          '';

          # libnvidia-encode is a GPU driver library, not part of the CUDA
          # toolkit, and absent from the Nix sandbox at build time.  Create a
          # stub shared lib exporting the two NVENC entry points the vendored
          # NvEncoder classes call so the linker can resolve them.  The real
          # driver-provided library is found at runtime through the DT_RPATH
          # set in postFixup; the stub is never installed.
          preBuild = ''
            cat > nvidia_encode_stub.c << 'EOF'
            void NvEncodeAPICreateInstance()          {}
            void NvEncodeAPIGetMaxSupportedVersion()  {}
            EOF
            cc -shared -fPIC -Wl,-soname,libnvidia-encode.so.1 -o libnvidia-encode.so nvidia_encode_stub.c
            export NIX_LDFLAGS="-L$(pwd) $NIX_LDFLAGS"
          '';

          nativeBuildInputs = with pkgs; [
            cmake
            pkg-config
            cuda.cuda_nvcc
            patchelf
          ];

          buildInputs = with pkgs; [
            # CUDA toolkit (cudart, cuda_driver, NPP, NVTX)
            cuda.cudatoolkit
            cuda.cuda_cudart
            cuda.cuda_nvtx
            cuda.libnpp

            # TensorRT (unfree – requires allowUnfree = true)
            cuda.tensorrt

            # OpenCV with contrib (sfm) + CUDA
            opencv

            # FFmpeg (MP4 muxer only)
            ffmpeg

            # OpenGL / windowing
            glfw
            glew
            libGL
            mesa  # provides libEGL / OpenGL for the build sandbox

            # Networking
            enet
          ];

          cmakeFlags = [
            # Point the build at Nix store paths instead of ~/nvidia/… and
            # the host eSDK (build-time sandbox copy; runtime uses the host
            # install through the DT_RPATH set in postFixup).
            "-DDIR_FFMPEG=${ffmpegPrefix}"
            "-DDIR_TENSORRT=${cuda.tensorrt}"
            "-DDIR_ESDK=${esdk}"

            # Broad CUDA arch coverage: Turing through Hopper.
            "-DCMAKE_CUDA_ARCHITECTURES=75;80;86;89;90"

            # Let CMake find the Nix-provided OpenCV.
            "-DOpenCV_DIR=${opencv}/lib/cmake/opencv4"
          ];

          installPhase = ''
            runHook preInstall

            # GUI binary + fonts + example camera configs
            mkdir -p $out/opt/orange $out/bin
            cp orange $out/opt/orange/orange
            cp -r ${self}/fonts $out/opt/orange/fonts
            mkdir -p $out/opt/orange/examples
            cp ${self}/config/*.json $out/opt/orange/examples/

            # Headless client and offline YOLO tool need no assets.
            cp orange_client yolo_offline $out/bin/

            # Thin wrapper that cd-s into the app dir so relative font paths work.
            cat > $out/bin/orange <<'WRAPPER'
#!/usr/bin/env bash
APPDIR="$(cd "$(dirname "$0")/../opt/orange" && pwd)"
cd "$APPDIR"
exec "$APPDIR/orange" "$@"
WRAPPER
            chmod +x $out/bin/orange

            runHook postInstall
          '';

          # Rewrite the runtime search path as a forced DT_RPATH (not
          # RUNPATH): Nix store paths first, then the NixOS driver dir, then
          # the host eSDK and system library dirs.  DT_RPATH is inherited
          # when the Emergent libraries (which carry no RUNPATH) resolve
          # their own dependencies, so librivermax/libibverbs/libmlx5 and the
          # driver's libcuda/libnvidia-encode fall through to the host dirs,
          # while Nix-provided libraries always win the search order.
          postFixup = ''
            hostDirs="/run/opengl-driver/lib:${pkgs.lib.concatStringsSep ":" esdkRuntimeLibDirs}"
            for exe in $out/opt/orange/orange $out/bin/orange_client $out/bin/yolo_offline; do
              patchelf --force-rpath --set-rpath "$(patchelf --print-rpath $exe):$hostDirs" $exe
            done
          '';

          meta = with pkgs.lib; {
            description = "Multi-camera capture, streaming and recording GUI for Emergent cameras";
            homepage    = "https://github.com/moments-behavior/orange";
            license     = licenses.mit;
            platforms   = [ "x86_64-linux" ];
            maintainers = [];
          };
        };

      in {
        # -------------------------------------------------------------------------
        # Packages.  All package builds read the host eSDK, so they must be
        # run with --impure (see NIX.md).
        # -------------------------------------------------------------------------
        packages.default = orangePkg;

        # Non-NixOS users need nixGL to bridge the Nix store / host driver
        # gap for OpenGL vendor discovery.  The host NVIDIA driver version is
        # read from /proc at evaluation time:
        #   nix profile install --impure .#orange-with-nixgl
        # The baked-in driver version must match the host; rerun
        # `nix profile upgrade --impure` after a host driver update.
        packages.orange-with-nixgl =
          if hostNvidiaVersion == null then
            throw "Cannot detect NVIDIA driver version from /proc/driver/nvidia/version; nixGL wrapper cannot be built.  If you are on NixOS, use .#default instead of .#orange-with-nixgl.  If you are on non-NixOS, ensure the NVIDIA driver is installed and the kernel module is loaded."
          else
            pkgs.runCommand "orange-with-nixgl" {} ''
              mkdir -p $out/bin
              for exe in orange orange_client yolo_offline; do
                cat > $out/bin/$exe <<EOF
#!${pkgs.runtimeShell}
exec ${nixglHost.nixGLCommon nixglHost.nixGLNvidia}/bin/nixGL ${orangePkg}/bin/$exe "\$@"
EOF
                chmod +x $out/bin/$exe
              done
            '';

        # -------------------------------------------------------------------------
        # Development shell – drops you into an environment where you can run
        # cmake -S . -B build && cmake --build build -j  without extra setup.
        # Reads the host eSDK, so enter it with: nix develop --impure
        # -------------------------------------------------------------------------
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            cmake
            pkg-config
            patchelf
            cuda.cuda_nvcc
            cuda.cudatoolkit
            cuda.cuda_cudart
            cuda.cuda_nvtx
            cuda.libnpp
            cuda.tensorrt
            opencv
            ffmpeg
            glfw
            glew
            libGL
            mesa
            enet
          ];

          shellHook = ''
            export DIR_FFMPEG="${ffmpegPrefix}"
            export DIR_TENSORRT="${cuda.tensorrt}"
            export DIR_ESDK="${esdk}"
            echo "Orange dev shell ready."
            echo "  Build: cmake -S . -B build -DDIR_FFMPEG=$DIR_FFMPEG -DDIR_TENSORRT=$DIR_TENSORRT -DDIR_ESDK=$DIR_ESDK -DOpenCV_DIR=${opencv}/lib/cmake/opencv4 && cmake --build build -j"
          '';
        };
      }
    )) // {
      # -------------------------------------------------------------------------
      # NixOS module – system-agnostic, lives outside eachSystem.
      # Add to your configuration.nix imports:
      #   imports = [ orange.nixosModules.default ];
      #   programs.orange.enable = true;
      # -------------------------------------------------------------------------
      nixosModules.default = { config, lib, pkgs, ... }:
        let cfg = config.programs.orange; in {
          options.programs.orange.enable =
            lib.mkEnableOption "Orange multi-camera capture GUI";

          config = lib.mkIf cfg.enable {
            hardware.nvidia.enable    = lib.mkDefault true;
            hardware.opengl.enable    = lib.mkDefault true;
            environment.systemPackages =
              [ self.packages.x86_64-linux.default ];
          };
        };
    };
}
