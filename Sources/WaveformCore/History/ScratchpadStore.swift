import Foundation

/// A single local scratchpad for drafting by voice; plain text file in
/// Application Support, autosaved.
@MainActor
final class ScratchpadStore: ObservableObject {
    static let shared = ScratchpadStore()

    @Published var text: String = "" {
        didSet { save() }
    }

    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Waveform", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("scratchpad.txt")
        text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    private func save() {
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
