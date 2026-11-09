// Renders assets/icon.svg to the PNG sizes the manifest lists. Run from BrowserExtension/:
//   swift scripts/render-icons.swift
import AppKit

let directory = URL(fileURLWithPath: "static/icons")
guard let image = NSImage(contentsOf: URL(fileURLWithPath: "assets/icon.svg")) else {
    fatalError("cannot read assets/icon.svg")
}
for size in [16, 32, 48, 128] {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(size).png"))
}
print("rendered")
