#!/usr/bin/env bash
# Build the third-party libraries the iOS app links, for one target:
#
#   tools/build_ios_deps.sh sim|device
#
# Installs into $DEPS/<target>/ (include/, lib/):
#   SDL2      static, window/input/audio
#   glslang   static, GLSL -> SPIR-V for nv2a_vk (no optimizer, so no
#             SPIRV-Tools; no tools or tests)
#   MoltenVK  copied from the official release's static xcframework
#             (MoltenVK-ios.tar for the device; the iOS-simulator slice of
#             MoltenVK-all.tar for the simulator)
#
# Sources are expected unpacked under $DEPS/src/ or will be auto-downloaded:
#   sdl2/SDL2-<ver>/, glslang/glslang-<ver>/, moltenvk/MoltenVK/ (device),
#   moltenvk-sim/MoltenVK/ (simulator)
#
# Environment:
#   DEPS          default ~/nfsu2/deps
#   IOS_MIN       deployment target (default 16.0)
#   JOBS          parallel jobs (default: hw.ncpu)
set -euo pipefail

TARGET="${1:-sim}"
DEPS="${DEPS:-$HOME/nfsu2/deps}"
IOS_MIN="${IOS_MIN:-16.0}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4)}"

mkdir -p "$DEPS/src/sdl2" "$DEPS/src/glslang"

# Auto-download SDL2 if missing
SDL_URL="https://github.com/libsdl-org/SDL/releases/download/release-2.32.10/SDL2-2.32.10.tar.gz"
if [ -z "$(ls -d "$DEPS"/src/sdl2/SDL2-* 2>/dev/null | head -1)" ]; then
    echo "==> Downloading SDL2..."
    curl -fSL "$SDL_URL" | tar -xz -C "$DEPS/src/sdl2"
fi

# Auto-download glslang if missing
GLSLANG_URL="https://github.com/KhronosGroup/glslang/archive/refs/tags/16.6.0.tar.gz"
if [ -z "$(ls -d "$DEPS"/src/glslang/glslang-* 2>/dev/null | head -1)" ]; then
    echo "==> Downloading glslang..."
    curl -fSL "$GLSLANG_URL" | tar -xz -C "$DEPS/src/glslang"
fi

# Auto-download MoltenVK if missing
MVK_IOS_URL="https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-ios.tar"
MVK_ALL_URL="https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-all.tar"

if [ "$TARGET" = "device" ]; then
    SYSROOT=iphoneos
    if [ ! -d "$DEPS/src/moltenvk" ] || [ -z "$(find "$DEPS/src/moltenvk" -name "libMoltenVK.a" 2>/dev/null | head -1)" ]; then
        echo "==> Downloading MoltenVK (device)..."
        mkdir -p "$DEPS/src/moltenvk"
        curl -fSL "$MVK_IOS_URL" | tar -x -C "$DEPS/src/moltenvk"
    fi
    MVK_SLICE="$(find "$DEPS/src/moltenvk" -type d -name "ios-arm64" 2>/dev/null | head -1)"
    if [ -z "$MVK_SLICE" ]; then
        MVK_SLICE="$DEPS/src/moltenvk/MoltenVK/MoltenVK/static/MoltenVK.xcframework/ios-arm64"
    fi
    MVK_SRC_DIR="$DEPS/src/moltenvk"
elif [ "$TARGET" = "sim" ]; then
    SYSROOT=iphonesimulator
    if [ ! -d "$DEPS/src/moltenvk-sim" ] || [ -z "$(find "$DEPS/src/moltenvk-sim" -name "libMoltenVK.a" 2>/dev/null | head -1)" ]; then
        echo "==> Downloading MoltenVK (simulator)..."
        mkdir -p "$DEPS/src/moltenvk-sim"
        curl -fSL "$MVK_ALL_URL" | tar -x -C "$DEPS/src/moltenvk-sim"
    fi
    MVK_SLICE="$(find "$DEPS/src/moltenvk-sim" -type d -name "ios-arm64_x86_64-simulator" 2>/dev/null | head -1)"
    if [ -z "$MVK_SLICE" ]; then
        MVK_SLICE="$DEPS/src/moltenvk-sim/MoltenVK/MoltenVK/static/MoltenVK.xcframework/ios-arm64_x86_64-simulator"
    fi
    MVK_SRC_DIR="$DEPS/src/moltenvk-sim"
else
    echo "usage: $0 sim|device" >&2
    exit 2
fi

PREFIX="$DEPS/$TARGET"
SDL_SRC="$(ls -d "$DEPS"/src/sdl2/SDL2-* | head -1)"
GLSLANG_SRC="$(ls -d "$DEPS"/src/glslang/glslang-* | head -1)"
IOS_ARGS=(-G Ninja -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SYSROOT"
          -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN"
          -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX")

build() {   # name src extra-args...
    local name="$1" src="$2"; shift 2
    local bdir="$DEPS/build-$TARGET-$name"
    cmake -S "$src" -B "$bdir" "${IOS_ARGS[@]}" "$@" >"$bdir.configure.log" 2>&1 \
        || { echo "$name: configure failed, see $bdir.configure.log" >&2; exit 1; }
    cmake --build "$bdir" -j "$JOBS" >"$bdir.build.log" 2>&1 \
        || { echo "$name: build failed, see $bdir.build.log" >&2; exit 1; }
    cmake --install "$bdir" >/dev/null
    rm -rf "$bdir"                      # disk is tight; the logs stay
    echo "$name: installed into $PREFIX"
}

mkdir -p "$DEPS"
build sdl2 "$SDL_SRC" -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF
build glslang "$GLSLANG_SRC" -DBUILD_SHARED_LIBS=OFF -DENABLE_OPT=OFF \
    -DENABLE_GLSLANG_BINARIES=OFF -DGLSLANG_TESTS=OFF -DGLSLANG_ENABLE_INSTALL=ON \
    -DENABLE_HLSL=OFF -DENABLE_SPVREMAPPER=OFF

mkdir -p "$PREFIX/lib" "$PREFIX/include"
cp "$MVK_SLICE/libMoltenVK.a" "$PREFIX/lib/"

MVK_INC="$(find "$MVK_SRC_DIR" -type d -name "include" 2>/dev/null | grep -v "xcframework" | head -1)"
if [ -n "$MVK_INC" ] && [ -d "$MVK_INC/vulkan" ]; then
    cp -R "$MVK_INC/vulkan" "$MVK_INC/vk_video" "$MVK_INC/MoltenVK" "$PREFIX/include/" 2>/dev/null || true
else
    cp -R "$DEPS/src/moltenvk/MoltenVK/MoltenVK/include/vulkan" \
          "$DEPS/src/moltenvk/MoltenVK/MoltenVK/include/vk_video" \
          "$DEPS/src/moltenvk/MoltenVK/MoltenVK/include/MoltenVK" "$PREFIX/include/" 2>/dev/null || true
fi
echo "MoltenVK: installed into $PREFIX"
