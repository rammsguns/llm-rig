#!/usr/bin/env bash
# Build llama.cpp from source with CUDA, targeting THIS GPU's compute capability.
# A generic/prebuilt binary ships fat kernels for every arch and misses
# arch-specific paths; a targeted build is typically 5-15% faster and starts quicker.
set -uo pipefail
source "$(dirname "$0")/lib/detect.sh"
detect_hw

c_info "Building llama.cpp for compute capability $GPU_CC (arch $CUDA_ARCH)"

# Belt and braces: if a stale CC/CXX is exported from a previous shell, unset it
# so CMake falls back to detecting gcc/g++ normally.
if [[ -n "${CC:-}" && ! -x "$(command -v "${CC:-}" 2>/dev/null)" ]]; then
  c_warn "Unsetting bogus CC='$CC' inherited from the environment"
  unset CC
fi
if [[ -n "${CXX:-}" && ! -x "$(command -v "${CXX:-}" 2>/dev/null)" ]]; then
  unset CXX
fi

# --- deps -------------------------------------------------------------------
c_info "Installing build dependencies"
sudo apt-get update -qq
sudo apt-get install -y -qq build-essential cmake git ccache libcurl4-openssl-dev pkg-config python3-pip

if ! need nvcc; then
  c_warn "nvcc not found. Installing the CUDA toolkit from Pop!_OS repos."
  # --no-install-recommends: the full package otherwise drags in openjdk-8 and
  # nvidia-visual-profiler, which are ~500MB of things we will never use.
  sudo apt-get install -y -qq --no-install-recommends nvidia-cuda-toolkit \
    || die "CUDA toolkit install failed. Install it manually, then re-run."
fi
NVCC_VER=$(nvcc --version | grep -oP 'release \K[0-9]+\.[0-9]+')
c_ok "nvcc $NVCC_VER"

# --- source -----------------------------------------------------------------
mkdir -p "$(dirname "$LLAMA_DIR")"
if [[ -d "$LLAMA_DIR/.git" ]]; then
  c_info "Updating existing checkout"
  git -C "$LLAMA_DIR" fetch --depth=1 origin master
  git -C "$LLAMA_DIR" reset --hard origin/master
else
  c_info "Cloning llama.cpp"
  git clone --depth=1 https://github.com/ggml-org/llama.cpp "$LLAMA_DIR"
fi
BUILD_REV=$(git -C "$LLAMA_DIR" rev-parse --short HEAD)
c_ok "at $BUILD_REV"

# --- configure --------------------------------------------------------------
# GGML_CUDA_FA_ALL_QUANTS: compiles flash-attention kernels for every KV quant
# combination. Costs build time, but without it a quantized KV cache silently
# falls back to a slow path -- and we depend on q8_0 KV to fit long contexts.
cd "$LLAMA_DIR"
rm -rf build

# --- CUDA / host-gcc compatibility -----------------------------------------
# nvcc rejects host compilers newer than it supports. Ubuntu 24.04 ships gcc-13
# while the repo CUDA toolkit is 12.0, whose ceiling is gcc-12 -- that mismatch
# fails with "unsupported GNU version! gcc versions later than 12 are not
# supported". Detect and pin an acceptable host compiler.
CUDA_MAJOR=${NVCC_VER%%.*}
CUDA_MINOR=${NVCC_VER##*.}
case "$CUDA_MAJOR.$CUDA_MINOR" in
  12.0|12.1|12.2|12.3) MAX_GCC=12 ;;
  12.4|12.5|12.6)      MAX_GCC=13 ;;
  *)                   MAX_GCC=14 ;;   # 12.8+ / 13.x
esac
HOST_GCC_VER=$(gcc -dumpversion | cut -d. -f1)
CUDA_HOST_FLAG=()
if (( HOST_GCC_VER > MAX_GCC )); then
  c_warn "gcc-$HOST_GCC_VER is too new for CUDA $NVCC_VER (max gcc-$MAX_GCC)"
  if ! need "gcc-$MAX_GCC"; then
    c_info "Installing gcc-$MAX_GCC / g++-$MAX_GCC as the CUDA host compiler"
    sudo apt-get install -y -qq "gcc-$MAX_GCC" "g++-$MAX_GCC" \
      || die "could not install gcc-$MAX_GCC; install a newer CUDA toolkit instead"
  fi
  CUDA_HOST_FLAG=( "-DCMAKE_CUDA_HOST_COMPILER=$(command -v "gcc-$MAX_GCC")" )
  c_ok "pinning CUDA host compiler to gcc-$MAX_GCC (C/C++ still use gcc-$HOST_GCC_VER)"
fi

cmake -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DGGML_CUDA=ON \
  -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
  -DGGML_CUDA_FA_ALL_QUANTS=ON \
  -DGGML_NATIVE=ON \
  -DLLAMA_CURL=ON \
  -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=ON \
  -DCMAKE_C_COMPILER_LAUNCHER=ccache \
  -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
  "${CUDA_HOST_FLAG[@]}" \
  || die "cmake configure failed"

c_info "Compiling with $(nproc) jobs (this takes 5-20 min the first time)"
cmake --build build --config Release -j"$(nproc)" || die "build failed"

# --- install ----------------------------------------------------------------
c_info "Linking binaries into /usr/local/bin"
for b in llama-server llama-cli llama-bench llama-quantize llama-perplexity; do
  if [[ -x "$LLAMA_DIR/build/bin/$b" ]]; then
    sudo ln -sf "$LLAMA_DIR/build/bin/$b" "/usr/local/bin/$b"
    c_ok "$b"
  fi
done

echo
llama-server --version 2>&1 | head -3
c_info "Verifying CUDA is actually linked"
if llama-cli --list-devices 2>&1 | grep -qi cuda; then
  llama-cli --list-devices 2>&1 | grep -i -A2 cuda
  c_ok "CUDA backend present"
else
  die "CUDA backend NOT present -- the build fell back to CPU only. Check nvcc + driver."
fi
echo "$BUILD_REV" > "$RIG_DIR/.llamacpp-rev"
