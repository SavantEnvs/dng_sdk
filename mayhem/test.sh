#!/usr/bin/env bash
#
# mayhem/test.sh — behavioral oracle for the DNG SDK parser and the dng_validate tool.
#
# Runs the CLEAN, dynamically-linked probe (/mayhem/dng_probe, built by build.sh)
# on a fixed, valid DNG fixture and asserts the EXACT geometry the DNG file parser
# (dng_info::Parse / PostParse) decodes from it. Then drives upstream's own
# dng_validate command-line tool (/mayhem/dng_validate, built clean by build.sh) —
# the pipeline the two dng_validate fuzz targets exercise — and asserts exact known
# answers: its success line, a -dng round trip read back by the probe, and the
# CLI's documented exit-code mapping of two SDK errors. Because it compares
# computed values — not just exit status — a program neutered to a no-op
# (verify-repo's sabotage shim _exit(0)s the binary) misses the assertions and the
# oracle FAILS.
#
# Emits a CTRF summary (file + compact `CTRF {...}` stdout marker); exits non-zero
# iff failed>0. Probes are UNCONDITIONAL: a missing binary or fixture is a FAILURE.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

PROBE="/mayhem/dng_probe"
FIXTURE="$SRC/mayhem/dng_parser_fuzzer/testsuite/original.dng"

passed=0; failed=0

check() {
  local desc="$1" expected="$2" out="$3"
  if printf '%s\n' "$out" | grep -qxF "$expected"; then
    echo "PASS: $desc ($expected)"; passed=$((passed+1))
  else
    echo "FAIL: $desc — expected '$expected'"; failed=$((failed+1))
  fi
}

if [ ! -x "$PROBE" ]; then
  echo "FAIL: oracle probe $PROBE missing/not executable (build.sh bug)" >&2
  emit_ctrf "dng-oracle" 0 1; exit 1
fi
if [ ! -f "$FIXTURE" ]; then
  echo "FAIL: oracle fixture $FIXTURE missing" >&2
  emit_ctrf "dng-oracle" 0 1; exit 1
fi

# Parse the fixed DNG once; assert the exact decoded geometry.
OUT="$("$PROBE" "$FIXTURE" 2>/dev/null)"
echo "--- probe output ---"; printf '%s\n' "$OUT"; echo "--------------------"

check "main IFD image width"  "MAIN_WIDTH=384"  "$OUT"
check "main IFD image height" "MAIN_HEIGHT=384" "$OUT"
check "IFD count"             "IFD_COUNT=4"     "$OUT"

# ---- dng_validate command-line tool (the dng_validate fuzz targets' pipeline) ----
VALIDATE="/mayhem/dng_validate"
if [ ! -x "$VALIDATE" ]; then
  echo "FAIL: dng_validate CLI $VALIDATE missing/not executable (build.sh bug)"
  failed=$((failed+1))
else
  SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/dng-oracle.XXXXXX")"
  trap 'rm -rf "$SCRATCH"' EXIT

  # 1) The fixture validates end to end (parse -> negative -> stage 1/2/3): exit 0 and the
  #    tool's own success line.
  VOUT="$("$VALIDATE" "$FIXTURE" 2>/dev/null; echo "EXIT=$?")"
  echo "--- dng_validate output ---"; printf '%s\n' "$VOUT"; echo "---------------------------"
  check "dng_validate: fixture exit status"     "EXIT=0"              "$VOUT"
  check "dng_validate: fixture success message" "Validation complete" "$VOUT"

  # 2) Round trip: -dng re-encodes the negative (plus rendered previews) through
  #    dng_image_writer; the parser probe must read the written DNG back with the
  #    fixture's geometry (main raw IFD + thumbnail + preview = 3 IFDs).
  "$VALIDATE" -dng "$SCRATCH/roundtrip.dng" "$FIXTURE" >/dev/null 2>&1
  RT="$("$PROBE" "$SCRATCH/roundtrip.dng" 2>/dev/null)"
  check "dng_validate -dng round trip: main width"  "MAIN_WIDTH=384"  "$RT"
  check "dng_validate -dng round trip: main height" "MAIN_HEIGHT=384" "$RT"
  check "dng_validate -dng round trip: IFD count"   "IFD_COUNT=3"     "$RT"

  # 3) Error mapping (exit code = DNG SDK error code - 100000 + 100, per dng_validate.cpp):
  #    the fixture's 16-byte TIFF header alone -> dng_error_end_of_file (111);
  #    16 zero bytes (not TIFF) -> dng_error_bad_format (106).
  head -c 16 "$FIXTURE" > "$SCRATCH/header_only.dng"
  head -c 16 /dev/zero  > "$SCRATCH/zeros.dng"
  EOUT="$("$VALIDATE" "$SCRATCH/header_only.dng" >/dev/null 2>&1; echo "EXIT=$?")"
  check "dng_validate: truncated header -> dng_error_end_of_file" "EXIT=111" "$EOUT"
  EOUT="$("$VALIDATE" "$SCRATCH/zeros.dng" >/dev/null 2>&1; echo "EXIT=$?")"
  check "dng_validate: non-TIFF input -> dng_error_bad_format"    "EXIT=106" "$EOUT"
fi

emit_ctrf "dng-oracle" "$passed" "$failed"
