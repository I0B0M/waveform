import AppKit
import SwiftUI

/// The status-item glyph: the same disco mark, plateless, rendered at menu-bar
/// size. Deliberately NOT a template image — the whole point of the mark is
/// its color, and macOS only forces monochrome on template images.
@MainActor
public enum MenuBarIcon {
    public static func image(points: CGFloat = 18) -> NSImage? {
        let renderer = ImageRenderer(
            content: DiscoIconView(showsPlate: false).frame(width: points, height: points)
        )
        // Render at 2x pixels, present at 1x points, so it stays sharp on
        // Retina without looking oversized.
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else { return nil }
        let image = NSImage(size: NSSize(width: points, height: points))
        image.addRepresentation(NSBitmapImageRep(cgImage: cgImage))
        image.isTemplate = false
        return image
    }
}
