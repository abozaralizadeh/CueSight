import Foundation
import simd
import ShotEngine

public struct PixelPoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }
}

public struct Ray: Sendable {
    public var origin: SIMD3<Double>
    public var direction: SIMD3<Double>

    public init(origin: SIMD3<Double>, direction: SIMD3<Double>) {
        self.origin = origin
        self.direction = simd_normalize(direction)
    }
}

/// A pinhole camera using ARKit's conventions: world units are metres, world +Y is up,
/// and the camera looks down its own -Z axis with +X right and +Y up.
public struct CameraModel: Sendable {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    public var width: Int
    public var height: Int
    /// Camera to world. The columns are the camera's axes, then its position.
    public var transform: simd_double4x4

    public init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int, transform: simd_double4x4) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.width = width
        self.height = height
        self.transform = transform
    }

    public var position: SIMD3<Double> {
        let c = transform.columns.3
        return SIMD3(c.x, c.y, c.z)
    }

    private var rotation: simd_double3x3 {
        let c = transform.columns
        return simd_double3x3(
            SIMD3(c.0.x, c.0.y, c.0.z),
            SIMD3(c.1.x, c.1.y, c.1.z),
            SIMD3(c.2.x, c.2.y, c.2.z)
        )
    }

    /// World point to pixel, plus its depth in front of the camera. Nil if it's behind the camera.
    public func project(_ world: SIMD3<Double>) -> (pixel: PixelPoint, depth: Double)? {
        let p = rotation.transpose * (world - position)
        let depth = -p.z
        guard depth > 0.01 else { return nil }
        return (PixelPoint(cx + fx * p.x / depth, cy - fy * p.y / depth), depth)
    }

    public func ray(through pixel: PixelPoint) -> Ray {
        let dir = SIMD3((pixel.x - cx) / fx, -(pixel.y - cy) / fy, -1.0)
        return Ray(origin: position, direction: rotation * dir)
    }

    /// The same camera at a different image size, as when working on a reduced frame.
    public func scaled(by s: Double) -> CameraModel {
        CameraModel(
            fx: fx * s, fy: fy * s, cx: cx * s, cy: cy * s,
            width: Int(Double(width) * s), height: Int(Double(height) * s), transform: transform
        )
    }

    public static func look(
        from position: SIMD3<Double>,
        at target: SIMD3<Double>,
        fx: Double,
        width: Int,
        height: Int
    ) -> CameraModel {
        let back = simd_normalize(position - target)
        let right = simd_normalize(simd_cross(SIMD3(0, 1, 0), back))
        let up = simd_cross(back, right)
        let t = simd_double4x4(
            SIMD4(right, 0), SIMD4(up, 0), SIMD4(back, 0), SIMD4(position, 1)
        )
        return CameraModel(
            fx: fx, fy: fx, cx: Double(width) / 2, cy: Double(height) / 2,
            width: width, height: height, transform: t
        )
    }
}

extension CameraModel: Codable {
    private enum CodingKeys: String, CodingKey {
        case fx, fy, cx, cy, width, height, transform
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode([Double].self, forKey: .transform)
        guard v.count == 16 else {
            throw DecodingError.dataCorruptedError(forKey: .transform, in: c, debugDescription: "Needs 16 numbers")
        }
        self.init(
            fx: try c.decode(Double.self, forKey: .fx),
            fy: try c.decode(Double.self, forKey: .fy),
            cx: try c.decode(Double.self, forKey: .cx),
            cy: try c.decode(Double.self, forKey: .cy),
            width: try c.decode(Int.self, forKey: .width),
            height: try c.decode(Int.self, forKey: .height),
            transform: simd_double4x4(
                SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15])
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(fx, forKey: .fx)
        try c.encode(fy, forKey: .fy)
        try c.encode(cx, forKey: .cx)
        try c.encode(cy, forKey: .cy)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        let m = transform.columns
        let values = [m.0, m.1, m.2, m.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        try c.encode(values, forKey: .transform)
    }
}

/// Where the table sits in the AR world. The table is taken to be level, so `up` is world up.
public struct TablePose: Codable, Hashable, Sendable {
    /// Centre of the playing area, on the cloth, in metres.
    public var centre: SIMD3<Double>
    /// World direction of the table's long axis.
    public var xAxis: SIMD3<Double>

    public init(centre: SIMD3<Double>, xAxis: SIMD3<Double>) {
        self.centre = centre
        self.xAxis = simd_normalize(xAxis)
    }

    public var up: SIMD3<Double> { SIMD3(0, 1, 0) }
    public var yAxis: SIMD3<Double> { simd_cross(up, xAxis) }

    /// Table millimetres to world metres. `z` is the height above the cloth.
    public func world(_ p: Vec2, z: Double = 0) -> SIMD3<Double> {
        centre + xAxis * (p.x / 1000) + yAxis * (p.y / 1000) + up * (z / 1000)
    }

    public func table(_ world: SIMD3<Double>) -> Vec2 {
        let d = world - centre
        return Vec2(simd_dot(d, xAxis) * 1000, simd_dot(d, yAxis) * 1000)
    }

    /// Where a ray crosses a level plane `z` mm above the cloth.
    public func intersect(_ ray: Ray, z: Double = 0) -> Vec2? {
        let planeHeight = centre.y + z / 1000
        guard abs(ray.direction.y) > 1e-6 else { return nil }
        let t = (planeHeight - ray.origin.y) / ray.direction.y
        guard t > 0 else { return nil }
        return table(ray.origin + ray.direction * t)
    }

    public var transform: simd_double4x4 {
        simd_double4x4(SIMD4(xAxis, 0), SIMD4(up, 0), SIMD4(simd_cross(xAxis, up), 0), SIMD4(centre, 1))
    }
}
