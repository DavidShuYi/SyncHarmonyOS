// make-icon.swift — renders the SyncHarmonyOS app icon with CoreGraphics.
// Usage: swift make-icon.swift <output.iconset directory>
// Draws: rounded-rect gradient background + two transfer arrows.

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <iconset-dir>\n".utf8))
    exit(1)
}
let iconsetPath = CommandLine.arguments[1]

func renderIcon(size: CGFloat) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: Int(size), height: Int(size),
                            bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    let s = size / 1024 // design-space scale factor (drawn for 1024 px)

    // macOS 11+ squircle background with blue→teal gradient.
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let corner = 232 * s
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    context.addPath(path)
    context.clip()

    let colors = [CGColor(red: 0.16, green: 0.42, blue: 0.96, alpha: 1),
                  CGColor(red: 0.02, green: 0.66, blue: 0.72, alpha: 1)] as CFArray
    let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0), options: [])

    // Two rounded transfer arrows (up-right and down-left).
    let arrow = { (offsetY: CGFloat, flip: Bool) in
        context.saveGState()
        let cx = size / 2
        let cy = size / 2 + offsetY * s
        context.translateBy(x: cx, y: cy)
        if flip { context.rotate(by: .pi) }
        // Shaft
        let shaft = CGRect(x: -150 * s, y: -46 * s, width: 260 * s, height: 92 * s)
        context.addPath(CGPath(roundedRect: shaft, cornerWidth: 40 * s, cornerHeight: 40 * s, transform: nil))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fillPath()
        // Head (triangle)
        context.move(to: CGPoint(x: 60 * s, y: -150 * s))
        context.addLine(to: CGPoint(x: 210 * s, y: 0))
        context.addLine(to: CGPoint(x: 60 * s, y: 150 * s))
        context.closePath()
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fillPath()
        context.restoreGState()
    }
    arrow(160, false)   // top arrow → right
    arrow(-160, true)   // bottom arrow → left

    return context.makeImage()!
}

func writePNG(_ image: CGImage, size: Int, name: String) {
    let url = URL(fileURLWithPath: iconsetPath).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

try? FileManager.default.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

let scales: [(base: Int, scale: Int)] = [
    (16, 1), (16, 2),
    (32, 1), (32, 2),
    (128, 1), (128, 2),
    (256, 1), (256, 2),
    (512, 1), (512, 2)
]
for (base, scale) in scales {
    let pixels = CGFloat(base * scale)
    let image = renderIcon(size: pixels)
    let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
    writePNG(image, size: base * scale, name: name)
    print("rendered \(name) (\(base * scale)px)")
}
print("iconset ready: \(iconsetPath)")
