// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MeetingNoteTaker",
    platforms: [
        // ScreenCaptureKit's unified capturesAudio + captureMicrophone
        // (single synchronized stream, avoiding a separate AVAudioEngine
        // mic tap and the cross-stream clock drift that would introduce)
        // requires macOS 15+.
        .macOS(.v15)
    ],
    dependencies: [
        // Official Swift MCP SDK — used for the Phase 2 MCP server (stdio
        // transport, launched as a subprocess by Claude Desktop/Code; see
        // TODOS.md "MCP server auth model" for why stdio replaced an
        // earlier Unix-socket design).
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        // Header-only shim exposing whisper.cpp's C API (Vendor/whisper.cpp,
        // vendored as a git submodule pinned to v1.9.2) to Swift. No sources
        // of its own — the actual whisper.cpp code is built separately via
        // its own CMake build (see Vendor/whisper.cpp/build) and linked in
        // as static libraries below, not recompiled by SPM.
        .target(
            name: "CWhisper",
            path: "Sources/CWhisper"
            // No header search path settings: whisper.h and every ggml/*.h
            // it transitively #includes are symlinked directly into
            // Sources/CWhisper/include/ (pointing back at the vendored
            // submodule), rather than relying on cSettings.headerSearchPath
            // — that was observed to not apply to the module map's own
            // header resolution in this SPM version.
        ),
        .executableTarget(
            name: "MeetingNoteTaker",
            dependencies: [
                "CWhisper",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/MeetingNoteTaker",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                // Verified against a real `cmake --build` output (2026-08-09,
                // whisper.cpp v1.9.2, GGML_METAL=ON, GGML_BLAS_DEFAULT=ON).
                // ggml-blas and ggml-metal land in their own subdirectories,
                // not directly under ggml/src/ like the others.
                .unsafeFlags([
                    "-L", "Vendor/whisper.cpp/build/src",
                    "-L", "Vendor/whisper.cpp/build/ggml/src",
                    "-L", "Vendor/whisper.cpp/build/ggml/src/ggml-metal",
                    "-L", "Vendor/whisper.cpp/build/ggml/src/ggml-blas",
                    "-lwhisper",
                    "-lggml",
                    "-lggml-base",
                    "-lggml-cpu",
                    "-lggml-metal",
                    "-lggml-blas",
                    // whisper.cpp/ggml are C++ under the hood (exceptions,
                    // RTTI); the Swift linker driver doesn't pull in libc++
                    // automatically just because a static lib needs it.
                    "-lc++"
                ])
            ]
        ),
        .testTarget(
            name: "MeetingNoteTakerTests",
            dependencies: [
                "MeetingNoteTaker",
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Tests/MeetingNoteTakerTests"
        )
    ]
)
