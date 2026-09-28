import AppKit
import CoreGraphics

// Renders a macOS-style app icon: the artwork clipped to the Big Sur+ rounded "squircle",
// 824 px inside a 1024 px transparent canvas, with a soft drop shadow.
// Usage: make-icon <art.png> <out-1024.png>

let args = CommandLine.arguments
guard args.count == 3, let art = NSImage(contentsOfFile: args[1]),
      let artCG = art.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("usage: make-icon <art.png> <out.png>")
}

let canvas = 1024
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)

/// Superellipse |x|^n + |y|^n = 1, close to Apple's continuous-corner icon shape.
func squircle(in r: CGRect, n: Double = 5.0, steps: Int = 720) -> CGPath {
    let path = CGMutablePath()
    let a = r.width / 2, b = r.height / 2, cx = r.midX, cy = r.midY
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let x = cx + a * copysign(pow(abs(c), 2 / n), c)
        let y = cy + b * copysign(pow(abs(s), 2 / n), s)
        i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath()
    return path
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
let shape = squircle(in: tile)

// Shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

// Artwork, clipped to the tile.
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
ctx.draw(artCG, in: tile)
ctx.restoreGState()

// Hairline inner edge so the tile separates from dark backgrounds.
ctx.addPath(shape)
ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.12))
ctx.setLineWidth(2)
ctx.strokePath()

let out = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: out)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2]) \(canvas)x\(canvas)")
