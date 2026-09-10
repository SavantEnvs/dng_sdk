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

DNG_DEFS="-DqLinux=1 -DUNIX_ENV=1 -DqDNGBigEndian=0 -DqDNGThreadSafe=0 \
-DqDNGUseLibJPEG=1 -DqDNGUseXMP=0 -DqDNGValidate=0 -DqDNGValidateTarget=0"
CXXSTD="-std=c++17 -fexceptions -frtti -Wno-unused-parameter -Wno-reorder -Isource"
# Relax ONLY integer-overflow (see header comment). Applied AFTER $SANITIZER_FLAGS.
UBSAN_RELAX="-fno-sanitize=signed-integer-overflow,unsigned-integer-overflow"
LIBS="-ljxl -ljxl_threads -lhwy -lbrotlienc -lbrotlidec -lbrotlicommon -ljpeg -lz"

BUILD="$SRC/mayhem-build"
rm -rf "$BUILD"
mkdir -p "$BUILD/obj_san" "$BUILD/obj_clean"

# Additive build-time shadow copy of dng_jxl.cpp (see mayhem/patch_jxl.py).
PATCHED_JXL="$BUILD/dng_jxl_patched.cpp"
python3 "$SRC/mayhem/patch_jxl.py" "$SRC/source/dng_jxl.cpp" "$PATCHED_JXL"

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

# One target per OSS-Fuzz harness name (dng_sdk is an OSS-Fuzz project).
HARNESSES="dng_parser_fuzzer dng_camera_profile_fuzzer dng_stage_fuzzer"
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

# ---- 2b) dng_validate harnesses: the dng_validate command-line tool pipeline ----
# dng_validate_fuzzer / dng_fixed_validate_fuzzer (OSS-Fuzz's validate targets, shipped by the legacy
# layer) set the CLI's option globals and call dng_validate(), the per-file driver of upstream's
# `dng_validate` tool: parse -> negative -> stage 1/2/3 -> proxy -> render -> -dng/-tif/-1/-2/-3 dumps.
# Both live in source/dng_validate.cpp, which compiles only under qDNGValidateTarget=1, defines main()
# and keeps dng_validate() + the option globals static. So, as OSS-Fuzz builds them:
#   * mayhem/patch_validate.py writes a BUILD-TIME SHADOW COPY ($VDIR/dng_validate_impl.cpp: CLI main
#     renamed, dng_validate un-static'd, per-file "Validation complete" print dropped) that each
#     harness #includes — upstream source/ stays byte-for-byte pristine;
#   * the harness TUs and source/dng_globals.cpp (which must then also define gVerbose/gDumpLineLimit)
#     are compiled with VALIDATE_DEFS = DNG_DEFS with the validate pair replaced by
#     -DqDNGValidateTarget=1 (dng_flags.h derives qDNGValidate from it);
#   * they link the SAME libdng_san.a as the three targets above, whose build is unchanged
#     (qDNGValidateTarget=0). Mixing is layout-safe: every `#if qDNGValidate` in source/*.h guards only
#     a non-virtual member-function declaration (Dump, WriteUncompressedStream,
#     DestructionOfUnflushedInstancesIsAllowed) or extern declarations, never a data member or a
#     virtual, so class layouts and vtables match on both sides. The directly linked validate
#     dng_globals_validate.o defines every symbol the archive's dng_globals.o does, so that archive
#     member is never pulled in.
# Same $SANITIZER_FLAGS, integer-overflow relaxation, -fsanitize=fuzzer-no-link, $DEBUG_FLAGS and
# lsan_off.o as above. Each harness TU is compiled once and linked twice (target + -standalone).
VDIR="$BUILD/validate"
mkdir -p "$VDIR"
VALIDATE_DEFS="${DNG_DEFS/-DqDNGValidate=0 -DqDNGValidateTarget=0/-DqDNGValidateTarget=1}"
[ "$VALIDATE_DEFS" != "$DNG_DEFS" ] || { echo "build.sh: cannot derive VALIDATE_DEFS from DNG_DEFS" >&2; exit 1; }
python3 "$SRC/mayhem/patch_validate.py" "$SRC/source/dng_validate.cpp" "$VDIR/dng_validate_impl.cpp"

VALIDATE_HARNESSES="dng_validate_fuzzer dng_fixed_validate_fuzzer"
compile_validate() {
  local in="$1" out="$2"
  # shellcheck disable=SC2086
  "$CXX" $CXXSTD $VALIDATE_DEFS $SANITIZER_FLAGS $UBSAN_RELAX -fsanitize=fuzzer-no-link \
    $DEBUG_FLAGS -O1 -I"$VDIR" -c "$in" -o "$out"
}
vpids=()
compile_validate "$SRC/source/dng_globals.cpp" "$VDIR/dng_globals_validate.o" & vpids+=($!)
for h in $VALIDATE_HARNESSES; do
  compile_validate "$SRC/mayhem/harnesses/$h.cpp" "$VDIR/$h.o" & vpids+=($!)
done
for p in "${vpids[@]}"; do wait "$p"; done

for h in $VALIDATE_HARNESSES; do
  # libFuzzer target
  # shellcheck disable=SC2086
  "$CXX" $CXXSTD $VALIDATE_DEFS $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS -O1 $LIB_FUZZING_ENGINE \
    "$VDIR/$h.o" "$VDIR/dng_globals_validate.o" "$LSAN_OFF_OBJ" "$BUILD/libdng_san.a" $LIBS -o "/mayhem/$h"
  # standalone run-once reproducer (repro artifact, not a Mayhem target)
  # shellcheck disable=SC2086
  "$CXX" $CXXSTD $VALIDATE_DEFS $SANITIZER_FLAGS $UBSAN_RELAX $DEBUG_FLAGS -O1 \
    "$VDIR/$h.o" "$BUILD/standalone_main.o" "$VDIR/dng_globals_validate.o" "$LSAN_OFF_OBJ" \
    "$BUILD/libdng_san.a" $LIBS -o "/mayhem/$h-standalone"
done

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
ls -la /mayhem/dng_parser_fuzzer /mayhem/dng_camera_profile_fuzzer /mayhem/dng_stage_fuzzer \
       /mayhem/dng_validate_fuzzer /mayhem/dng_fixed_validate_fuzzer \
       /mayhem/dng_probe /mayhem/dng_validate /mayhem/*-standalone
