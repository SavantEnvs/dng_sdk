# ParseStringTag: string buffer sized by an unchecked TIFF tag count

- **Target:** `dng_fixed_validate_fuzzer`. The same root cause is reached by `dng_validate_fuzzer`; see
  `mayhem/dng_validate_fuzzer/known-findings/parse-string-tag-unbounded-alloc/`.
- **Class:** excessive allocation / out-of-memory (CWE-789). Not a memory-corruption bug.
- **Found:** 2026-09-10, local 60 s fork-mode libFuzzer run during integration (`-rss_limit_mb=2560`).

## Reproducer

`oom-17db403a805ff2613675eb82f069f6527be31115` (142 229 bytes): a DNG whose IFD0 camera-profile string tag
declares a count of about 2.6 GiB.

    /mayhem/dng_fixed_validate_fuzzer -rss_limit_mb=2560 -runs=1 oom-17db403a805ff2613675eb82f069f6527be31115

    ==N== ERROR: libFuzzer: out-of-memory (malloc(2726404129))
        #8  dng_memory_data::Allocate(unsigned int)        source/dng_memory.cpp:85
        #10 ParseStringTag(...)                            source/dng_parse_utils.cpp:2900
        #11 dng_camera_profile_info::ParseTag(...)         source/dng_shared.cpp
        #12 dng_shared::Parse_ifd0(...)                    source/dng_shared.cpp:3727
        #16 dng_info::Parse(dng_host&, dng_stream&)        source/dng_info.cpp:2333
        #17 dng_validate(char const*)                      source/dng_validate.cpp:143
    exit 71

The upstream CLI runs the same code: `/mayhem/dng_validate <reproducer>` exits 111
(`dng_error_end_of_file`). glibc returns the 2.6 GiB without touching it, then the read throws.

## Cause

`ParseStringTag` (source/dng_parse_utils.cpp:2882) rejects only `tagCount == 0` and
`tagCount == 0xFFFFFFFF`. It then allocates `dng_memory_data temp_buffer (tagCount + 1)`, up to 4 GiB
taken straight from the file, *before* `stream.Get (buffer, tagCount)` finds out the file is far shorter
than the count.

## Impact

A file of a few kilobytes can make the SDK allocate up to 4 GiB per string tag before any length check.
Under ASan/libFuzzer, and in any process with a memory cap or strict overcommit, that is an
out-of-memory abort, i.e. denial of service. In an ordinary glibc build the pages are never touched, and
the parse fails cleanly with `dng_error_end_of_file`. There is no out-of-bounds read or write.

## One-line fix

In `ParseStringTag`, immediately before the allocation:

    if (stream.Position () > stream.Length () || tagCount > stream.Length () - stream.Position ()) ThrowEndOfFile ();

Verified with a build-time shadow copy of dng_parse_utils.cpp linked into both validate fuzzers. All five
reproducers found during integration (this one, the three kept under `dng_validate_fuzzer`, and a fourth
`dng_ifd::ParseTag` duplicate that was not kept) then exit 0 with no OOM, and every seed still passes.
Two sibling helpers size their buffers from the tag count the same way and want the same guard:
`ParseDualStringTag` (`tagCount + 1`, dng_parse_utils.cpp:2993) and `ParseEncodedStringTag`
(`tagCount - 8`, :3179 and :3242).
