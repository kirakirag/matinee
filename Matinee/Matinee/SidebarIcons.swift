import AppKit
import MatineeKit

/// Each section's symbol drawn once, at 2x, in the accent colour. With live symbol images the sidebar
/// blanks them for a frame or two whenever the window turns active or inactive.
@MainActor let sidebarIcons: [AppSection: NSImage] = Dictionary(uniqueKeysWithValues: AppSection.allCases.map { s in
    let symbol = NSImage(systemSymbolName: s.symbol, accessibilityDescription: s.title)!
        .withSymbolConfiguration(.init(pointSize: 13, weight: .regular).applying(.init(paletteColors: [.controlAccentColor])))!
    let size = symbol.size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    symbol.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: size)
    image.addRepresentation(rep)
    return (s, image)
})
