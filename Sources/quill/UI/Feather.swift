import AppKit

/// The Lucide feather, inlined as SVG so the executable ships no resource
/// bundle. Two renderings: a template glyph for the status item, and a
/// white-on-slate rounded tile used to generate Quill.app's icon at install
/// time (which is what notifications and System Settings display).
enum Feather {
    static let menuSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    /// macOS app icons carry their margins in the artwork: a 28/32 rounded
    /// tile with the feather at ~2/3 scale, centered.
    static let iconSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">\
    <rect x="2" y="2" width="28" height="28" rx="6.4" fill="#232936"/>\
    <g transform="translate(7 7) scale(0.75)" fill="none" stroke="#e9edf5" \
    stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </g>\
    </svg>
    """

    static func menuImage() -> NSImage? {
        guard let data = menuSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    /// Rasterize the icon SVG at one pixel size (for building an .iconset).
    static func iconPNG(pixels: Int) -> Data? {
        guard let data = iconSVG.data(using: .utf8),
              let image = NSImage(data: data),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              )
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
