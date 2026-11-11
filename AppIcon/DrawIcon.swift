import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}

func rounded(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: width, height: height),
           cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fill(_ path: CGPath, with paint: CGColor, in ctx: CGContext) {
    ctx.addPath(path)
    ctx.setFillColor(paint)
    ctx.fillPath()
}

func stroke(_ path: CGPath, with paint: CGColor, width: CGFloat, in ctx: CGContext) {
    ctx.addPath(path)
    ctx.setStrokeColor(paint)
    ctx.setLineWidth(width)
    ctx.strokePath()
}

func gradient(_ path: CGPath, colors: [CGColor], from start: CGPoint, to end: CGPoint, in ctx: CGContext) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let ramp = CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(ramp, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()
}

func render(_ size: Int, to url: URL) throws {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: rgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let scale = CGFloat(size) / 1024
    ctx.scaleBy(x: scale, y: -scale)
    ctx.translateBy(x: 0, y: -1024)

    let tile = rounded(89, 79, 846, 846, 197)
    if size >= 32 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18 * scale), blur: 31 * scale,
                      color: color(0x21114F, alpha: 0.32))
        fill(tile, with: color(0x281A67), in: ctx)
        ctx.restoreGState()
    }
    gradient(tile, colors: [color(0x8468FA), color(0x593CCF), color(0x251658)],
             from: CGPoint(x: 126, y: 90), to: CGPoint(x: 904, y: 905), in: ctx)

    if size >= 64 {
        ctx.saveGState()
        ctx.addPath(tile)
        ctx.clip()
        let glow = CGGradient(colorsSpace: rgb, colors: [color(0xBFABFF, alpha: 0.48),
                                                        color(0xA591FF, alpha: 0)] as CFArray, locations: nil)!
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 232, y: 120), startRadius: 0,
                               endCenter: CGPoint(x: 258, y: 182), endRadius: 490,
                               options: [.drawsAfterEndLocation])
        ctx.restoreGState()
        stroke(rounded(92, 82, 840, 840, 195), with: color(0xEBE0FF, alpha: 0.30), width: 4, in: ctx)
    }

    let panel = rounded(219, 225, 586, 541, 98)
    if size >= 32 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12 * scale), blur: 26 * scale,
                      color: color(0x1F0B4D, alpha: 0.42))
        fill(panel, with: color(0x332174), in: ctx)
        ctx.restoreGState()
    }
    gradient(panel, colors: [color(0x443285), color(0x2D1B68)],
             from: CGPoint(x: 252, y: 238), to: CGPoint(x: 772, y: 764), in: ctx)
    stroke(rounded(222, 228, 580, 535, 95), with: color(0xC8B6FF, alpha: 0.30), width: 4, in: ctx)

    let signal: [(CGFloat, CGFloat, UInt32)] = [
        (322, 46, 0xB69DFF), (385, 91, 0xD7CAFF), (448, 142, 0xF2EBFF),
        (512, 196, 0xFFF8FF), (576, 138, 0xEFE7FF), (639, 86, 0xCDBBFF), (702, 44, 0xA894F7)
    ]
    for (x, height, tone) in signal {
        let width: CGFloat = size <= 32 ? 33 : 31
        fill(rounded(x - width / 2, 398 - height / 2, width, height, width / 2),
             with: color(tone), in: ctx)
    }

    let keys = rounded(275, 548, 474, 157, 34)
    gradient(keys, colors: [color(0xFEF9FF), color(0xD6CAFF)],
             from: CGPoint(x: 512, y: 550), to: CGPoint(x: 512, y: 712), in: ctx)
    for division in 1...4 {
        let x = 275 + CGFloat(division) * 474 / 5
        fill(rounded(x - 4, 548, 8, 157, 2), with: color(0x4D358C), in: ctx)
    }
    for division in [1, 2, 4] {
        let x = 275 + CGFloat(division) * 474 / 5
        let blackKey = rounded(x - 25, 539, 50, 93, 11)
        gradient(blackKey, colors: [color(0x503992), color(0x2B1B60)],
                 from: CGPoint(x: x, y: 540), to: CGPoint(x: x, y: 631), in: ctx)
        if size >= 64 {
            stroke(blackKey, with: color(0xBC9FFF, alpha: 0.36), width: 2, in: ctx)
        }
    }

    let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(file, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(file) else { throw CocoaError(.fileWriteUnknown) }
}

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let preview = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    let name = "icon_\(size)x\(size)"
    try render(size, to: iconset.appendingPathComponent(name + ".png"))
    try render(size * 2, to: iconset.appendingPathComponent(name + "@2x.png"))
}
try render(512, to: preview)
