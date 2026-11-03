import Foundation
import simd
import ShotEngine

public struct TableSolution: Sendable {
    public var pose: TablePose
    /// How far the tapped corners sit from a rectangle of the right size, in millimetres.
    public var residualMm: Double
}

/// Finds the table from four tapped corners and its known size.
///
/// Cloth has little texture for AR to lock on to, so this doesn't rely on plane detection.
/// A table is level and ARKit knows which way is up, so only the height, the position on the
/// floor and the turn are unknown. For a trial height the four rays land on four points, and
/// the right height is the one where those points best fit a rectangle of the known size.
public enum TableSolver {
    /// - Parameter rays: one ray per corner, going round the table in order. Any start and direction.
    public static func solve(rays: [Ray], lengthMm: Double, widthMm: Double) -> TableSolution? {
        guard rays.count == 4 else { return nil }
        let l = lengthMm / 2000, w = widthMm / 2000
        let longFirst = [Vec2(-l, -w), Vec2(l, -w), Vec2(l, w), Vec2(-l, w)]
        let shortFirst = [Vec2(l, -w), Vec2(l, w), Vec2(-l, w), Vec2(-l, -w)]
        let layouts = [longFirst, shortFirst, longFirst.reversed(), shortFirst.reversed()]

        let top = rays.map(\.origin.y).min() ?? 0
        var best: (height: Double, residual: Double, layout: [Vec2])?

        for layout in layouts.map({ Array($0) }) {
            var bestHeight: Double?
            var bestResidual = Double.infinity
            for step in 0...48 {
                let h = top - 0.05 - Double(step) * 0.05
                if let fit = fit(rays, height: h, layout: layout), fit.residual < bestResidual {
                    bestResidual = fit.residual
                    bestHeight = h
                }
            }
            guard let start = bestHeight else { continue }

            // Golden section search around the best coarse height.
            var a = start - 0.05, b = min(start + 0.05, top - 0.01)
            let ratio = (5.0.squareRoot() - 1) / 2
            for _ in 0..<40 {
                let c = b - (b - a) * ratio, d = a + (b - a) * ratio
                let fc = fit(rays, height: c, layout: layout)?.residual ?? .infinity
                let fd = fit(rays, height: d, layout: layout)?.residual ?? .infinity
                if fc < fd { b = d } else { a = c }
            }
            let h = (a + b) / 2
            if let f = fit(rays, height: h, layout: layout), f.residual < best?.residual ?? .infinity {
                best = (h, f.residual, layout)
            }
        }

        guard let best, let result = fit(rays, height: best.height, layout: best.layout) else { return nil }
        return TableSolution(pose: result.pose, residualMm: result.residual * 1000)
    }

    /// Lands the rays on a level plane, then fits the rectangle to them by best rotation.
    private static func fit(_ rays: [Ray], height: Double, layout: [Vec2]) -> (pose: TablePose, residual: Double)? {
        var points: [Vec2] = []
        for ray in rays {
            guard abs(ray.direction.y) > 1e-6 else { return nil }
            let t = (height - ray.origin.y) / ray.direction.y
            guard t > 0 else { return nil }
            let p = ray.origin + ray.direction * t
            // World x and -z, so that seen from above the plane has the same handedness as the table.
            points.append(Vec2(p.x, -p.z))
        }
        let centroid = points.reduce(.zero, +) / 4

        var sumCos = 0.0, sumSin = 0.0
        for (p, m) in zip(points, layout) {
            let q = p - centroid
            sumCos += m.dot(q)
            sumSin += m.cross(q)
        }
        let angle = atan2(sumSin, sumCos)

        var total = 0.0
        for (p, m) in zip(points, layout) {
            let e = m.rotated(byRadians: angle) + centroid - p
            total += e.dot(e)
        }
        let residual = (total / 4).squareRoot()
        let axis = Vec2(cos(angle), sin(angle))
        let pose = TablePose(
            centre: SIMD3(centroid.x, height, -centroid.y),
            xAxis: SIMD3(axis.x, 0, -axis.y)
        )
        return (pose, residual)
    }
}
