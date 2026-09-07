import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for (points, scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let pixels = points * scale
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let factor = Double(pixels) / 1024
    let card = NSBezierPath(roundedRect: NSRect(x: 72 * factor, y: 72 * factor, width: 880 * factor, height: 880 * factor), xRadius: 200 * factor, yRadius: 200 * factor)
    NSColor(red: 0.035, green: 0.11, blue: 0.16, alpha: 1).setFill(); card.fill()
    NSColor(red: 0.18, green: 0.88, blue: 0.79, alpha: 1).setFill()
    let heights = [190.0, 330.0, 470.0, 300.0, 160.0]
    for (index, height) in heights.enumerated() {
        NSBezierPath(roundedRect: NSRect(x: (262 + Double(index) * 100) * factor,
            y: (512 - height / 2) * factor, width: 52 * factor, height: height * factor),
            xRadius: 26 * factor, yRadius: 26 * factor).fill()
    }
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 694 * factor, y: 255 * factor, width: 95 * factor, height: 95 * factor)).fill()
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let data = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
    let suffix = scale == 2 ? "@2x" : ""
    try data.write(to: output.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
}
