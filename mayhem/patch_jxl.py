#!/usr/bin/env python3
# mayhem/patch_jxl.py
#
# Build-time SHADOW patch (additive: the committed upstream source/dng_jxl.cpp is
# never modified). dng_jxl.cpp is required for the parser (ParseJXL / dng_jxl_decoder
# are referenced by dng_read_image, dng_big_table, dng_negative, dng_image_writer),
# but it uses the XMP type in two isolated spots that do not compile when the SDK is
# built with qDNGUseXMP=0 (we disable XMP so we don't need the external Adobe XMP
# toolkit / expat). Both spots are cleanly guardable with #if qDNGUseXMP:
#   * the XMP-writing block in the JXL ENCODE path, and
#   * the dng_xmp Parse in dng_jxl_decoder::ProcessXMPBox (decode path).
# Neither is on the fuzzed decode/geometry path. We assert every anchor is found so
# an upstream change that moves these regions fails the build loudly instead of
# silently dropping the guard.
#
# Usage: patch_jxl.py <in dng_jxl.cpp> <out patched.cpp>

import sys

def main():
    src_path, out_path = sys.argv[1], sys.argv[2]
    with open(src_path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    # Region 1: guard the XMP-writing block (encode path).
    a1 = ("\t\t// XMP.\n\n"
          "\t\tif (includeXMP && metadata && metadata->GetXMP ())")
    assert a1 in src, "patch_jxl: region1 start anchor not found"
    src = src.replace(
        a1,
        "\t\t// XMP.\n\n#if qDNGUseXMP\n"
        "\t\tif (includeXMP && metadata && metadata->GetXMP ())",
        1)
    a1end = "\t\t\t} // xmp\n"
    assert a1end in src, "patch_jxl: region1 end anchor not found"
    src = src.replace(a1end, "\t\t\t} // xmp\n#endif // qDNGUseXMP\n", 1)

    # Region 2: guard the dng_xmp usage in dng_jxl_decoder::ProcessXMPBox
    # (decode path), keeping the 'count' local which is used afterwards.
    r2 = ("\t\t\tdng_xmp xmp (host.Allocator ());\n\n"
          "\t\t\tuint32 count = (uint32) data.size ();\n\n"
          "\t\t\txmp.Parse (host, data.data (), count);\n")
    assert r2 in src, "patch_jxl: region2 anchor not found"
    r2new = ("\t\t\tuint32 count = (uint32) data.size ();\n\n"
             "#if qDNGUseXMP\n"
             "\t\t\tdng_xmp xmp (host.Allocator ());\n\n"
             "\t\t\txmp.Parse (host, data.data (), count);\n"
             "#endif // qDNGUseXMP\n")
    src = src.replace(r2, r2new, 1)

    with open(out_path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(src)
    print("patch_jxl: dng_jxl.cpp shadow-patched OK ->", out_path)

if __name__ == "__main__":
    main()
