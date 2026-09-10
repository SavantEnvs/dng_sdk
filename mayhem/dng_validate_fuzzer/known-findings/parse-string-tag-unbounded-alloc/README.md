# ParseStringTag: string buffer sized by an unchecked TIFF tag count

- **Target:** `dng_validate_fuzzer`. The same root cause is reached by `dng_fixed_validate_fuzzer`; that
  directory's README has the full write-up.
- **Class:** excessive allocation / out-of-memory (CWE-789). Not a memory-corruption bug.
- **Found:** 2026-09-10, local 60 s fork-mode libFuzzer run during integration (`-rss_limit_mb=2560`):
  4 OOM artifacts, all with the same allocation site. The three below each reach it from a different
  parser; a fourth `dng_ifd::ParseTag` duplicate was not kept.

## Reproducers

Run with `/mayhem/dng_validate_fuzzer -rss_limit_mb=2560 -runs=1 <file>`. Each one exits 71 with
`ERROR: libFuzzer: out-of-memory (malloc(N))` at `dng_memory_data::Allocate` (source/dng_memory.cpp:85)
<- `ParseStringTag` (source/dng_parse_utils.cpp:2900), reached from `dng_validate()` via `dng_info::Parse`:

| file | bytes | malloc size | caller of ParseStringTag |
| --- | --- | --- | --- |
| `oom-42f2b40e05e747fbf60d5fac72be29d9f39d3f09` | 3 928 | 4 294 915 846 | `dng_shared::Parse_ifd0` (dng_shared.cpp:2166) |
| `oom-51323b2cb7823e8c7b21c37a656bc997a6dc08d6` | 2 818 | 3 321 888 789 | `dng_exif::Parse_ifd0` <- `dng_exif::ParseTag` (dng_exif.cpp:835) |
| `oom-f17c51399c43e0d8599414b3164f4e630f11c220` | 7 047 | 3 755 991 008 | `dng_ifd::ParseTag` <- `dng_info::ParseTag` (dng_info.cpp:170) |

The upstream CLI, `/mayhem/dng_validate <file>`, exits 111 (`dng_error_end_of_file`) on each one.

## Cause

`ParseStringTag` rejects only `tagCount == 0` and `tagCount == 0xFFFFFFFF`. It then allocates
`tagCount + 1` bytes straight from the file before `stream.Get` finds out the file is shorter than the
count.

## Impact

A few-kilobyte file can make the SDK allocate up to 4 GiB per string tag before any length check. Under
ASan/libFuzzer, or in any memory-capped / strict-overcommit process, that is an out-of-memory abort
(denial of service). In an ordinary glibc build the parse fails cleanly with `dng_error_end_of_file`.
There is no out-of-bounds access.

## One-line fix

In `ParseStringTag`, immediately before the allocation:

    if (stream.Position () > stream.Length () || tagCount > stream.Length () - stream.Position ()) ThrowEndOfFile ();

Verified: with that guard, all four integration reproducers exit 0 with no OOM, and every seed still
passes. `ParseDualStringTag` (:2993) and `ParseEncodedStringTag` (:3179, :3242) want the same guard.
