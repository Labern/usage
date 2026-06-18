import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let fullRect = NSRect(x: 0, y: 0, width: size, height: size)

// Background: rounded-square, dark gradient matching the app's theme.
let bgPath = NSBezierPath(roundedRect: fullRect, xRadius: 200, yRadius: 200)
let bgGradient = NSGradient(
    starting: NSColor(calibratedRed: 0.075, green: 0.06, blue: 0.2, alpha: 1),
    ending: NSColor(calibratedRed: 0.22, green: 0.2, blue: 0.46, alpha: 1)
)
bgGradient?.draw(in: bgPath, angle: -45)

// Faint outer ring (unfilled track).
let ringInset: CGFloat = 168
let ringRect = fullRect.insetBy(dx: ringInset, dy: ringInset)
NSColor.white.withAlphaComponent(0.12).setStroke()
let ringPath = NSBezierPath(ovalIn: ringRect)
ringPath.lineWidth = 64
ringPath.stroke()

// Pie slice — fills clockwise from 12 o'clock, ~70%, gradient teal -> violet -> pink.
let center = NSPoint(x: size / 2, y: size / 2)
let radius = ringRect.width / 2
let percent: CGFloat = 70
let sweep = percent / 100 * 360

let piePath = NSBezierPath()
piePath.move(to: center)
piePath.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
piePath.close()

NSGraphicsContext.saveGraphicsState()
piePath.addClip()
let pieGradient = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 0.369, green: 0.918, blue: 0.831, alpha: 1), 0.0),
    (NSColor(calibratedRed: 0.655, green: 0.545, blue: 0.980, alpha: 1), 0.5),
    (NSColor(calibratedRed: 0.957, green: 0.447, blue: 0.714, alpha: 1), 1.0)
)
pieGradient?.draw(from: NSPoint(x: center.x, y: center.y + radius), to: NSPoint(x: center.x, y: center.y - radius), options: [])
NSGraphicsContext.restoreGraphicsState()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Failed to render icon")
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
