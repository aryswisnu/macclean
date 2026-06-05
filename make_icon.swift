import AppKit
import CoreGraphics

let size: CGFloat = 1024
let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no graphics context")
}

// Squircle background with gradient
let cornerRadius: CGFloat = size * 0.2237  // macOS app icon corner radius ratio
let rect = CGRect(x: 0, y: 0, width: size, height: size)
let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

ctx.saveGState()
ctx.addPath(path)
ctx.clip()

// Gradient: deep blue → teal
let colorSpace = CGColorSpaceCreateDeviceRGB()
let colors = [
    CGColor(srgbRed: 0.16, green: 0.42, blue: 0.95, alpha: 1.0),  // blue
    CGColor(srgbRed: 0.10, green: 0.75, blue: 0.85, alpha: 1.0),  // teal
] as CFArray
let locations: [CGFloat] = [0.0, 1.0]
let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: locations)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: []
)

// Inner glow / highlight at top
let highlightColors = [
    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.22),
    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0),
] as CFArray
let highlight = CGGradient(colorsSpace: colorSpace, colors: highlightColors, locations: [0, 1])!
ctx.drawRadialGradient(
    highlight,
    startCenter: CGPoint(x: size * 0.5, y: size * 0.95),
    startRadius: 0,
    endCenter: CGPoint(x: size * 0.5, y: size * 0.95),
    endRadius: size * 0.7,
    options: []
)

ctx.restoreGState()

// Draw SF Symbol "sparkles" centered, white
let symbolName = "sparkles"
let config = NSImage.SymbolConfiguration(pointSize: size * 0.55, weight: .bold)
    .applying(.init(paletteColors: [.white]))

if let symbolImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
    .withSymbolConfiguration(config) {
    let symbolSize = symbolImage.size
    let scale = (size * 0.6) / max(symbolSize.width, symbolSize.height)
    let drawSize = CGSize(width: symbolSize.width * scale, height: symbolSize.height * scale)
    let origin = CGPoint(x: (size - drawSize.width) / 2, y: (size - drawSize.height) / 2)

    // Soft shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.04, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
    symbolImage.draw(in: CGRect(origin: origin, size: drawSize))
    ctx.restoreGState()
} else {
    // Fallback: draw "MC" text
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.4, weight: .heavy),
        .foregroundColor: NSColor.white
    ]
    let text = "MC" as NSString
    let textSize = text.size(withAttributes: attrs)
    text.draw(at: CGPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2), withAttributes: attrs)
}

image.unlockFocus()

// Save PNG
guard let tiffData = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiffData),
      let pngData = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("png encoding failed")
}

let url = URL(fileURLWithPath: outputPath)
try! pngData.write(to: url)
print("Wrote \(outputPath)")
