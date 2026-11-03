import Foundation

/// A point or direction on the table, in millimetres.
public struct Vec2: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
    public static prefix func - (a: Vec2) -> Vec2 { Vec2(-a.x, -a.y) }

    public func dot(_ o: Vec2) -> Double { x * o.x + y * o.y }
    public func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    public var length: Double { (x * x + y * y).squareRoot() }
    public var perpendicular: Vec2 { Vec2(-y, x) }

    public var normalized: Vec2 {
        let l = length
        return l > 0 ? self / l : .zero
    }

    public func distance(to o: Vec2) -> Double { (self - o).length }

    public func rotated(byRadians a: Double) -> Vec2 {
        let c = cos(a), s = sin(a)
        return Vec2(x * c - y * s, x * s + y * c)
    }

    /// Shortest distance from this point to the segment a to b.
    public func distance(toSegment a: Vec2, _ b: Vec2) -> Double {
        let ab = b - a
        let lengthSquared = ab.dot(ab)
        guard lengthSquared > 0 else { return distance(to: a) }
        let t = max(0, min(1, (self - a).dot(ab) / lengthSquared))
        return distance(to: a + ab * t)
    }
}

public extension Array where Element == Vec2 {
    /// Total length of a path through these points.
    var pathLength: Double {
        guard count > 1 else { return 0 }
        return zip(self, dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }
}
