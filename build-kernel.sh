#!/usr/bin/env bash
# =====================================================================
# C-Local build: picasso (Redmi K30 5G) 4.19 + in-tree KernelSU
# Shared by local WSL2 and GitHub Actions. Put at kernel repo root.
# Repo: EndCredits/kernel_xiaomi_sm7250 branch android-4.19-feat-kernelsu
# =====================================================================
set -euo pipefail
cd "$(dirname "$0")"

DEVICE=picasso
DEFCONFIG=picasso_user_defconfig      # exists in arch/arm64/configs/ (and vendor/)
JOBS=${JOBS:-$(( $(nproc) > 4 ? $(nproc) - 2 : 2 ))}
KSU_PIN_VERSION=${KSU_PIN_VERSION:-381}   # KERNEL_SU_VERSION=10000+381+200=10581 (v0.3.7/v0.3.8 era)
OUT_ROOT=${OUT_ROOT:-/mnt/c/dsh/out}
USE_LLD=${USE_LLD:-1}
USE_CCACHE=${USE_CCACHE:-auto}

log(){ echo "[build-kernel] $*"; }

# ---------- toolchain resolution ----------
TC="${TOOLCHAIN_DIR:-}"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
if [ -n "$TC" ] && [ -x "$TC/bin/clang" ]; then
  export PATH="$TC/bin:$PATH"
  CLANG_BIN=clang; LLD_BIN=ld.lld
  log "using TOOLCHAIN_DIR=$TC ($($(command -v clang || echo "$TC/bin/clang") --version | head -n1))"
elif command -v clang-13 >/dev/null 2>&1; then CLANG_BIN=clang-13; LLD_BIN=ld.lld-13; log "distro clang-13"
elif command -v clang-12 >/dev/null 2>&1; then CLANG_BIN=clang-12; LLD_BIN=ld.lld-12; log "distro clang-12"
elif command -v clang >/dev/null 2>&1; then CLANG_BIN=clang; LLD_BIN=ld.lld; log "distro clang ($($CLANG_BIN --version | head -n1))"
else log "ERROR: no clang found"; exit 1; fi

# ---------- ccache ----------
if [ "$USE_CCACHE" != 0 ] && command -v ccache >/dev/null 2>&1; then
  export CCACHE_BASEDIR="$PWD" CCACHE_COMPILERCHECK=content
  CC_USE="ccache $CLANG_BIN"; HOSTCC_USE="ccache gcc"; CXX_USE="ccache ${CLANG_BIN/clang/clang++}"
  log "ccache ON (CCACHE_DIR=${CCACHE_DIR:-default})"
else
  CC_USE="$CLANG_BIN"; HOSTCC_USE="gcc"; CXX_USE="${CLANG_BIN/clang/clang++}"; log "ccache OFF"
fi

KARGS=(ARCH=arm64 "CC=$CC_USE" "CXX=$CXX_USE" "HOSTCC=$HOSTCC_USE"
       "CLANG_TRIPLE=aarch64-linux-gnu-" "CROSS_COMPILE=$CROSS_COMPILE"
       "LLVM_IAS=1" "KSU_GIT_VERSION=$KSU_PIN_VERSION")
if [ -n "${TOOLCHAIN_DIR:-}" ] && [ -x "$TOOLCHAIN_DIR/bin/arm-linux-gnueabi-gcc" ]; then
  KARGS+=("CROSS_COMPILE_COMPAT=$TOOLCHAIN_DIR/bin/arm-linux-gnueabi-")
fi
if [ "$USE_LLD" = 1 ]; then KARGS+=("LD=$LLD_BIN"); log "linker: $LLD_BIN"; else log "linker: binutils"; fi

[ -d drivers/kernelsu ] || { log "ERROR: drivers/kernelsu missing - wrong branch?"; exit 1; }

# ---------- defconfig ----------
log "defconfig: $DEFCONFIG"
make -j"$JOBS" "${KARGS[@]}" "$DEFCONFIG"
./scripts/config --enable KSU
./scripts/config --disable KSU_DEBUG
make -j"$JOBS" "${KARGS[@]}" olddefconfig
grep -E '^CONFIG_KSU' .config || { log "ERROR: CONFIG_KSU not enabled"; exit 1; }

# ---------- build ----------
log "building Image (+ Image.gz-dtb for reference) with -j$JOBS"
mkdir -p "$OUT_ROOT" 2>/dev/null || { OUT_ROOT="${LOCAL_OUT:-/tmp/kout}"; mkdir -p "$OUT_ROOT"; }
BUILD_LOG="$OUT_ROOT/build-$(date +%Y%m%d-%H%M).log"
set +e
make -j"$JOBS" "${KARGS[@]}" Image 2>&1 | tee "$BUILD_LOG"
rc=${PIPESTATUS[0]}
set -e
if [ "$rc" = 0 ]; then
  make -j"$JOBS" "${KARGS[@]}" Image.gz-dtb dtbs >>"$BUILD_LOG" 2>&1 || log "WARN: secondary targets Image.gz-dtb/dtbs failed (NOT fatal; primary Image is what we flash)"
fi
[ "$rc" = 0 ] || { log "BUILD FAILED (rc=$rc). Log: $BUILD_LOG"; tail -40 "$BUILD_LOG" || true; exit "$rc"; }

# stock picasso boot.img kernel section = UNCOMPRESSED arm64 Image (verified from both
# stock & magisk-patched images); DTB lives in its own section we never touch.
IMG=arch/arm64/boot/Image
[ -f "$IMG" ] || { log "FATAL: $IMG not produced"; exit 1; }
cp -f "$IMG" "$OUT_ROOT/Image"
cp -f arch/arm64/boot/Image.gz-dtb "$OUT_ROOT/Image.gz-dtb" 2>/dev/null || true
if [ "$(od -An -tx1 -j56 -N4 "$IMG" | tr -d ' \n')" != "41524d64" ]; then
  log "WARN: Image lacks ARM64 magic at 0x38"; fi
cp -f "$BUILD_LOG" "$OUT_ROOT/last-build.log" || true
ls -l "$OUT_ROOT/Image.gz-dtb" 2>/dev/null || true
{ echo "clang=$($CLANG_BIN --version | head -n1)"
  echo "linker=$([ "$USE_LLD" = 1 ] && echo "$LLD_BIN" || echo binutils)"
  echo "ksu_git_version=$KSU_PIN_VERSION (KERNEL_SU_VERSION=10581)"
  echo "Image_size=$(stat -c%s "$IMG")";
  echo "stock_kernel_size=50456588 (new Image must stay near this)"; } > "$OUT_ROOT/Image.buildinfo"
ls -l "$OUT_ROOT/Image" "$OUT_ROOT/Image.gz-dtb" 2>/dev/null || true
log "DONE -> $OUT_ROOT/Image  (use repack-boot.mjs <boot.img> this Image <out>)"
