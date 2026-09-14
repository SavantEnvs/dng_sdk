// mayhem/harnesses/dng_stage_fuzzer.cpp
//
// In-process, byte-in port of the OSS-Fuzz dng_stage_fuzzer. Drives the full DNG
// pipeline (parse -> negative parse -> ReadStage1Image -> BuildStage2/3 -> render
// -> WriteDNG/WriteTIFF) under a variety of dng_host settings — the same high-level
// operations dng_validate performs, which is why this harness also covers the code
// paths the OSS-Fuzz dng_validate_fuzzer / dng_fixed_validate_fuzzer exercise.
//
// Changes vs the OSS-Fuzz original, all to satisfy Mayhem's read-only image /
// byte-in contract (no filesystem access):
//   * input arrives as bytes wrapped in an in-memory dng_stream (was: written to
//     /tmp and re-read via dng_file_stream);
//   * DNG/TIFF output is written to in-memory dng_memory_stream (was: /tmp files);
//   * info.fIFDCount -> info.IFDCount() (member renamed in DNG 1.7.1).

#include <stddef.h>
#include <stdint.h>

#include "dng_camera_profile.h"
#include "dng_color_space.h"
#include "dng_date_time.h"
#include "dng_exceptions.h"
#include "dng_host.h"
#include "dng_ifd.h"
#include "dng_image.h"
#include "dng_image_writer.h"
#include "dng_info.h"
#include "dng_memory_stream.h"
#include "dng_negative.h"
#include "dng_preview.h"
#include "dng_render.h"
#include "dng_stream.h"
#include "dng_tag_codes.h"
#include "dng_tag_values.h"

static void runFuzzerWithVariableHost(const uint8_t *data, size_t size,
                                      uint32 dng_version, bool linear,
                                      bool preview, bool should_proxy,
                                      bool KeepOriginalFile, bool NeedsMeta,
                                      bool NeedsImage, int do_color_coding,
                                      bool setFuji) {
  dng_host host;
  host.SetPreferredSize(0);
  host.SetMinimumSize(0);
  host.SetMaximumSize(0);
  host.SetSaveDNGVersion(dng_version);
  host.SetSaveLinearDNG(linear);
  host.SetForPreview(preview);
  host.ValidateSizes();
  host.SetKeepOriginalFile(KeepOriginalFile);
  host.SetNeedsMeta(NeedsMeta);
  host.SetNeedsImage(NeedsImage);

  AutoPtr<dng_camera_profile> customCameraProfile(new dng_camera_profile());
  customCameraProfile->SetName("custom profile");

  AutoPtr<dng_negative> negative;
  try {
    dng_info info;
    dng_stream stream(data, static_cast<uint32>(size));
    info.Parse(host, stream);
    info.PostParse(host);

    if (setFuji && info.IFDCount() > 0) {
      info.fIFD[0]->CanRead();
    }

    if (info.IsValidDNG()) {
      negative.Reset(host.Make_dng_negative());
      negative->AddProfile(customCameraProfile);

      if (do_color_coding == 1) {
        negative->SetDefaultCropSize((uint32)100, (uint32)100);
        negative->SetDefaultCropOrigin((uint32)50, (uint32)100);
      } else if (do_color_coding == 2) {
        negative->ResetDefaultUserCrop();
      } else {
        negative->SetDefaultUserCropT(dng_urational(0, 1));
      }

      negative->SetStage3Gain(2);
      negative->SetIsPreview(true);

      negative->Parse(host, stream, info);
      negative->PostParse(host, stream, info);
      negative->ReadStage1Image(host, stream, info);
      if (info.fMaskIndex != -1) {
        negative->ReadTransparencyMask(host, stream, info);
      }

      if (do_color_coding == 2) {
        const char fingerprint_raw[32] = {
            'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a',
            'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a', 'a',
            'a', 'a', 'a', 'a', 'a', 'a'};

        dng_fingerprint fp;
        fp.FromUtf8HexString(fingerprint_raw);
        dng_camera_profile_id dcpi("random id", fp);
        dng_camera_profile foundProfile;
        negative->GetProfileByID(dcpi, foundProfile, true);  // 1.7.1: ProfileByID -> GetProfileByID
      }
      negative->SynchronizeMetadata();
      negative->SetFourColorBayer();
      if (do_color_coding == 1) {
        negative->SetRGB();
      } else if (do_color_coding == 2) {
        negative->SetCMY();
      } else if (do_color_coding == 3) {
        negative->SetGMCY();
      }
      negative->BuildStage2Image(host);
      negative->BuildStage3Image(host, 1);

      if (should_proxy) {
        dng_image_writer writer;
        negative->ConvertToProxy(host, writer, 1);
      }

      if (negative->NeedFlattenTransparency(host)) {
        negative->FlattenTransparency(host);
      }

      // Write DNG to an in-memory stream (was /tmp/randdng1).
      dng_memory_stream stream3(host.Allocator());
      dng_image_writer writer3;
      dng_preview_list previewList;
      writer3.WriteDNG(host, stream3, *negative.Get(), &previewList, dng_version,
                       false);

      // Write TIFF (each compression) to an in-memory stream (was /tmp/randpng).
      uint32 compression_arr[8] = {ccUncompressed, ccLZW,      ccOldJPEG,
                                   ccJPEG,         ccDeflate,  ccPackBits,
                                   ccOldDeflate,   ccLossyJPEG};
      for (int c = 0; c < 8; c++) {
        dng_memory_stream stream2(host.Allocator());
        const dng_image &stage3 = *negative->Stage3Image();
        dng_image_writer writer2;
        writer2.WriteTIFF(host, stream2, stage3,
                          stage3.Planes() >= 3 ? piRGB : piBlackIsZero,
                          compression_arr[c]);
      }

      // Render.
      dng_render render(host, *negative);
      AutoPtr<dng_image> finalImage;
      finalImage.Reset(render.Render());

      if (do_color_coding == 3) {
        negative->ClearProfiles();  // 1.7.1: now takes no arguments
      }
    }
  } catch (dng_exception &) {
    // Expected on malformed input.
  }
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
  runFuzzerWithVariableHost(data, size, dngVersion_None, true, false, false, true,
                            true, true, 1, true);
  runFuzzerWithVariableHost(data, size, dngVersion_1_0_0_0, true, true, false,
                            true, true, true, 2, false);
  runFuzzerWithVariableHost(data, size, dngVersion_1_1_0_0, true, true, false,
                            true, true, true, 3, true);
  runFuzzerWithVariableHost(data, size, dngVersion_1_2_0_0, true, true, false,
                            true, true, true, 4, false);
  runFuzzerWithVariableHost(data, size, dngVersion_1_3_0_0, true, true, false,
                            true, true, true, 1, true);
  runFuzzerWithVariableHost(data, size, dngVersion_1_4_0_0, true, true, false,
                            true, true, true, 2, false);
  runFuzzerWithVariableHost(data, size, dngVersion_1_4_0_0, false, false, true,
                            true, true, true, 3, false);
  runFuzzerWithVariableHost(data, size, dngVersion_1_4_0_0, false, false, true,
                            true, true, true, 3, true);
  return 0;
}
