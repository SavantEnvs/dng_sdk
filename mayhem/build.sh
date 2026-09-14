#!/usr/bin/env bash
#
# mayhem/build.sh — build the Adobe DNG SDK fuzz harnesses (five libFuzzer targets) + the
# behavioral oracle probes. Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in
# /mayhem. The base image exports the build contract (CC, CXX, SANITIZER_FLAGS,
# DEBUG_FLAGS, LIB_FUZZING_ENGINE, STANDALONE_FUZZ_MAIN, SRC). The JPEG-XL /
# highway / brotli / jpeg / zlib dev libraries are apt-installed by the Dockerfile.
#
# Configuration decisions (see mayhem/README notes in the PR):
#   * qDNGUseXMP=0 — build WITHOUT the external Adobe XMP toolkit (+expat). XMP is
#     cleanly gated off in the SDK; only dng_jxl.cpp uses the XMP type in two
#     isolated, non-decode spots, which mayhem/patch_jxl.py guards additively via a
#     build-time shadow copy (upstream source stays byte-for-byte pristine).
#   * qDNGUseLibJPEG=1 — lossy-JPEG previews via the system libjpeg.
#   * JPEG-XL is not optional in DNG 1.7.1 (qDNGSupportJXL is retired) — libjxl is
#     linked in.
#   * The library is compiled with $SANITIZER_FLAGS AND -fsanitize=fuzzer-no-link
#     UNCONDITIONALLY so the fuzzed code (not just the harness) carries ASan/UBSan
#     instrumentation and SanCov coverage.
#   * Every ASan-built binary (5 fuzzers + 5 -standalone reproducers) links the
#     build-time LSan off-switch mayhem/lsan_off.cc (__lsan_is_turned_off() -> 1),
#     compiled with $SANITIZER_FLAGS $DEBUG_FLAGS (SPEC.md §6.2 item 15). ASan/UBSan
#     stay fully on; only leak detection is dropped.
#   * UBSan integer-overflow is relaxed (-fno-sanitize=signed-integer-overflow,
#     unsigned-integer-overflow) — and ONLY that. The DNG SDK is *designed* to build
#     with these checks routed to exceptions (Android.bp enables exactly this pair
#     and injects a throwing ubsan runtime); left halting under -fno-sanitize-recover
#     they abort on the SDK's ordinary defensive parsing arithmetic and starve the
#     fuzzer of coverage. ASan and the rest of UBSan stay halting.
#   * dng_validate_fuzzer / dng_fixed_validate_fuzzer (the dng_validate command-line tool's
#     pipeline) link the same library plus a separate validate object set compiled with
#     -DqDNGValidateTarget=1 from a build-time shadow copy of source/dng_validate.cpp — see 2b).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS

cd "$SRC"

# qDNGThreadSafe=1 (unlike the live branch's =0): at this backport's vulnerable commit,
# dng_image_writer.cpp's multi-threaded tile writer (dng_write_tiles_task) unconditionally
# uses dng_condition, which source/dng_mutex.h only defines under qDNGThreadSafe — the class
# fails to parse (and dng_write_tiles_task's own inheritance with it) when it's 0. Needs -lpthread.
DNG_DEFS="-DqLinux=1 -DUNIX_ENV=1 -DqDNGBigEndian=0 -DqDNGThreadSafe=1 \
-DqDNGUseLibJPEG=1 -DqDNGUseXMP=0 -DqDNGValidate=0 -DqDNGValidateTarget=0"
CXXSTD="-std=c++17 -fexceptions -frtti -Wno-unused-parameter -Wno-reorder -Isource"
# Relax ONLY integer-overflow (see header comment). Applied AFTER $SANITIZER_FLAGS.
UBSAN_RELAX="-fno-sanitize=signed-integer-overflow,unsigned-integer-overflow"
LIBS="-ljxl -ljxl_threads -lhwy -lbrotlienc -lbrotlidec -lbrotlicommon -ljpeg -lz -lpthread"

BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"
mkdir -p "$BUILD/obj_san" "$BUILD/obj_clean"

# Additive build-time shadow copy of dng_jxl.cpp (see mayhem/patch_jxl.py). At this backport's
# vulnerable commit the SDK predates JPEG-XL support (no source/dng_jxl.cpp) — skip the patch.
PATCHED_JXL="$BUILD/dng_jxl_patched.cpp"
if [ -f "$SRC/source/dng_jxl.cpp" ]; then
  python3 "$SRC/mayhem/patch_jxl.py" "$SRC/source/dng_jxl.cpp" "$PATCHED_JXL"
fi

# The library source set = source/*.cpp minus:
#   dng_validate      (the dng_validate command-line tool's main())
#   dng_update_meta   (a metadata-rewrite utility, not part of libdng_sdk)
#   dng_xmp,dng_xmp_sdk (XMP backend — excluded because qDNGUseXMP=0)
# dng_jxl is compiled from the shadow-patched copy.
is_excluded() {
  case "$1" in
    dng_validate|dng_update_meta|dng_xmp|dng_xmp_sdk) return 0 ;;
    *) return 1 ;;
  esac
}

