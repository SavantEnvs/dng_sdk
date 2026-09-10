// mayhem/harnesses/dng_camera_profile_fuzzer.cpp
//
// In-process, byte-in port of the OSS-Fuzz dng_camera_profile_fuzzer. Parses an
// extended camera-profile (DCP-style) stream and computes its fingerprint. The
// upstream OSS-Fuzz version wrote the bytes to /tmp and re-read them via a
// dng_file_stream; here we feed the bytes directly through the SDK's in-memory
// dng_stream (no filesystem access), which is what Mayhem's read-only image needs.

#include <stddef.h>
#include <stdint.h>

#include "dng_camera_profile.h"
#include "dng_exceptions.h"
#include "dng_fingerprint.h"
#include "dng_stream.h"

#include <fuzzer/FuzzedDataProvider.h>

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  FuzzedDataProvider provider(data, size);
  std::string s1 = provider.ConsumeRandomLengthString();

  // In-memory read stream over the consumed bytes — no temp file.
  dng_stream stream(s1.data(), static_cast<uint32>(s1.size()));

  try {
    AutoPtr<dng_camera_profile> customCameraProfile(new dng_camera_profile());
    customCameraProfile->ParseExtended(stream);

    // Not stubbed, so the fingerprint can be computed.
    const dng_fingerprint &fPrint = customCameraProfile->Fingerprint();
    (void)fPrint;
  } catch (dng_exception &) {
    // Expected on malformed input.
  }

  return 0;
}
