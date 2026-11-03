import Foundation
import simd
import ShotEngine

/// What a single frame says about one ball.
public struct Sighting: Sendable {
    public var position: Vec2
    /// How much to trust the position along each table axis. It's the inverse of the covariance,
    /// so a low viewing angle gives a weak value along the line of sight.
    public var informationXX: Double
    public var informationXY: Double
    public var informationYY: Double
    public var colour: ColourEvidence
    public var score: Double
}

/// Swap this out to try a trained model. The rest of the app only sees sightings.
public protocol BallDetecting: Sendable {
    func detect(image: RGBImage, camera: CameraModel, pose: TablePose, table: TableProfile) -> [Sighting]
}

/// Tells cloth from everything else, using colour ratios so shadows still count as cloth.
struct ClothModel {
    var red: Double
    var green: Double
    var value: Double

    static func estimate(image: RGBImage, camera: CameraModel, pose: TablePose, table: TableProfile) -> ClothModel? {
        var reds: [Double] = [], greens: [Double] = [], values: [Double] = []
        let stepX = table.lengthMm / 40, stepY = table.widthMm / 20
        var x = -table.lengthMm / 2 + stepX
        while x < table.lengthMm / 2 {
            var y = -table.widthMm / 2 + stepY
            while y < table.widthMm / 2 {
                if let hit = camera.project(pose.world(Vec2(x, y))) {
                    let px = Int(hit.pixel.x), py = Int(hit.pixel.y)
                    if px >= 0, py >= 0, px < image.width, py < image.height {
                        let c = image.rgb(px, py)
                        let sum = c.r + c.g + c.b + 1
                        reds.append(c.r / sum)
                        greens.append(c.g / sum)
                        values.append(max(c.r, c.g, c.b))
                    }
                }
                y += stepY
            }
            x += stepX
        }
        guard reds.count >= 30 else { return nil }
        return ClothModel(red: median(reds), green: median(greens), value: median(values))
    }

    /// Above 1 means "not cloth". The value is continuous, so an edge can be placed between pixels.
    @inline(__always)
    func difference(r: Double, g: Double, b: Double, localValue: Double? = nil) -> Double {
        let sum = r + g + b + 1
        let dr = r / sum - red, dg = g / sum - green
        let colour = (dr * dr + dg * dg).squareRoot()
        let v = max(r, g, b)
        // Dark pixels have noisy ratios, so they need a bigger colour shift to count.
        let colourLimit = v < 60 ? 0.11 : 0.05
        let colourScore = colour / colourLimit
        // Shadows and lamp pools change brightness, so "dark" means dark next to the cloth around it.
        let darkScore = 0.5 * (localValue ?? value) / max(v, 1)
        return max(colourScore, darkScore)
    }
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    return sorted[sorted.count / 2]
}

public struct ClassicBallDetector: BallDetecting {
    public var pixelNoise = 0.6

    public init() {}

    public func detect(image: RGBImage, camera: CameraModel, pose: TablePose, table: TableProfile) -> [Sighting] {
        guard let cloth = ClothModel.estimate(image: image, camera: camera, pose: pose, table: table) else { return [] }
        let radius = table.ballRadiusMm
        let measure = Measure(image: image, cloth: cloth)

        // Try ball-sized spots over the whole table and keep the ones that look like a ball on cloth.
        let step = table.ballDiameterMm / 3
        let limitX = table.lengthMm / 2 - radius, limitY = table.widthMm / 2 - radius
        var candidates: [(position: Vec2, score: Double)] = []
        var x = -limitX
        while x <= limitX {
            var y = -limitY
            while y <= limitY {
                let p = Vec2(x, y)
                if let score = measure.discScore(at: p, camera: camera, pose: pose, table: table), score > 0.55 {
                    candidates.append((p, score))
                }
                y += step
            }
            x += step
        }

        candidates.sort { $0.score > $1.score }
        var kept: [(position: Vec2, score: Double)] = []
        for candidate in candidates
        where !kept.contains(where: { $0.position.distance(to: candidate.position) < table.ballDiameterMm * 0.8 }) {
            kept.append(candidate)
        }

        var sightings: [Sighting] = []
        for candidate in kept {
            if let sighting = refine(candidate.position, candidate.score, measure, camera, pose, table) {
                sightings.append(sighting)
            }
        }
        return sightings
    }

