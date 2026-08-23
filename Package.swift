// swift-tools-version:6.0
import PackageDescription

// The Testing.framework that ships with Command Line Tools; SwiftPM doesn't
// add these search paths on its own (Xcode would).
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltTestingLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "Waveform",
    platforms: [
        .macOS("26.0")
    ],
    targets: [
        .target(
            name: "WaveformCore",
            path: "Sources/WaveformCore",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .executableTarget(
            name: "Waveform",
            dependencies: ["WaveformCore"],
            path: "Sources/Waveform",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        // The CLT `swift test` runner silently executes zero swift-testing
        // tests (verified: a deliberately broken assertion still exits 0), so
        // the suite is a plain executable calling the Testing entry point:
        //   swift run waveform-tests
        .executableTarget(
            name: "waveform-tests",
            dependencies: ["WaveformCore"],
            path: "Tests/WaveformTests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-F", cltFrameworks]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", cltFrameworks,
                    "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                    "-Xlinker", "-rpath", "-Xlinker", cltTestingLibs,
                ])
            ]
        ),
    ]
)
