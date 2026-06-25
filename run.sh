#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
DIR_FFMPEG=$HOME/nvidia/ffmpeg
DIR_TENSORRT=$HOME/nvidia/TensorRT
LD_LIBRARY_PATH=/usr/local/cuda/lib64:$DIR_FFMPEG/build/lib:$DIR_TENSORRT/lib

mkdir -p "$LOG_DIR"

TIMESTAMP="$(date +%Y-%m-%dT%H-%M-%S%z)"
LOG_FILE="$LOG_DIR/run-$TIMESTAMP.log"

{
    echo "=== launched: $(date -Iseconds) ==="
    echo
} >"$LOG_FILE"

sudo LD_LIBRARY_PATH=$LD_LIBRARY_PATH ./targets/orange 2>&1 | tee -a "$LOG_FILE"
EXIT_CODE="${PIPESTATUS[0]}"

{
    echo
    echo "=== exited: $(date -Iseconds) (status $EXIT_CODE) ==="
} >>"$LOG_FILE"

exit "$EXIT_CODE"



