import Testing

// Entry point for the test suite (see Package.swift for why this is an
// executable instead of a test target). Exits non-zero on any failure.
await Testing.__swiftPMEntryPoint() as Never
