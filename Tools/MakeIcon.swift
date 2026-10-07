import AppKit

let output = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for (size, suffix) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let scale = CGFloat(size) / 1024
    let background = NSBezierPath(roundedRect: NSRect(x: 70 * scale, y: 70 * scale, width: 884 * scale, height: 884 * scale), xRadius: 196 * scale, yRadius: 196 * scale)
    NSColor(calibratedRed: 0.04, green: 0.36, blue: 0.79, alpha: 1).setFill()
    background.fill()
    if let symbol = NSImage(systemSymbolName: "arrow.down.document", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: 480 * scale, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let artwork = symbol.withSymbolConfiguration(config)!
        artwork.draw(in: NSRect(x: 250 * scale, y: 230 * scale, width: 524 * scale, height: 564 * scale))
    }
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let png = bitmap.representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("icon_\(suffix).png"))
}
