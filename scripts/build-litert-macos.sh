#!/usr/bin/env bash
# Builds merged libc_engine.a for macOS arm64, iOS arm64, and iOS sim arm64
# from the LiteRT-LM submodule, and copies prebuilt dylibs for macOS.
#
# Usage: scripts/build-litert-macos.sh [macos_arm64|ios_arm64|ios_sim_arm64|all]
# Defaults to 'all'. Run from the repo root or from Xcode.

set -euo pipefail

# Xcode's sandboxed shell has a minimal PATH — add Homebrew locations
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LITERT_DIR="$REPO_ROOT/LiteRT-LM"
LIB_BASE="$REPO_ROOT/build/lib"
TARGET="${1:-all}"

# ---------------------------------------------------------------------------
# Git LFS — pull prebuilt dylibs (macOS only needs this)
# ---------------------------------------------------------------------------
echo "==> Pulling LiteRT-LM Git LFS prebuilt dylibs..."
pull_lfs_dylib() {
  local PLATFORM="$1"
  local DYLIB="$LITERT_DIR/prebuilt/$PLATFORM/libGemmaModelConstraintProvider.dylib"
  # Check if it's still an LFS pointer (ASCII text, < 200 bytes)
  if [ -f "$DYLIB" ] && file "$DYLIB" | grep -q "Mach-O"; then
    echo "    [$PLATFORM] dylib already downloaded."
    return
  fi
  if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
    git -C "$LITERT_DIR" lfs pull --include="prebuilt/$PLATFORM/*.dylib"
  else
    # No git-lfs: download directly via LFS batch API
    local POINTER_FILE="$DYLIB"
    if [ ! -f "$POINTER_FILE" ]; then
      echo "ERROR: [$PLATFORM] prebuilt dylib missing and git-lfs not installed."
      exit 1
    fi
    local OID SIZE
    OID=$(grep "^oid sha256:" "$POINTER_FILE" | awk '{print $2}' | sed 's/sha256://')
    SIZE=$(grep "^size" "$POINTER_FILE" | awk '{print $2}')
    echo "    [$PLATFORM] Downloading via LFS API (${SIZE} bytes)..."
    local RESP URL
    RESP=$(curl -s -X POST \
      -H "Accept: application/vnd.git-lfs+json" \
      -H "Content-Type: application/vnd.git-lfs+json" \
      -d "{\"operation\":\"download\",\"transfers\":[\"basic\"],\"objects\":[{\"oid\":\"$OID\",\"size\":$SIZE}]}" \
      "https://github.com/google-ai-edge/LiteRT-LM.git/info/lfs/objects/batch")
    URL=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['objects'][0]['actions']['download']['href'])")
    curl -s -L -o "$DYLIB" "$URL"
    echo "    [$PLATFORM] Downloaded $(ls -lh "$DYLIB" | awk '{print $5}')."
  fi
}

case "$TARGET" in
  macos_arm64|all) pull_lfs_dylib macos_arm64 ;;
esac
case "$TARGET" in
  ios_arm64|all) pull_lfs_dylib ios_arm64 ;;
esac
case "$TARGET" in
  ios_sim_arm64|all) pull_lfs_dylib ios_sim_arm64 ;;
esac
DYLIB_PATH="$LITERT_DIR/prebuilt/macos_arm64/libGemmaModelConstraintProvider.dylib"

