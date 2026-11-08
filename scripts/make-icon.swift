import AppKit
import Foundation

// Keep the approved artwork as the source for every standard macOS icon size.
let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent().appendingPathComponent("apps/macos/Resources/AppIcon.png")
guard let image = NSImage(contentsOf: source) else {
  fatalError("Cannot load app icon: \(source.path)")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
  let size = points * scale
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  NSGraphicsContext.current?.imageInterpolation = .high
  let inset = CGFloat(size) / 32
  image.draw(in: NSRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset,
    height: CGFloat(size) - 2 * inset), from: .zero, operation: .copy, fraction: 1)
  NSGraphicsContext.restoreGraphicsState()
  let suffix = scale == 2 ? "@2x" : ""
  try rep.representation(using: .png, properties: [:])!.write(
    to: directory.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}