    private func refine(
        _ start: Vec2,
        _ startScore: Double,
        _ measure: Measure,
        _ camera: CameraModel,
        _ pose: TablePose,
        _ table: TableProfile
    ) -> Sighting? {
        let radius = table.ballRadiusMm
        var best = start
        var bestScore = startScore
        for stepSize in [8.0, 4.0, 2.0] {
            var improved = true
            while improved {
                improved = false
                for offset in [Vec2(stepSize, 0), Vec2(-stepSize, 0), Vec2(0, stepSize), Vec2(0, -stepSize)] {
                    let p = best + offset
                    if let s = measure.discScore(at: p, camera: camera, pose: pose, table: table), s > bestScore {
                        bestScore = s
                        best = p
                        improved = true
                    }
                }
            }
        }

        guard let hit = camera.project(pose.world(best, z: radius)) else { return nil }
        let expectedRadius = camera.fx * radius / 1000 / hit.depth
        guard expectedRadius >= 2 else { return nil }

        let fitted = measure.fitEdge(centre: hit.pixel, radius: expectedRadius) ?? hit.pixel
        guard let position = pose.intersect(camera.ray(through: fitted), z: radius) else { return nil }
        guard table.contains(ballCentre: position, tolerance: radius * 0.6) else { return nil }

        // Pixel noise mapped on to the table: a step of one pixel in each direction.
        guard
            let dx = pose.intersect(camera.ray(through: PixelPoint(fitted.x + 1, fitted.y)), z: radius),
            let dy = pose.intersect(camera.ray(through: PixelPoint(fitted.x, fitted.y + 1)), z: radius)
        else { return nil }
        let jx = dx - position, jy = dy - position
        let noise = pixelNoise * pixelNoise
        let xx = (jx.x * jx.x + jy.x * jy.x) * noise + 0.25
        let xy = (jx.x * jx.y + jy.x * jy.y) * noise
        let yy = (jx.y * jx.y + jy.y * jy.y) * noise + 0.25
        let det = xx * yy - xy * xy
        guard det > 0 else { return nil }

        // A pocket looks like a dark ball. A real black ball hanging over a pocket gets lost here,
        // and review is where the player adds it back.
        let colour = measure.colour(centre: fitted, radius: expectedRadius)
        let nearPocket = table.pockets.contains { position.distance(to: $0.centre) < $0.mouthWidth * 0.62 + radius * 1.6 }
        if nearPocket && colour.blackShare > 0.35 { return nil }

        return Sighting(
            position: table.clamped(ballCentre: position),
            informationXX: yy / det,
            informationXY: -xy / det,
            informationYY: xx / det,
            colour: colour,
            score: bestScore
        )
    }
}

/// The pixel work, kept apart from the search above.
struct Measure {
    let image: RGBImage
    let cloth: ClothModel

    @inline(__always)
    func notCloth(_ x: Double, _ y: Double, localValue: Double? = nil) -> Double? {
        let px = Int(x), py = Int(y)
        guard px >= 0, py >= 0, px < image.width, py < image.height else { return nil }
        let c = image.rgb(px, py)
        return cloth.difference(r: c.r, g: c.g, b: c.b, localValue: localValue)
    }

    /// How bright the cloth is just outside a ball. The brighter half of the samples is used,
    /// because shadows and neighbouring balls pull the other half down.
    func localClothValue(cx: Double, cy: Double, radius r: Double) -> Double? {
        var values: [Double] = []
        for (dx, dy, _) in Measure.ringPattern {
            let px = Int(cx + dx * r * 1.9), py = Int(cy + dy * r * 1.9)
            guard px >= 0, py >= 0, px < image.width, py < image.height else { continue }
            let c = image.rgb(px, py)
            if cloth.difference(r: c.r, g: c.g, b: c.b, localValue: 1) <= 1 {
                values.append(max(c.r, c.g, c.b))
            }
        }
        guard values.count >= 3 else { return nil }
        values.sort()
        return values[values.count * 3 / 4]
    }

    /// Smooth version for placing edges between pixels.
    func notClothSmooth(_ x: Double, _ y: Double, localValue: Double?) -> Double? {
        let px = Int(x.rounded(.down)), py = Int(y.rounded(.down))
        guard px >= 0, py >= 0, px + 1 < image.width, py + 1 < image.height else { return nil }
        let fx = x - Double(px), fy = y - Double(py)
        func at(_ a: Int, _ b: Int) -> Double {
            let c = image.rgb(a, b)
            return min(cloth.difference(r: c.r, g: c.g, b: c.b, localValue: localValue), 2)
        }
        let top = at(px, py) * (1 - fx) + at(px + 1, py) * fx
        let bottom = at(px, py + 1) * (1 - fx) + at(px + 1, py + 1) * fx
        return top * (1 - fy) + bottom * fy
    }

