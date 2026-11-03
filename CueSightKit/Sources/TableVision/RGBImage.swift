import Foundation

/// A plain 8-bit RGB image, three bytes per pixel, row by row.
public struct RGBImage: Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 3)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: 0, count: width * height * 3))
    }

    @inline(__always)
    public func rgb(_ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
        let i = (y * width + x) * 3
        return pixels.withUnsafeBufferPointer { p in
            (Double(p[i]), Double(p[i + 1]), Double(p[i + 2]))
        }
    }
}

public struct HSV: Sendable {
    public var hue: Double          // 0 to 360
    public var saturation: Double   // 0 to 1
    public var value: Double        // 0 to 1

    public init(r: Double, g: Double, b: Double) {
        let maxC = max(r, g, b), minC = min(r, g, b)
        let delta = maxC - minC
        value = maxC / 255
        saturation = maxC > 0 ? delta / maxC : 0
        guard delta > 0 else {
            hue = 0
            return
        }
        var h: Double
        if maxC == r {
            h = (g - b) / delta
        } else if maxC == g {
            h = (b - r) / delta + 2
        } else {
            h = (r - g) / delta + 4
        }
        h *= 60
        hue = h < 0 ? h + 360 : h
    }
}