# ---------------------------------------------------------------------------
# build_platform <platform> <bazel_configs> <bazel_cpu_dir>
#   platform     : macos_arm64 | ios_arm64 | ios_sim_arm64
#   bazel_configs: space-separated list of --config values (e.g. "macos macos_arm64")
#   bazel_cpu_dir: bazel-out subdirectory prefix (e.g. darwin_arm64-opt)
# ---------------------------------------------------------------------------
build_platform() {
  local PLATFORM="$1"
  local BAZEL_CONFIGS="$2"
  local CPU_DIR="$3"
  local OUT_DIR="$LIB_BASE/$PLATFORM"
  local BAZEL_OUT="$LITERT_DIR/bazel-out/${CPU_DIR}/bin"
  local PARAMS="$BAZEL_OUT/c/engine_test-2.params"

  if [ -f "$OUT_DIR/libc_engine.a" ]; then
    echo "==> [$PLATFORM] libc_engine.a already exists — skipping."
    echo "    (Delete $OUT_DIR/libc_engine.a to force a rebuild.)"
    return
  fi

  echo "==> [$PLATFORM] Building LiteRT-LM engine_test..."
  cd "$LITERT_DIR"
  local CONFIG_FLAGS=""
  for cfg in $BAZEL_CONFIGS; do
    CONFIG_FLAGS="$CONFIG_FLAGS --config=$cfg"
  done
  bazel build //c:engine_test $CONFIG_FLAGS

  echo "==> [$PLATFORM] Merging static libraries..."
  local TMPDIR
  TMPDIR="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$TMPDIR'" EXIT

  local LIBS
  LIBS=$(grep -E '\.(a|lo)$' "$PARAMS" \
    | sed 's/-Wl,-force_load,//' \
    | grep -v 'engine_test\.o' \
    | grep -v 'libgtest' \
    | grep -v 'status_matchers' \
    | sed "s|bazel-out/${CPU_DIR}/bin/|$BAZEL_OUT/|g")

  local IDX=0
  while IFS= read -r lib; do
    if [ -f "$lib" ]; then
      local SUBDIR="$TMPDIR/lib_$(printf '%04d' $IDX)"
      mkdir -p "$SUBDIR"
      (cd "$SUBDIR" && ar -x "$lib" 2>/dev/null) || true
      IDX=$((IDX + 1))
    fi
  done <<< "$LIBS"

  find "$TMPDIR" -name "__.SYMDEF*" -delete

  local OBJ_COUNT
  OBJ_COUNT=$(find "$TMPDIR" -name "*.o" | wc -l | tr -d ' ')
  echo "    Extracted $OBJ_COUNT object files from $IDX archives"

  mkdir -p "$OUT_DIR"
  # libtool -static with many files: pass via file list to avoid ARG_MAX
  # Build into TMPDIR first to avoid Xcode sandbox blocking libtool's temp files
  find "$TMPDIR" -name "*.o" | sort > "$TMPDIR/objects.lst"
  libtool -static -o "$TMPDIR/libc_engine.a" \
    -filelist "$TMPDIR/objects.lst" 2>&1 \
    | grep -v "has no symbols" || true
  cp "$TMPDIR/libc_engine.a" "$OUT_DIR/libc_engine.a"

  echo "    $(ls -lh "$OUT_DIR/libc_engine.a" | awk '{print $5}') → $OUT_DIR/libc_engine.a"
  trap - EXIT
  rm -rf "$TMPDIR"
}

# ---------------------------------------------------------------------------
# Copy prebuilt dylib for a given platform
# ---------------------------------------------------------------------------
copy_dylib() {
  local PLATFORM="$1"
  local OUT_DIR="$LIB_BASE/$PLATFORM"
  local SRC="$LITERT_DIR/prebuilt/$PLATFORM/libGemmaModelConstraintProvider.dylib"
  mkdir -p "$OUT_DIR"
  if [ -f "$OUT_DIR/libGemmaModelConstraintProvider.dylib" ]; then
    echo "==> [$PLATFORM] dylib already present — skipping copy."
  else
    cp "$SRC" "$OUT_DIR/"
    echo "==> [$PLATFORM] Copied libGemmaModelConstraintProvider.dylib"
  fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$TARGET" in
  macos_arm64)
    build_platform macos_arm64 "macos macos_arm64" "darwin_arm64-opt"
    copy_dylib macos_arm64
    ;;
  ios_arm64)
    build_platform ios_arm64 "ios ios_arm64" "ios_arm64-opt"
    copy_dylib ios_arm64
    ;;
  ios_sim_arm64)
    build_platform ios_sim_arm64 "ios_sim_arm64" "ios_sim_arm64-opt"
    copy_dylib ios_sim_arm64
    ;;
  all)
    build_platform macos_arm64 "macos macos_arm64" "darwin_arm64-opt"
    copy_dylib macos_arm64
    build_platform ios_arm64 "ios ios_arm64" "ios_arm64-opt"
    copy_dylib ios_arm64
    build_platform ios_sim_arm64 "ios_sim_arm64" "ios_sim_arm64-opt"
    copy_dylib ios_sim_arm64
    ;;
  *)
    echo "Usage: $0 [macos_arm64|ios_arm64|ios_sim_arm64|all]"
    exit 1
    ;;
esac

echo "==> Done. Artifacts ready for: $TARGET"