    /// High when the disc at this table spot is full of not-cloth and its surrounding ring is cloth.
    func discScore(at p: Vec2, camera: CameraModel, pose: TablePose, table: TableProfile) -> Double? {
        let radius = table.ballRadiusMm
        guard let hit = camera.project(pose.world(p, z: radius)) else { return nil }
        let r = camera.fx * radius / 1000 / hit.depth
        guard r >= 2 else { return nil }
        let cx = hit.pixel.x, cy = hit.pixel.y
        guard cx > r, cy > r, cx < Double(image.width) - r, cy < Double(image.height) - r else { return nil }

        let local = localClothValue(cx: cx, cy: cy, radius: r)
        var inside = 0, insideCount = 0
        for (dx, dy, scale) in Measure.discPattern {
            if let d = notCloth(cx + dx * r * scale, cy + dy * r * scale, localValue: local) {
                insideCount += 1
                if d > 1 { inside += 1 }
            }
        }
        guard insideCount > 8 else { return nil }
        let fill = Double(inside) / Double(insideCount)
        guard fill > 0.6 else { return 0 }

        var ring = 0, ringCount = 0
        for (dx, dy, _) in Measure.ringPattern {
            if let d = notCloth(cx + dx * r * 1.3, cy + dy * r * 1.3, localValue: local) {
                ringCount += 1
                if d > 1 { ring += 1 }
            }
        }
        guard ringCount > 6 else { return nil }
        // A neighbouring ball can fill part of the ring, so this only takes a partial penalty.
        return fill - 0.45 * Double(ring) / Double(ringCount)
    }

    /// Roughly how bright cloth comes out in a well-exposed frame.
    static let normalClothValue = 130.0

    static let ringPattern: [(Double, Double, Double)] = (0..<16).map {
        let a = Double($0) / 16 * 2 * .pi
        return (cos(a), sin(a), 1)
    }

    static let discPattern: [(Double, Double, Double)] = {
        var points: [(Double, Double, Double)] = [(0, 0, 1)]
        for (count, scale) in [(6, 0.4), (10, 0.65), (14, 0.88)] {
            for i in 0..<count {
                let a = Double(i) / Double(count) * 2 * .pi
                points.append((cos(a), sin(a), scale))
            }
        }
        return points
    }()

    /// Finds the ball's outline along spokes from the centre, then fits a circle to it.
    func fitEdge(centre: PixelPoint, radius: Double) -> PixelPoint? {
        var points: [PixelPoint] = []
        let local = localClothValue(cx: centre.x, cy: centre.y, radius: radius)
        let spokes = 64
        for i in 0..<spokes {
            let a = Double(i) / Double(spokes) * 2 * .pi
            let ux = cos(a), uy = sin(a)
            var previous: Double?
            var t = radius * 1.35
            var edge: Double?
            // Walk inwards from the cloth to the first ball pixel.
            while t > radius * 0.65 {
                guard let v = notClothSmooth(centre.x + ux * t, centre.y + uy * t, localValue: local) else { break }
                if let p = previous, p < 1, v >= 1 {
                    edge = t + 0.5 * (1 - v) / (p - v + 1e-9) * -1
                    break
                }
                previous = v
                t -= 0.5
            }
            if let edge, previous != nil {
                points.append(PixelPoint(centre.x + ux * edge, centre.y + uy * edge))
            }
        }
        guard points.count >= 14 else { return nil }

        // Keep the radius near what the geometry says and reject spokes that hit something else.
        var cx = centre.x, cy = centre.y, r = radius
        var active = points
        for round in 0..<6 {
            var sx = 0.0, sy = 0.0, sr = 0.0
            for p in active {
                let dx = p.x - cx, dy = p.y - cy
                let d = (dx * dx + dy * dy).squareRoot()
                sr += d
                sx += p.x - dx / max(d, 1e-6) * r
                sy += p.y - dy / max(d, 1e-6) * r
            }
            let n = Double(active.count)
            cx = sx / n
            cy = sy / n
            if active.count > 40 {
                r = min(max(sr / n, radius * 0.9), radius * 1.15)
            }
            if round >= 1 {
                let limit = max(1.0, radius * 0.1)
                let filtered = active.filter {
                    abs(($0.x - cx) * ($0.x - cx) + ($0.y - cy) * ($0.y - cy) - r * r) < 2 * r * limit
                }
                if filtered.count >= 10 { active = filtered }
            }
        }
        guard active.count >= 10 else { return nil }
        let moved = ((cx - centre.x) * (cx - centre.x) + (cy - centre.y) * (cy - centre.y)).squareRoot()
        return moved < radius * 0.7 ? PixelPoint(cx, cy) : nil
    }

    func colour(centre: PixelPoint, radius: Double) -> ColourEvidence {
        var evidence = ColourEvidence()
        // Brings balls in dim light up to the level the colour bands expect.
        let reference = localClothValue(cx: centre.x, cy: centre.y, radius: radius) ?? cloth.value
        let gain = max(0.7, min(4, Measure.normalClothValue / max(reference, 10)))
        let rings = [(1, 0.0), (8, 0.3), (14, 0.55), (20, 0.78)]
        for (count, scale) in rings {
            for i in 0..<count {
                let a = Double(i) / Double(count) * 2 * .pi
                let x = Int(centre.x + cos(a) * radius * scale)
                let y = Int(centre.y + sin(a) * radius * scale)
                guard x >= 0, y >= 0, x < image.width, y < image.height else { continue }
                let c = image.rgb(x, y)
                evidence.add(HSV(r: min(255, c.r * gain), g: min(255, c.g * gain), b: min(255, c.b * gain)))
            }
        }
        return evidence
    }
}
