import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let bounds = NSRect(origin: .zero, size: size).insetBy(dx: 64, dy: 64)
let shape = NSBezierPath(roundedRect: bounds, xRadius: 200, yRadius: 200)
NSGradient(starting: NSColor(calibratedRed: 0.23, green: 0.62, blue: 0.80, alpha: 1),
           ending: NSColor(calibratedRed: 0.09, green: 0.24, blue: 0.48, alpha: 1))!
    .draw(in: shape, angle: -90)
for (index, start) in [340.0, 490.0, 640.0].enumerated() {
    let ribbon = NSBezierPath()
    ribbon.move(to: NSPoint(x: 240, y: start))
    ribbon.curve(to: NSPoint(x: 780 - Double(index) * 38, y: start + 35),
                 controlPoint1: NSPoint(x: 410, y: start - 85),
                 controlPoint2: NSPoint(x: 590, y: start + 130))
    ribbon.lineWidth = 48
    ribbon.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.95 - Double(index) * 0.13).setStroke()
    ribbon.stroke()
}
image.unlockFocus()
try NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!.write(to: output)
