// mayhem/harnesses/dng_fuzz.cpp
//
// libFuzzer harness for the Adobe DNG SDK parser. Byte-in only: the fuzzer bytes
// are wrapped in an in-memory dng_memory_stream (NO file I/O), then driven through
// the DNG file parser (dng_info::Parse / PostParse), and, for a valid DNG, the
// negative parse + Stage-1 image decode (dng_negative + dng_image via the read path).
//
// This mirrors upstream's own fuzzer/dng_parser_fuzzer.cpp (kept additive under
// mayhem/ so it is never picked up as an ordinary source file). The SDK throws
// dng_exception on malformed input — that is normal, so we catch it and return 0;
// only an ASan/UBSan report or a genuine crash is a finding.

#include <stddef.h>
#include <stdint.h>

#include <memory>

#include "dng_exceptions.h"
#include "dng_host.h"
#include "dng_info.h"
#include "dng_memory_stream.h"
#include "dng_negative.h"

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  dng_host host;
  dng_memory_stream stream(host.Allocator());

  // In-memory only: copy the fuzzer bytes into the stream, no filesystem access.
  stream.Put(data, size);
  stream.SetReadPosition(0);

  std::unique_ptr<dng_negative> negative(host.Make_dng_negative());

  try {
    dng_info info;
    info.Parse(host, stream);
    info.PostParse(host);

    if (info.IsValidDNG()) {
      negative->Parse(host, stream, info);
      negative->PostParse(host, stream, info);
      negative->ReadStage1Image(host, stream, info);
    }
  } catch (dng_exception &) {
    // dng_sdk throws C++ exceptions on bad input; swallow them so libFuzzer
    // does not treat an expected parse rejection as a crash.
  }

  return 0;
}
