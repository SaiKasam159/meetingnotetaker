// Empty translation unit. CWhisper is a headers-only shim (see
// include/shim.h) exposing the vendored whisper.cpp C API to Swift — no code
// of its own is compiled here. This file exists only so SPM treats CWhisper
// as a target with real sources, which is what makes it actually apply the
// cSettings header search paths (Vendor/whisper.cpp/include,
// Vendor/whisper.cpp/ggml/include) when resolving shim.h's #include
// "whisper.h" — an empty-sources target was observed to skip that.
#include "shim.h"
