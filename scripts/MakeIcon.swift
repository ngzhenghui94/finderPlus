import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FinderPlus-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 512
        let transform = NSAffineTransform(); transform.scale(by: factor); transform.concat()
        NSColor(calibratedRed: 0.15, green: 0.45, blue: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 472, height: 472), xRadius: 108, yRadius: 108).fill()
        NSColor(calibratedRed: 0.81, green: 0.92, blue: 1, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 78, y: 144, width: 356, height: 220), xRadius: 24, yRadius: 24).fill()
        NSBezierPath(roundedRect: NSRect(x: 78, y: 310, width: 157, height: 74), xRadius: 20, yRadius: 20).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 78, y: 128, width: 356, height: 202), xRadius: 24, yRadius: 24).fill()
        NSColor(calibratedRed: 0.14, green: 0.44, blue: 0.81, alpha: 1).setStroke()
        let plus = NSBezierPath(); plus.lineWidth = 21; plus.lineCapStyle = .round
        plus.move(to: NSPoint(x: 256, y: 183)); plus.line(to: NSPoint(x: 256, y: 277)); plus.move(to: NSPoint(x: 209, y: 230)); plus.line(to: NSPoint(x: 303, y: 230)); plus.stroke()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot render icon") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); process.arguments = ["-c", "icns", folder.path, "-o", output.path]; try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { fatalError("iconutil failed") }
