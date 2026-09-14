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
// mayhem/harnesses/dng_validate_fuzzer.cpp
//
// Port of OSS-Fuzz's dng_validate_fuzzer (as shipped by the legacy mayhemheroes/dng_sdk layer). It
// fuzzes the `dng_validate` command-line tool's pipeline: the fuzzer picks the CLI's option globals
// (-size/-min/-max, -proxy, -s <plane>, -b4, -cs*, and which of the -dng/-1/-2/-3/-tif dumps to
// write) and the remaining bytes become the input file handed to dng_validate(): parse -> negative
// parse -> stage 1/2/3 -> proxy -> render -> WriteDNG/WriteTIFF.
//
// dng_validate() and its static option globals come from dng_validate_impl.cpp, a build-time shadow
// copy of upstream source/dng_validate.cpp (see mayhem/patch_validate.py), compiled with
// -DqDNGValidateTarget=1 by mayhem/build.sh. Upstream source/ is never modified.
//
// Changes vs the legacy harness (the byte-consumption order is unchanged):
//   * the input and every dump output are mkstemp() files under $TMPDIR (fallback /tmp), unlinked
//     after each iteration (dng_validate_scratch.h), instead of fixed /tmp/libfuzzer-*.<pid> paths;
//   * FinalSpace choices 6 and 7 select DisplayP3 / Rec2020 (the CLI's -csP3 / -cs2020, available in
//     this SDK version); the legacy harness mapped both to sRGB;
//   * the per-stage dng_timer lines (stderr timing chatter only) are switched off.
//
// Seeds (mayhem/dng_validate_fuzzer/testsuite/): the legacy raw DNGs original.dng and poc.dng, plus
// original_cli_opts.dng = original.dng + a 27-byte option tail. FuzzedDataProvider takes every option
// value from the END of the input, so a raw DNG loses its last 27 bytes to them and is rejected early;
// the tail (in consumption order from the end: -size 0 -min 0 -max 0, -dng -1 -2 -3 -tif on, -proxy 0,
// -s -1, no -b4, -cs1) keeps the DNG intact, so the corpus starts through the full pipeline.

#include <fuzzer/FuzzedDataProvider.h>

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

#include "dng_validate_impl.cpp"

#include "dng_validate_scratch.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  gDNGShowTimers = false;

  FuzzedDataProvider provider(data, size);

  // Set the various sizes (-size / -min / -max).
  gPreferredSize = provider.ConsumeIntegral<uint32_t>();
  gMinimumSize = provider.ConsumeIntegral<uint32_t>();
  gMaximumSize = provider.ConsumeIntegral<uint32_t>();

  // Dump outputs (-dng / -1 / -2 / -3 / -tif), each switched on by one fuzzer-chosen bool. SetDump()
  // runs before `&& ok`, so every bool is consumed regardless of an earlier scratch failure.
  std::unique_ptr<ScratchFile> dumpDNG, dumpStage1, dumpStage2, dumpStage3, dumpTIF;
  bool ok = SetDump(gDumpDNG, provider.ConsumeBool(), dumpDNG, "dng_validate_fuzzer-dng");
  ok = SetDump(gDumpStage1, provider.ConsumeBool(), dumpStage1, "dng_validate_fuzzer-stage1") && ok;
  ok = SetDump(gDumpStage2, provider.ConsumeBool(), dumpStage2, "dng_validate_fuzzer-stage2") && ok;
  ok = SetDump(gDumpStage3, provider.ConsumeBool(), dumpStage3, "dng_validate_fuzzer-stage3") && ok;
  ok = SetDump(gDumpTIF, provider.ConsumeBool(), dumpTIF, "dng_validate_fuzzer-tif") && ok;

  gProxyDNGSize = provider.ConsumeIntegral<uint32_t>();  // -proxy
  gMosaicPlane = provider.ConsumeIntegral<int32_t>();    // -s

  gFourColorBayer = provider.ConsumeBool();              // -b4

  switch (provider.ConsumeIntegralInRange(0, 7)) {       // -cs1 .. -cs6, -csP3, -cs2020
    case 0:
      gFinalSpace = &dng_space_sRGB::Get();
      break;
    case 1:
      gFinalSpace = &dng_space_AdobeRGB::Get();
      break;
    case 2:
      gFinalSpace = &dng_space_ProPhoto::Get();
      break;
    case 3:
      gFinalSpace = &dng_space_ColorMatch::Get();
      break;
    case 4:
      gFinalSpace = &dng_space_GrayGamma18::Get();
      break;
    case 5:
      gFinalSpace = &dng_space_GrayGamma22::Get();
      break;
    case 6:
      gFinalSpace = &dng_space_DisplayP3::Get();
      break;
    default:
      gFinalSpace = &dng_space_Rec2020::Get();
      break;
  }

  std::string restData = provider.ConsumeRemainingBytesAsString();
  if (ok && !restData.empty()) {
    ScratchFile input("dng_validate_fuzzer-input");
    if (input.WriteAndClose(reinterpret_cast<const uint8_t *>(restData.data()), restData.size())) {
      // Target
      dng_validate(input.path());
    }
  }

  ClearDumps();
  return 0;
}
