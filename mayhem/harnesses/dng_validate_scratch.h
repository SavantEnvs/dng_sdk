// mayhem/harnesses/dng_validate_scratch.h
//
// Scratch-file helpers shared by the two dng_validate harnesses. dng_validate() — the per-file driver
// of upstream's `dng_validate` command-line tool — takes a PATH (it opens the input with
// dng_file_stream) and writes its -dng/-1/-2/-3/-tif dump outputs to paths, so these harnesses need
// real files. Each one is created with mkstemp() under $TMPDIR (fallback /tmp; Mayhem mounts the image
// read-only, the scratch dir is writable) and unlinked when its ScratchFile goes out of scope, i.e.
// after every iteration. No fixed or absolute paths.
//
// Include AFTER dng_validate_impl.cpp: SetDump()/ClearDumps() use that TU's static dump globals.

#ifndef MAYHEM_DNG_VALIDATE_SCRATCH_H
#define MAYHEM_DNG_VALIDATE_SCRATCH_H

#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>

#include <unistd.h>

class ScratchFile {
 public:
  explicit ScratchFile(const char *tag) {
    const char *dir = getenv("TMPDIR");
    if (dir == nullptr || dir[0] == '\0') dir = "/tmp";
    int n = snprintf(path_, sizeof(path_), "%s/%s.XXXXXX", dir, tag);
    if (n > 0 && static_cast<size_t>(n) < sizeof(path_)) fd_ = mkstemp(path_);
    if (fd_ < 0) path_[0] = '\0';
  }

  ~ScratchFile() {
    CloseFd();
    if (path_[0] != '\0') unlink(path_);
  }

  ScratchFile(const ScratchFile &) = delete;
  ScratchFile &operator=(const ScratchFile &) = delete;

  bool ok() const { return path_[0] != '\0'; }
  const char *path() const { return path_; }

  void CloseFd() {
    if (fd_ >= 0) {
      close(fd_);
      fd_ = -1;
    }
  }

  // Writes every byte through the mkstemp() descriptor, then closes it.
  bool WriteAndClose(const uint8_t *data, size_t size) {
    bool good = fd_ >= 0;
    while (good && size > 0) {
      ssize_t w = write(fd_, data, size);
      if (w < 0) {
        if (errno == EINTR) continue;
        good = false;
      } else {
        data += w;
        size -= static_cast<size_t>(w);
      }
    }
    CloseFd();
    return good;
  }

 private:
  char path_[4096] = {0};
  int fd_ = -1;
};

// Clears one dump global and, when `enable` is set, points it at a fresh scratch file owned by
// `slot`. Returns false only if that scratch file could not be created.
static inline bool SetDump(dng_string &dump, bool enable, std::unique_ptr<ScratchFile> &slot,
                           const char *tag) {
  dump.Clear();
  if (!enable) return true;
  slot.reset(new ScratchFile(tag));
  if (!slot->ok()) return false;
  slot->CloseFd();  // dng_validate() re-opens the path for writing (truncating)
  dump.Set(slot->path());
  return true;
}

// Never leave a dump global naming a scratch file that is about to be unlinked (dng_validate()
// clears the ones it wrote, but not on its exception paths).
static inline void ClearDumps() {
  gDumpDNG.Clear();
  gDumpStage1.Clear();
  gDumpStage2.Clear();
  gDumpStage3.Clear();
  gDumpTIF.Clear();
}

#endif  // MAYHEM_DNG_VALIDATE_SCRATCH_H
