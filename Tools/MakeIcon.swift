import AppKit

// Scale the release master, retaining alpha and exact iconset dimensions.
guard (3...4).contains(CommandLine.arguments.count), let source = NSImage(contentsOfFile: CommandLine.arguments[1]),
      CommandLine.arguments.count == 3 || CommandLine.arguments[3] == "--round-tile" else {
    fatalError("Usage: MakeIcon.swift master.png output.iconset [--round-tile]")
}
let output = CommandLine.arguments[2]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for (size, suffix) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    // Optional production mask for generated macOS tiles; the artwork is unchanged.
    if CommandLine.arguments.count == 4 {
        let edge = CGFloat(size)
        NSBezierPath(roundedRect: NSRect(x: edge * 0.09, y: edge * 0.09, width: edge * 0.82, height: edge * 0.82),
                     xRadius: edge * 0.16, yRadius: edge * 0.16).addClip()
    }
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("icon_\(suffix).png"))
}
