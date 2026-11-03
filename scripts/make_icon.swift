// Draws the app icon: a ball on cloth with an aiming line. Run with: swift scripts/make_icon.swift <out.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.png"
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }

// Cloth with a soft lamp pool.
let cloth = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 0.16, green: 0.62, blue: 0.32, alpha: 1), CGColor(red: 0.05, green: 0.30, blue: 0.15, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(cloth, startCenter: CGPoint(x: 430, y: 600), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 760, options: [.drawsAfterEndLocation])

// Aiming line from the ball towards the top right corner.
ctx.setLineCap(.round)
ctx.setStrokeColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
ctx.setLineWidth(46)
ctx.move(to: CGPoint(x: 420, y: 420)); ctx.addLine(to: CGPoint(x: 880, y: 880)); ctx.strokePath()
ctx.setStrokeColor(CGColor(red: 1, green: 0.85, blue: 0.2, alpha: 1))
ctx.setLineWidth(28)
ctx.setLineDash(phase: 0, lengths: [60, 44])
ctx.move(to: CGPoint(x: 420, y: 420)); ctx.addLine(to: CGPoint(x: 880, y: 880)); ctx.strokePath()
ctx.setLineDash(phase: 0, lengths: [])

// Ghost ball ring.
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
ctx.setLineWidth(18)
ctx.strokeEllipse(in: CGRect(x: 560, y: 560, width: 200, height: 200))

// The cue ball, shaded.
let ball = CGGradient(colorsSpace: space, colors: [
    CGColor(red: 1, green: 1, blue: 1, alpha: 1), CGColor(red: 0.78, green: 0.78, blue: 0.74, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: 200, y: 200, width: 300, height: 300)); ctx.clip()
ctx.drawRadialGradient(ball, startCenter: CGPoint(x: 300, y: 400), startRadius: 10,
                       endCenter: CGPoint(x: 350, y: 350), endRadius: 170, options: [.drawsAfterEndLocation])
ctx.restoreGState()

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
