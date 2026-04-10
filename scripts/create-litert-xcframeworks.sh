#!/usr/bin/env bash
# Creates two xcframeworks from the pre-built LiteRT-LM platform slices:
#
#   build/xcframeworks/LiteRTLM.xcframework
#       Static library (libc_engine.a) + C API header + module map
#       → drag into Xcode "Frameworks, Libraries, and Embedded Content"
#         (set to "Do Not Embed")
#
#   build/xcframeworks/GemmaModelConstraintProvider.xcframework
#       Dynamic library (libGemmaModelConstraintProvider.dylib)
#       → drag into Xcode "Frameworks, Libraries, and Embedded Content"
#         (set to "Embed & Sign")
#
# Prerequisites: run  scripts/build-litert-macos.sh all  first.
#
# Usage: scripts/create-litert-xcframeworks.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_BASE="$REPO_ROOT/build/lib"
HEADER_SRC="$REPO_ROOT/LiteRT-LM/c/engine.h"
OUT_DIR="$REPO_ROOT/build/xcframeworks"

PLATFORMS=(macos_arm64 ios_arm64 ios_sim_arm64)

# ---------------------------------------------------------------------------
# Preflight — make sure all platform slices exist
# ---------------------------------------------------------------------------
echo "==> Checking pre-built artifacts..."
MISSING=0
for PLATFORM in "${PLATFORMS[@]}"; do
  for FILE in libc_engine.a libGemmaModelConstraintProvider.dylib; do
    if [ ! -f "$LIB_BASE/$PLATFORM/$FILE" ]; then
      echo "    MISSING: $LIB_BASE/$PLATFORM/$FILE"
      MISSING=1
    fi
  done
done
if [ ! -f "$HEADER_SRC" ]; then
  echo "    MISSING: $HEADER_SRC"
  MISSING=1
fi
if [ "$MISSING" -eq 1 ]; then
  echo "ERROR: Run  scripts/build-litert-macos.sh all  first."
  exit 1
fi
echo "    All artifacts present."

# ---------------------------------------------------------------------------
# Prepare headers directory (shared across all platforms)
# ---------------------------------------------------------------------------
TMPDIR="$(mktemp -d)"
trap "rm -rf '$TMPDIR'" EXIT

HEADERS_DIR="$TMPDIR/headers"
mkdir -p "$HEADERS_DIR"
cp "$HEADER_SRC" "$HEADERS_DIR/"

cat > "$HEADERS_DIR/module.modulemap" <<'MODULEMAP'
module LiteRTLM {
    header "engine.h"
    export *
}
MODULEMAP

# ---------------------------------------------------------------------------
# Build LiteRTLM.xcframework (static library)
# ---------------------------------------------------------------------------
rm -rf "$OUT_DIR/LiteRTLM.xcframework"
mkdir -p "$OUT_DIR"

echo "==> Creating LiteRTLM.xcframework (static)..."
xcodebuild -create-xcframework \
  -library "$LIB_BASE/ios_arm64/libc_engine.a" \
    -headers "$HEADERS_DIR" \
  -library "$LIB_BASE/ios_sim_arm64/libc_engine.a" \
    -headers "$HEADERS_DIR" \
  -library "$LIB_BASE/macos_arm64/libc_engine.a" \
    -headers "$HEADERS_DIR" \
  -output "$OUT_DIR/LiteRTLM.xcframework"

echo "    $(du -sh "$OUT_DIR/LiteRTLM.xcframework" | awk '{print $1}') → $OUT_DIR/LiteRTLM.xcframework"

# ---------------------------------------------------------------------------
# Build GemmaModelConstraintProvider.xcframework (dynamic library)
# ---------------------------------------------------------------------------
rm -rf "$OUT_DIR/GemmaModelConstraintProvider.xcframework"

echo "==> Creating GemmaModelConstraintProvider.xcframework (dynamic)..."

# xcodebuild -create-xcframework needs the dylib install_name to encode the
# correct rpath.  The prebuilt dylibs may have a Bazel-relative install_name,
# so we copy them to a temp dir and fix up with install_name_tool.
for PLATFORM in "${PLATFORMS[@]}"; do
  PDIR="$TMPDIR/dylibs/$PLATFORM"
  mkdir -p "$PDIR"
  cp "$LIB_BASE/$PLATFORM/libGemmaModelConstraintProvider.dylib" "$PDIR/"
  install_name_tool -id \
    "@rpath/libGemmaModelConstraintProvider.dylib" \
    "$PDIR/libGemmaModelConstraintProvider.dylib" 2>/dev/null || true
done

xcodebuild -create-xcframework \
  -library "$TMPDIR/dylibs/ios_arm64/libGemmaModelConstraintProvider.dylib" \
  -library "$TMPDIR/dylibs/ios_sim_arm64/libGemmaModelConstraintProvider.dylib" \
  -library "$TMPDIR/dylibs/macos_arm64/libGemmaModelConstraintProvider.dylib" \
  -output "$OUT_DIR/GemmaModelConstraintProvider.xcframework"

echo "    $(du -sh "$OUT_DIR/GemmaModelConstraintProvider.xcframework" | awk '{print $1}') → $OUT_DIR/GemmaModelConstraintProvider.xcframework"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "==> Done.  Two xcframeworks created in $OUT_DIR/"
echo ""
echo "    Xcode integration:"
echo "      1. Drag both .xcframework bundles into your target's"
echo "         \"Frameworks, Libraries, and Embedded Content\"."
echo "      2. Set LiteRTLM.xcframework to \"Do Not Embed\"."
echo "      3. Set GemmaModelConstraintProvider.xcframework to \"Embed & Sign\"."
echo "      4. Add  -lc++  to OTHER_LDFLAGS."
echo "      5. Add  -Wl,-force_load,\$(BUILD_DIR)/LiteRTLM.xcframework/..."
echo "         or use  -force_load  via Xcode's \"Other Linker Flags\"."
