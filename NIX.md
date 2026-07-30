# Building and installing orange with Nix

This flake builds orange (GUI), orange_client (headless), and yolo_offline as a Nix package, on NixOS or any Linux distribution with Nix installed. It packages everything that is open and redistributable — CUDA, TensorRT, OpenCV with contrib, FFmpeg, the ImGui-family submodules — and consumes the proprietary, host-installed pieces (Emergent eSDK, NVIDIA driver, Mellanox/Rivermax stack) from the host system.

## Prerequisites

Nix with flakes enabled (`experimental-features = nix-command flakes` in `nix.conf`).

Unfree packages must be allowed for TensorRT and the NVIDIA driver packages; the flake sets `allowUnfree` internally, so no `NIXPKGS_ALLOW_UNFREE` is needed.

The following must already be installed and working on the host via the vendor installers — Nix does not manage them and the application will not run without them:

| Component | Provided by | Notes |
|---|---|---|
| Emergent eSDK at `/opt/EVT/eSDK` | Emergent installer | Headers/libs consumed at build time, libraries used at run time |
| NVIDIA driver (>= 470) | Distro/NVIDIA installer | Provides `libcuda.so`, `libnvidia-encode.so` (NVENC API 11.1) |
| Mellanox NIC drivers / OFED user-space | Mellanox/Emergent installer | `libibverbs`, `libmlx5`, `librivermax`, resolved from host lib dirs |
| Rivermax license (`rivermax.lic`) | Emergent | Placed per vendor instructions |
| `nvidia_peermem` kernel module | NVIDIA driver install | Required for GPUDirect (`gpu_direct: true` camera configs) |
| Kernel supported by the eSDK (<= 6.5 at time of writing) | Distro | The eSDK NIC stack is kernel-version sensitive |

Verify the camera stack works with Emergent's `eCapture` before blaming this package.

## Quick install

All builds read the host eSDK path at evaluation time, so every build/install command needs `--impure`.

```
git clone <repo-url> && cd orange
```

NixOS:

```
nix profile install --impure .
```

Non-NixOS (Ubuntu etc.) — use the nixGL-wrapped output so OpenGL vendor discovery works:

```
nix profile install --impure .#orange-with-nixgl
```

Binaries land in `~/.nix-profile/bin/`: `orange`, `orange_client`, `yolo_offline`. For an ephemeral run: `nix run --impure .`.

After a host NVIDIA driver upgrade, refresh the baked-in driver version with `nix profile upgrade --impure orange-with-nixgl`.

## How the eSDK is consumed

The eSDK cannot be redistributed, and its runtime is coupled to host state (Rivermax licensing, OFED libraries, NIC drivers, `nvidia_peermem`). The flake therefore treats it as an impure host dependency:

- At build time, the tree at `/opt/EVT/eSDK` is copied into the build sandbox so headers resolve and the linker can see `libEmergentCamera`/`libEmergentGenICam`/`libEmergentGigEVision`. This is why `--impure` is required.
- At run time, the binaries reference the real host install: a forced `DT_RPATH` is patched into each binary, ordered Nix store paths → `/run/opengl-driver/lib` (NixOS driver dir) → `/opt/EVT/eSDK/lib` → `/usr/lib/x86_64-linux-gnu` → `/lib/x86_64-linux-gnu`. `DT_RPATH` (unlike `RUNPATH`) is inherited when the Emergent libraries resolve their own dependencies, so the host OFED/Rivermax/driver libraries are found, while any library the Nix store provides always wins the search order and can never be shadowed by an older host copy.

If the eSDK is installed somewhere other than `/opt/EVT/eSDK`, set `ORANGE_ESDK_PATH=/path/to/eSDK` in the environment when building.

## Running

Camera capture needs raw NIC access, so orange is typically run as root:

```
sudo $(which orange)
```

Per-user data lives in `~/orange_data` (configs, calibration, detection engines). Under sudo, `SUDO_USER` is used to resolve this to the invoking user's home rather than root's. Recordings are written under `/data0` (site convention baked into the app).

Camera configs are read from `~/orange_data/config/{local,network}/<node>/<serial>.json`; example configs ship in `~/.nix-profile/opt/orange/examples/`.

TensorRT `.engine` files for detection are GPU- and TensorRT-version-specific and must be generated on the target machine (see `docs/YOLO.md`); they are not part of the package.

## Updating dependencies

`nix flake update` bumps nixpkgs/nixGL.

The git submodules are pinned by rev + hash in `flake.nix` because the flake source archive omits submodule content. After bumping a submodule pin, update the matching rev in both `flake.nix` and `nix/update-submodule-hashes.sh`, then run:

```
bash nix/update-submodule-hashes.sh
```

and paste the printed hashes into `flake.nix`. Alternatively, set the changed hash to `""` and copy the value from the `got:` line of the build error.

## CUDA architectures

The flake builds for architectures 75, 80, 86, 89, 90 (Turing through Hopper). A plain CMake build defaults to 80 only. Check your GPU with `nvidia-smi --query-gpu=compute_cap --format=csv` and adjust `-DCMAKE_CUDA_ARCHITECTURES` in `flake.nix` `cmakeFlags` if needed.

## Development shell

```
nix develop --impure
cmake -S . -B build -DDIR_FFMPEG=$DIR_FFMPEG -DDIR_TENSORRT=$DIR_TENSORRT -DDIR_ESDK=$DIR_ESDK && cmake --build build -j
```

The shell exports `DIR_FFMPEG`, `DIR_TENSORRT`, and `DIR_ESDK` pointing at the Nix store paths. The legacy non-Nix layout (`~/nvidia/ffmpeg`, `~/nvidia/TensorRT`, `/opt/EVT/eSDK`) remains the CMake default when these are not passed.

## Design notes

- `libnvidia-encode` is a driver library, absent from the build sandbox; the build links against a generated stub exporting the two NVENC entry points, and the real library resolves at run time through the host dirs in `DT_RPATH`.
- FFmpeg is used purely as an MP4 muxer (NVENC is driven directly through the vendored `src/NvEncoder` classes), so the stock nixpkgs FFmpeg is used; it is the same build OpenCV links against, avoiding libavcodec soname conflicts.
- `src = self` (the flake source archive) omits git submodule content, so each public submodule is fetched separately with `fetchFromGitHub` and copied into `third_party/` before the build. `third_party/imgui-filebrowser` is unused by the build and not fetched.
- The `orange` GUI loads fonts relative to the working directory, so `bin/orange` is a wrapper that cd-s into the package's app directory before exec.

## Troubleshooting

**`error: access to absolute path '/opt/EVT/eSDK' is forbidden in pure evaluation mode`** — add `--impure` to the nix command.

**`libcuda.so.1: cannot open shared object file`** — the host NVIDIA driver is missing, or (non-NixOS) the nixGL wrapper was built for a different driver version; rerun `nix profile upgrade --impure orange-with-nixgl`.

**`no kernel image is available for execution on the device`** — the GPU's compute capability is not in the built architecture list; see CUDA architectures above.

**Cameras not detected / stream errors** — verify the host stack first: `lsmod | grep -e mlx5 -e nvidia_peermem`, Rivermax license in place, NIC tuning applied, and that Emergent's own `eCapture` streams successfully.

**Hash mismatch on a submodule fetch** — the rev in `flake.nix` no longer matches the recorded hash; rerun `bash nix/update-submodule-hashes.sh` and paste the new value.