SRC_LIST=()
for f in "$SRC"/source/*.cpp; do
  b="$(basename "$f" .cpp)"
  is_excluded "$b" && continue
  if [ "$b" = "dng_jxl" ]; then SRC_LIST+=("$PATCHED_JXL"); else SRC_LIST+=("$f"); fi
done
echo "build.sh: ${#SRC_LIST[@]} library translation units"

# ---- 1) sanitized library (instrumented + SanCov coverage) --------------------
compile_san() {
  local in="$1" out="$2"
  # shellcheck disable=SC2086
  "$CXX" $CXXSTD $DNG_DEFS $SANITIZER_FLAGS $UBSAN_RELAX -fsanitize=fuzzer-no-link \
    $DEBUG_FLAGS -O1 -c "$in" -o "$out"
}
export -f compile_san
export CXX CXXSTD DNG_DEFS SANITIZER_FLAGS UBSAN_RELAX DEBUG_FLAGS
printf '%s\n' "${SRC_LIST[@]}" | \
  xargs -P"$MAYHEM_JOBS" -I{} bash -c 'compile_san "$1" "'"$BUILD"'/obj_san/$(basename "$1" .cpp).o"' _ {}
ar rcs "$BUILD/libdng_san.a" "$BUILD"/obj_san/*.o

# ---- 2) each fuzzer + its standalone reproducer --------------------------------
# StandaloneFuzzTargetMain.c is C — compile it as a C object so its extern "C"
# LLVMFuzzerTestOneInput reference is not mangled by clang++, then link with $CXX.
# shellcheck disable=SC2086
"$CC" $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -x c -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

# Build-time LeakSanitizer off-switch (mayhem/lsan_off.cc, SPEC.md §6.2 item 15): compiled
# with $SANITIZER_FLAGS $DEBUG_FLAGS and linked into EVERY ASan-built binary below (each
# fuzzer AND its -standalone reproducer). Only leak detection is dropped; ASan/UBSan stay on.
LSAN_OFF_OBJ="$BUILD/lsan_off.o"
# shellcheck disable=SC2086
"$CXX" $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -c "$SRC/mayhem/lsan_off.cc" -o "$LSAN_OFF_OBJ"

# Backport: only the kept Mayhemfile target's harness is built. dng_parser_fuzzer and
# dng_stage_fuzzer were dropped (no defects at FUZZED) and their harnesses target a newer
# SDK API (dng_info::IFDCount, dng_negative::GetProfileByID) that doesn't exist at this
# historical commit; building them would need harness-side fixes for binaries no Mayhemfile uses.
HARNESSES="dng_camera_profile_fuzzer"
for h in $HARNESSES; do
  hsrc="$SRC/mayhem/harnesses/$h.cpp"
  # libFuzzer target
  # shellcheck disable=SC2086
  "$CXX" $CXXSTD $DNG_DEFS $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS -O1 $LIB_FUZZING_ENGINE \
    "$hsrc" "$LSAN_OFF_OBJ" "$BUILD/libdng_san.a" $LIBS -o "/mayhem/$h"
  # standalone run-once reproducer (repro artifact, not a Mayhem target)
  # shellcheck disable=SC2086
  "$CXX" $CXXSTD $DNG_DEFS $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS -O1 \
    "$hsrc" "$BUILD/standalone_main.o" "$LSAN_OFF_OBJ" "$BUILD/libdng_san.a" $LIBS -o "/mayhem/$h-standalone"
done

# ---- 2b) dng_validate CLI pipeline defines --------------------------------------
# Backport: dng_validate_fuzzer / dng_fixed_validate_fuzzer are dropped (no defects at FUZZED),
# so the sanitized validate-harness build (shadow dng_validate_impl.cpp, dng_globals_validate.o,
# both fuzz binaries) is skipped. VALIDATE_DEFS is still needed below — the CLEAN dng_validate
# CLI (section 3) that test.sh drives as its own oracle compiles under it.
VALIDATE_DEFS="${DNG_DEFS/-DqDNGValidate=0 -DqDNGValidateTarget=0/-DqDNGValidateTarget=1}"
[ "$VALIDATE_DEFS" != "$DNG_DEFS" ] || { echo "build.sh: cannot derive VALIDATE_DEFS from DNG_DEFS" >&2; exit 1; }

# ---- 3) clean oracle build (NORMAL flags: no sanitizer, no -gdwarf-3) ----------
: "${COVERAGE_FLAGS=}"
compile_clean() {
  local in="$1" out="$2"
  # shellcheck disable=SC2086
  "$CXX" $CXXSTD $DNG_DEFS $COVERAGE_FLAGS -O2 -c "$in" -o "$out"
}
export -f compile_clean
export COVERAGE_FLAGS
printf '%s\n' "${SRC_LIST[@]}" | \
  xargs -P"$MAYHEM_JOBS" -I{} bash -c 'compile_clean "$1" "'"$BUILD"'/obj_clean/$(basename "$1" .cpp).o"' _ {}
ar rcs "$BUILD/libdng_clean.a" "$BUILD"/obj_clean/*.o
# shellcheck disable=SC2086
"$CXX" $CXXSTD $DNG_DEFS $COVERAGE_FLAGS -O2 \
  "$SRC/mayhem/probe_oracle.cpp" "$BUILD/libdng_clean.a" $LIBS -o /mayhem/dng_probe
# The dng_validate command-line tool itself: upstream source/dng_validate.cpp UNMODIFIED (its real
# main) + dng_globals.cpp under VALIDATE_DEFS, against the clean library, so test.sh can assert known
# answers through the same validate pipeline the two dng_validate harnesses fuzz.
# shellcheck disable=SC2086
"$CXX" $CXXSTD $VALIDATE_DEFS $COVERAGE_FLAGS -O2 \
  "$SRC/source/dng_validate.cpp" "$SRC/source/dng_globals.cpp" "$BUILD/libdng_clean.a" $LIBS \
  -o /mayhem/dng_validate

echo "build.sh: done"
ls -la /mayhem/dng_camera_profile_fuzzer /mayhem/dng_probe /mayhem/dng_validate /mayhem/*-standalone
