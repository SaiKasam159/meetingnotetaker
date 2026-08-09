#ifndef CWHISPER_SHIM_H
#define CWHISPER_SHIM_H

// Exposes whisper.cpp's C API to Swift. The real header lives in the vendored
// submodule (Vendor/whisper.cpp/include/whisper.h) rather than being copied
// here, so it stays in sync with whatever commit the submodule is pinned to.
// The header search path is added via cSettings in Package.swift.
#include "whisper.h"

#endif
