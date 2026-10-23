import AppKit
import Foundation

// Original vector geometry. Regenerates all raster and native icon assets locally on macOS.
let fm = FileManager.default
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Assets/Brand")
try fm.createDirectory(at: output, withIntermediateDirectories: true)
let green = NSColor(srgbRed: 46/255, green: 97/255, blue: 67/255, alpha: 1)

func mark(_ color: NSColor) {
    color.setStroke()
    for x in [12.0, 70.0] {
        let frame = NSBezierPath(roundedRect: NSRect(x: x, y: 24, width: 46, height: 80), xRadius: 12, yRadius: 12)
        frame.lineWidth = 7; frame.stroke()
        let header = NSBezierPath(); header.move(to: NSPoint(x: x, y: 81)); header.line(to: NSPoint(x: x+46, y: 81)); header.lineWidth = 7; header.stroke()
    }
    let cutout = NSBezierPath(rect: NSRect(x: 38, y: 53.5, width: 52, height: 21))
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.compositingOperation = .clear; cutout.fill(); NSGraphicsContext.restoreGraphicsState()
    color.setStroke(); let bridge = NSBezierPath(); bridge.move(to: NSPoint(x: 42, y: 64)); bridge.line(to: NSPoint(x: 86, y: 64)); bridge.lineWidth = 7; bridge.lineCapStyle = .round; bridge.stroke()
}

func png(size: Int, icon: Bool) throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = NSAffineTransform(); transform.scale(by: CGFloat(size)/128); transform.concat()
    if icon {
        green.setFill(); NSBezierPath(roundedRect: NSRect(x: 4, y: 4, width: 120, height: 120), xRadius: 27, yRadius: 27).fill()
        let inset = NSAffineTransform(); inset.translateX(by: 19.2, yBy: 19.2); inset.scale(by: 0.7); inset.concat()
        // Draw symbol in a separate transparent layer so its cutout does not punch through the icon ground.
        let symbol = NSImage(data: try png(size: 1024, icon: false))!
        symbol.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
    } else { mark(.white) }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func logoPNG() throws -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 512, pixelsHigh: 512, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let transform = NSAffineTransform(); transform.scale(by: 4); transform.concat(); mark(green)
    NSGraphicsContext.restoreGraphicsState(); return rep.representation(using: .png, properties: [:])!
}
try logoPNG().write(to: output.appendingPathComponent("logo.png"))
try png(size: 1024, icon: true).write(to: output.appendingPathComponent("app-icon.png"))
try png(size: 512, icon: false).write(to: output.appendingPathComponent("logo-white.png"))
let iconset = output.appendingPathComponent("BrowserBridge.iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try png(size: size, icon: true).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try png(size: size*2, icon: true).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil"); process.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("BrowserBridge.icns").path]
try process.run(); process.waitUntilExit()
guard process.terminationStatus == 0 else { throw NSError(domain: "Brand", code: 1) }
try fm.removeItem(at: iconset)
print("Generated Browser Bridge assets in \(output.path)")
