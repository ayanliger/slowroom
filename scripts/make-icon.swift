import AppKit

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB,
                             bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(srgbRed: 0.074, green: 0.086, blue: 0.082, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: size, height: size)).fill()
let panel = NSBezierPath(roundedRect: NSRect(x: 130, y: 170, width: 764, height: 684), xRadius: 38, yRadius: 38)
NSColor(srgbRed: 0.12, green: 0.14, blue: 0.13, alpha: 1).setFill()
panel.fill()
NSColor(srgbRed: 0.28, green: 0.31, blue: 0.29, alpha: 1).setStroke()
panel.lineWidth = 5
panel.stroke()
NSColor(srgbRed: 0.91, green: 0.65, blue: 0.37, alpha: 1).setFill()
let heights: [CGFloat] = [76, 120, 170, 250, 320, 400, 340, 260, 200, 140, 100, 64]
for (index, height) in heights.enumerated() {
    NSBezierPath(roundedRect: NSRect(x: 230 + index * 48, y: Int(530 - height / 2), width: 18, height: Int(height)), xRadius: 9, yRadius: 9).fill()
}
let label = "0.80" as NSString
label.draw(at: NSPoint(x: 230, y: 225), withAttributes: [
    .font: NSFont.monospacedDigitSystemFont(ofSize: 88, weight: .medium),
    .foregroundColor: NSColor(srgbRed: 0.94, green: 0.93, blue: 0.88, alpha: 1)
])
NSBezierPath(ovalIn: NSRect(x: 725, y: 250, width: 44, height: 44)).fill()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
