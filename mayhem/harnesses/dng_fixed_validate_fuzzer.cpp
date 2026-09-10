/* Copyright 2021 Google LLC
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
      http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/
// mayhem/harnesses/dng_fixed_validate_fuzzer.cpp
//
// Port of OSS-Fuzz's dng_fixed_validate_fuzzer (as shipped by the legacy mayhemheroes/dng_sdk layer):
// the `dng_validate` command-line tool's pipeline under ONE fixed, deterministic option set — no size
// limits, every dump output on (-dng -1 -2 -3 -tif), -proxy 1024, -s 32, -b4, sRGB — with the whole
// fuzzer input as the file handed to dng_validate().
//
// dng_validate() and its static option globals come from dng_validate_impl.cpp, a build-time shadow
// copy of upstream source/dng_validate.cpp (see mayhem/patch_validate.py), compiled with
// -DqDNGValidateTarget=1 by mayhem/build.sh. Upstream source/ is never modified.
//
// Changes vs the legacy harness: the input and the five dump outputs are mkstemp() files under
// $TMPDIR (fallback /tmp), unlinked after each iteration (dng_validate_scratch.h), instead of fixed
// /tmp/libfuzzer-*.<pid> paths; the per-stage dng_timer lines (stderr timing chatter) are off.

#include <cstddef>
#include <cstdint>
#include <memory>

#include "dng_validate_impl.cpp"

#include "dng_validate_scratch.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  gDNGShowTimers = false;

  // Set the various sizes
  gPreferredSize = 0;
  gMinimumSize = 0;
  gMaximumSize = 0;

  std::unique_ptr<ScratchFile> dumpDNG, dumpStage1, dumpStage2, dumpStage3, dumpTIF;
  bool ok = SetDump(gDumpDNG, true, dumpDNG, "dng_fixed_validate_fuzzer-dng");
  ok = SetDump(gDumpStage1, true, dumpStage1, "dng_fixed_validate_fuzzer-stage1") && ok;
  ok = SetDump(gDumpStage2, true, dumpStage2, "dng_fixed_validate_fuzzer-stage2") && ok;
  ok = SetDump(gDumpStage3, true, dumpStage3, "dng_fixed_validate_fuzzer-stage3") && ok;
  ok = SetDump(gDumpTIF, true, dumpTIF, "dng_fixed_validate_fuzzer-tif") && ok;

  gProxyDNGSize = 1024;
  gMosaicPlane = 32;

  gFourColorBayer = true;
  gFinalSpace = &dng_space_sRGB::Get();

  if (ok) {
    ScratchFile input("dng_fixed_validate_fuzzer-input");
    if (input.WriteAndClose(data, size)) {
      // Target
      dng_validate(input.path());
    }
  }

  ClearDumps();
  return 0;
}
