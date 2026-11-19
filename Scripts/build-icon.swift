// Render the Dock/Finder tile using the same vector as the template and web icons.
import AppKit

let source = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
let iconset = directory.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
guard let gauge = NSImage(contentsOf: source) else { fatalError("无法读取表盘图形") }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels)/128, y: CGFloat(pixels)/128)
        let tile = NSBezierPath(roundedRect: NSRect(x: 10, y: 10, width: 108, height: 108), xRadius: 24, yRadius: 24)
        let top = NSColor(srgbRed: 0.95, green: 0.94, blue: 0.89, alpha: 1)
        let base = NSColor(srgbRed: 0.77, green: 0.75, blue: 0.69, alpha: 1)
        NSGradient(starting: base, ending: top)!.draw(in: tile, angle: 90)
        base.setStroke()
        tile.lineWidth = 0.8
        tile.stroke()
        gauge.draw(in: NSRect(x: 22, y: 24, width: 84, height: 84))
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        let file = iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png")
        try rep.representation(using: .png, properties: [:])!.write(to: file)
    }
}
let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try tool.run()
tool.waitUntilExit()
exit(tool.terminationStatus)
