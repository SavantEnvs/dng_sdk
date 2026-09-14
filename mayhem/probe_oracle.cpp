// mayhem/probe_oracle.cpp
//
// Behavioral oracle probe (built with the project's NORMAL flags — no sanitizer,
// no -gdwarf-3 — and DYNAMICALLY linked, so the verify-repo sabotage shim that
// _exit(0)s a neutered binary is able to affect it).
//
// It parses a fixed, valid DNG file through the same DNG file parser the fuzzer
// exercises (dng_info::Parse / PostParse) and prints the main-IFD geometry it
// decoded. test.sh greps the exact expected values, so a program neutered to a
// no-op prints nothing and the oracle FAILS.

#include <cstdio>

#include "dng_exceptions.h"
#include "dng_file_stream.h"
#include "dng_host.h"
#include "dng_ifd.h"
#include "dng_info.h"

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: %s <file.dng>\n", argv[0]);
    return 2;
  }

  try {
    dng_host host;
    dng_file_stream stream(argv[1]);

    dng_info info;
    info.Parse(host, stream);
    info.PostParse(host);

    if (info.fMainIndex < 0 ||
        info.fMainIndex >= static_cast<int>(info.fIFDCount)) {
      fprintf(stderr, "no main IFD\n");
      return 3;
    }

    dng_ifd *ifd = info.fIFD[info.fMainIndex].Get();
    printf("MAIN_WIDTH=%u\n", ifd->fImageWidth);
    printf("MAIN_HEIGHT=%u\n", ifd->fImageLength);
    printf("IFD_COUNT=%u\n", static_cast<unsigned>(info.fIFDCount));
  } catch (dng_exception &e) {
    fprintf(stderr, "dng_exception %d\n", e.ErrorCode());
    return 4;
  }

  return 0;
}
