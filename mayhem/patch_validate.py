#!/usr/bin/env python3
# mayhem/patch_validate.py
#
# Build-time SHADOW copy of upstream source/dng_validate.cpp for the two dng_validate harnesses
# (dng_validate_fuzzer, dng_fixed_validate_fuzzer). Additive: the committed upstream file is never
# modified; mayhem/build.sh writes the copy under its build dir and each harness #includes it.
#
# The same three edits OSS-Fuzz's dng_sdk build (and the legacy mayhemheroes layer) apply:
#   1. `int main (` -> `int dng_validate_cli_main (` — the libFuzzer / standalone driver owns main();
#   2. `static dng_error_code dng_validate (` -> non-static — the harness entry point;
#   3. comment out the per-file `printf ("Validation complete\n");`.
# Every edit is an in-line replacement, so line numbers are unchanged; a leading #line directive maps
# them back to the upstream file, so sanitizer/Mayhem backtraces name source/dng_validate.cpp:<line>.
# Each anchor must match EXACTLY once: an upstream change that moves one fails the build loudly
# instead of silently producing a different target.
#
# Usage: patch_validate.py <in dng_validate.cpp> <out dng_validate_impl.cpp>

import sys

EDITS = [
    ("int main (int argc, char *argv [])",
     "int dng_validate_cli_main (int argc, char *argv [])"),
    ("static dng_error_code dng_validate (const char *filename)",
     "dng_error_code dng_validate (const char *filename)"),
    ('\tprintf ("Validation complete\\n");',
     '\t// printf ("Validation complete\\n");  (dropped by mayhem/patch_validate.py)'),
]


def main():
    src_path, out_path = sys.argv[1], sys.argv[2]
    with open(src_path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    for old, new in EDITS:
        n = src.count(old)
        assert n == 1, "patch_validate: anchor %r found %d times (want exactly 1)" % (old, n)
        src = src.replace(old, new, 1)

    with open(out_path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write('#line 1 "%s"\n' % src_path)
        f.write(src)
    print("patch_validate: dng_validate.cpp shadow copy OK ->", out_path)


if __name__ == "__main__":
    main()
