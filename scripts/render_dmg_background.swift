#!/usr/bin/env swift
import AppKit
import Foundation

let logicalWidth: CGFloat = 720
let logicalHeight: CGFloat = 460

func hexColor(_ hex: String) -> NSColor {
    var cString = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if cString.hasPrefix("#") { cString.remove(at: cString.startIndex) }
    var rgbValue: UInt64 = 0
    Scanner(string: cString).scanHexInt64(&rgbValue)
    return NSColor(
        srgbRed: CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0,
        green: CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0,
        blue: CGFloat(rgbValue & 0x0000FF) / 255.0,
        alpha: 1.0
    )
}

func renderBitmap(pixelsWide: Int, pixelsHigh: Int, scale: CGFloat) -> NSBitmapImageRep {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Failed to create NSBitmapImageRep")
    }
    
    rep.size = NSSize(width: logicalWidth, height: logicalHeight)
    
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
        fatalError("Failed to create NSGraphicsContext")
    }
    NSGraphicsContext.current = context
    let ctx = context.cgContext
    
    // Scale coordinate system to logical points, with (0,0) at top-left
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: 0, y: logicalHeight)
    ctx.scaleBy(x: 1, y: -1)
    
    let bgColor = hexColor("#F6F5FD")
    let cardFill = NSColor.white
    let cardBorder = hexColor("#DDD6F7")
    let inkColor = hexColor("#1E1A34")
    let mutedColor = hexColor("#6C6589")
    
    // 1. Fill entire background
    bgColor.setFill()
    ctx.fill(CGRect(x: 0, y: 0, width: logicalWidth, height: logicalHeight))
    
    // 2. Draw rounded card (x: 40, y: 190, w: 640, h: 178, radius: 21)
    let cardRect = CGRect(x: 40, y: 190, width: 640, height: 178)
    let cardPath = NSBezierPath(roundedRect: cardRect, xRadius: 21, yRadius: 21)
    cardFill.setFill()
    cardPath.fill()
    cardBorder.setStroke()
    cardPath.lineWidth = 1.5
    cardPath.stroke()
    
    // 3. Draw Connecting Arrow in Card
    let arrowY: CGFloat = 271
    let arrowStartX: CGFloat = 330
    let arrowEndX: CGFloat = 392
    
    ctx.saveGState()
    inkColor.setStroke()
    ctx.setLineWidth(2.5)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    
    // Main arrow shaft
    ctx.beginPath()
    ctx.move(to: CGPoint(x: arrowStartX, y: arrowY))
    ctx.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
    // Arrowhead
    ctx.move(to: CGPoint(x: arrowEndX - 8, y: arrowY - 6))
    ctx.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
    ctx.addLine(to: CGPoint(x: arrowEndX - 8, y: arrowY + 6))
    ctx.strokePath()
    ctx.restoreGState()
    
    // 4. Flip coordinate system for AppKit text rendering (top-down)
    ctx.translateBy(x: 0, y: logicalHeight)
    ctx.scaleBy(x: 1, y: -1)
    
    func drawString(_ text: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor, kern: CGFloat = 0) {
        let topY = logicalHeight - y
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .kern: kern
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let rect = CGRect(x: x, y: topY - font.ascender, width: logicalWidth - x - 20, height: 60)
        attributed.draw(in: rect)
    }
    
    // Header Wordmark
    let headerFont = NSFont.systemFont(ofSize: 11, weight: .bold)
    drawString("MIMRA", x: 44, y: 39, font: headerFont, color: inkColor, kern: 2.0)
    
    // Title
    let titleFont = NSFont.systemFont(ofSize: 34, weight: .bold)
    drawString("Welcome to Mimra", x: 43, y: 76, font: titleFont, color: inkColor)
    
    // Subtitle
    let subtitleFont = NSFont.systemFont(ofSize: 14.5, weight: .regular)
    drawString("Fast, private clipboard manager for macOS", x: 44, y: 133, font: subtitleFont, color: mutedColor)
    
    // Footer instruction
    let footerFont = NSFont.systemFont(ofSize: 13.5, weight: .medium)
    drawString("Drag Mimra into Applications to install.", x: 44, y: 388, font: footerFont, color: inkColor)
    
    // Compatibility footer
    let compatFont = NSFont.systemFont(ofSize: 11.5, weight: .regular)
    drawString("macOS 15.0+  ·  Apple Silicon", x: 44, y: 423, font: compatFont, color: mutedColor)
    
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func savePNG(rep: NSBitmapImageRep, path: String) {
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to convert image to PNG at \(path)")
    }
    try! pngData.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
let outputDir = args.count > 1 ? args[1] : "packaging/dmg"

let rep1x = renderBitmap(pixelsWide: 720, pixelsHigh: 460, scale: 1.0)
let rep2x = renderBitmap(pixelsWide: 1440, pixelsHigh: 920, scale: 2.0)

savePNG(rep: rep1x, path: "\(outputDir)/background.png")
savePNG(rep: rep2x, path: "\(outputDir)/background@2x.png")
print("✓ Rendered \(outputDir)/background.png (720x460)")
print("✓ Rendered \(outputDir)/background@2x.png (1440x920)")
