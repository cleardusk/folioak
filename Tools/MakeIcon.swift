import AppKit

// Scale the user-approved master, retaining alpha and exact iconset dimensions.
guard CommandLine.arguments.count == 3, let source = NSImage(contentsOfFile: CommandLine.arguments[1]) else {
    fatalError("Usage: MakeIcon.swift master.png output.iconset")
}
let output = CommandLine.arguments[2]
try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
for (size, suffix) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"), (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                                  hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    source.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let png = bitmap.representation(using: .png, properties: [:])!
    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent("icon_\(suffix).png"))
}
