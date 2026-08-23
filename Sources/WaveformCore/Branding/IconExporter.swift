import AppKit
import SwiftUI

/// Exports the app mark to an .iconset directory at every size macOS wants.
///
/// Uses `ImageRenderer` with an explicit scale of 1 so each file is exactly
/// the pixel size it claims — view snapshotting would silently inherit the
/// display's 2x backing and produce mislabeled icons.
public enum IconExporter {
    /// (filename, pixel size) pairs iconutil expects in an .iconset.
    private static let variants: [(name: String, pixels: Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]

    @MainActor
    public static func exportIconsetAndExit(to directory: String) {
        _ = NSApplication.shared
        let url = URL(fileURLWithPath: directory)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for variant in variants {
                let data = try png(pixels: variant.pixels)
                try data.write(to: url.appendingPathComponent(variant.name + ".png"))
            }
            print("Wrote \(variants.count) icons to \(directory)")
            exit(0)
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    /// Single PNG at an arbitrary size — used for design review.
    @MainActor
    public static func exportPreviewAndExit(to path: String, pixels: Int) {
        _ = NSApplication.shared
        do {
            try png(pixels: pixels).write(to: URL(fileURLWithPath: path))
            print("Wrote \(path) (\(pixels)px)")
            exit(0)
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    /// Plateless glyph preview — the menu-bar variant.
    @MainActor
    public static func exportGlyphAndExit(to path: String, pixels: Int) {
        _ = NSApplication.shared
        do {
            try png(pixels: pixels, plate: false).write(to: URL(fileURLWithPath: path))
            print("Wrote \(path) (\(pixels)px glyph)")
            exit(0)
        } catch {
            print("FAIL: \(error)")
            exit(1)
        }
    }

    @MainActor
    private static func png(pixels: Int, plate: Bool = true) throws -> Data {
        let side = CGFloat(pixels)
        let renderer = ImageRenderer(
            content: DiscoIconView(showsPlate: plate).frame(width: side, height: side)
        )
        renderer.scale = 1
        guard let cgImage = renderer.cgImage else {
            throw NSError(domain: "IconExporter", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "renderer produced no image at \(pixels)px",
            ])
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        rep.size = NSSize(width: side, height: side)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IconExporter", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "PNG encoding failed at \(pixels)px",
            ])
        }
        return data
    }
}
