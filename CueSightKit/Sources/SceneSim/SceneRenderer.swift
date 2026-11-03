import Foundation
import simd
import ShotEngine
import TableVision

/// Draws a table the way a phone camera might see it, so the whole vision pipeline can run with
/// known answers. It has lamp pools, soft shadows, sensor noise and lens softness. It doesn't have
/// raised rails, cues, people, glare off the cloth or motion blur, so a pass here doesn't prove
/// anything about a real table.
public struct SceneRenderer: Sendable {
    public var noiseSigma = 3.0
    public var blur = true

    public init() {}

    private struct Lamp {
        var x: Double, y: Double, spread: Double, power: Double
    }

    private func lamps(for scene: SimScene) -> (ambient: Double, lamps: [Lamp], shadowShift: Vec2, shadowDepth: Double) {
        let l = scene.table.lengthMm, w = scene.table.widthMm
        switch scene.lighting {
        case .club:
            return (0.55, [
                Lamp(x: -l / 4, y: 0, spread: l * 0.45, power: 0.5),
                Lamp(x: l / 4, y: 0, spread: l * 0.45, power: 0.5),
            ], Vec2(0, 0), 0.5)
        case .dim:
            return (0.3, [
                Lamp(x: 0, y: 0, spread: l * 0.6, power: 0.28),
            ], Vec2(0, 0), 0.45)
        case .uneven:
            return (0.32, [
                Lamp(x: -l * 0.33, y: w * 0.2, spread: l * 0.3, power: 0.85),
                Lamp(x: l * 0.2, y: -w * 0.3, spread: l * 0.22, power: 0.5),
            ], Vec2(scene.table.ballRadiusMm * 0.8, scene.table.ballRadiusMm * -0.4), 0.6)
        }
    }

    public func render(_ scene: SimScene, camera: CameraModel, frameSeed: UInt64) -> RGBImage {
        let width = camera.width, height = camera.height
        var buffer = [Float](repeating: 0, count: width * height * 3)
        let table = scene.table
        let hl = table.lengthMm / 2, hw = table.widthMm / 2
        let light = lamps(for: scene)
        let pockets = table.pockets
        let positions = scene.balls.map { $0.ball.position + light.shadowShift }
        let shadowRadius = table.ballRadiusMm * 1.35

        func brightness(_ p: Vec2) -> Double {
            var total = light.ambient
            for lamp in light.lamps {
                let dx = (p.x - lamp.x) / lamp.spread, dy = (p.y - lamp.y) / lamp.spread
                total += lamp.power * exp(-(dx * dx + dy * dy))
            }
            return total
        }

        buffer.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                for x in 0..<width {
                    let ray = camera.ray(through: PixelPoint(Double(x) + 0.5, Double(y) + 0.5))
                    var colour = Colour(26, 25, 28)
                    if let p = scene.pose.intersect(ray) {
                        let ax = abs(p.x), ay = abs(p.y)
                        if ax < hl + 420 && ay < hw + 420 {
                            if ax < hl && ay < hw {
                                var shade = brightness(p)
                                for b in positions {
                                    let dx = p.x - b.x, dy = p.y - b.y
                                    let d2 = dx * dx + dy * dy
                                    if d2 < 16 * shadowRadius * shadowRadius {
                                        shade *= 1 - light.shadowDepth * exp(-d2 / (shadowRadius * shadowRadius))
                                    }
                                }
                                colour = scaled(scene.cloth, shade)
                            } else if ax < hl + 50 && ay < hw + 50 {
                                colour = scaled(scene.cloth, brightness(p) * 0.72)
                            } else if ax < hl + 150 && ay < hw + 150 {
                                colour = scaled(Colour(92, 56, 32), brightness(p) * 0.9)
                            }
                            for pocket in pockets where p.distance(to: pocket.centre) < pocket.mouthWidth * 0.62 {
                                colour = Colour(8, 8, 8)
                            }
                        }
                    }
                    let i = (y * width + x) * 3
                    out[i] = Float(colour.r)
                    out[i + 1] = Float(colour.g)
                    out[i + 2] = Float(colour.b)
                }
            }

            // Far balls first, so nearer ones cover them.
            let order = scene.balls.sorted {
                simd_distance(camera.position, scene.pose.world($0.ball.position)) >
                    simd_distance(camera.position, scene.pose.world($1.ball.position))
            }
            for ball in order {
                draw(ball, scene: scene, camera: camera, into: out, brightness: brightness(ball.ball.position))
            }
        }
        return finish(buffer, width: width, height: height, seed: frameSeed)
    }

    private func scaled(_ c: Colour, _ s: Double) -> Colour {
        Colour(c.r * s, c.g * s, c.b * s)
    }

    private func draw(
        _ ball: SimBall,
        scene: SimScene,
        camera: CameraModel,
        into out: UnsafeMutableBufferPointer<Float>,
        brightness: Double
    ) {
        let radiusM = scene.table.ballRadiusMm / 1000
        let centre = scene.pose.world(ball.ball.position, z: scene.table.ballRadiusMm)
        guard let hit = camera.project(centre) else { return }
        let r = camera.fx * radiusM / hit.depth
        let reach = r * 1.25 + 2
        let x0 = max(0, Int(hit.pixel.x - reach)), x1 = min(camera.width - 1, Int(hit.pixel.x + reach))
        let y0 = max(0, Int(hit.pixel.y - reach)), y1 = min(camera.height - 1, Int(hit.pixel.y + reach))
        guard x0 <= x1, y0 <= y1 else { return }

        let lightDirection = simd_normalize(SIMD3<Double>(0.2, 1, 0.1))
        let pattern = ball.spinAxis
        let helper = abs(pattern.y) < 0.9 ? SIMD3<Double>(0, 1, 0) : SIMD3<Double>(1, 0, 0)
        let numberAxis = simd_normalize(simd_cross(pattern, helper))
        let pixelSize = hit.depth / camera.fx

        for y in y0...y1 {
            for x in x0...x1 {
                let ray = camera.ray(through: PixelPoint(Double(x) + 0.5, Double(y) + 0.5))
                let toCentre = centre - ray.origin
                let along = simd_dot(toCentre, ray.direction)
                let closest = simd_length(toCentre - ray.direction * along)
                let coverage = max(0, min(1, (radiusM - closest) / pixelSize + 0.5))
                guard coverage > 0 else { continue }

                let inside = max(0, radiusM * radiusM - closest * closest).squareRoot()
                let point = ray.origin + ray.direction * (along - inside)
                let normal = simd_normalize(point - centre)

                var base = ball.colour
                let band = simd_dot(normal, pattern)
                if ball.striped {
                    if abs(band) > 0.48 { base = .white }
                    if simd_dot(normal, numberAxis) > 0.95 { base = .white }
                } else if ball.ball.kind != .cue, scene.table.game == .pool, simd_dot(normal, numberAxis) > 0.93 {
                    base = .white
                }

                let diffuse = max(0, simd_dot(normal, lightDirection))
                let reflect = simd_reflect(-lightDirection, normal)
                let shine = pow(max(0, simd_dot(reflect, -ray.direction)), 60)
                let shade = (0.45 + 0.6 * diffuse) * min(1.25, brightness)
                let red = base.r * shade + 240 * shine * brightness
                let green = base.g * shade + 240 * shine * brightness
                let blue = base.b * shade + 240 * shine * brightness

                let i = (y * camera.width + x) * 3
                let keep = Float(1 - coverage), add = Float(coverage)
                out[i] = out[i] * keep + Float(red) * add
                out[i + 1] = out[i + 1] * keep + Float(green) * add
                out[i + 2] = out[i + 2] * keep + Float(blue) * add
            }
        }
    }

    private func finish(_ buffer: [Float], width: Int, height: Int, seed: UInt64) -> RGBImage {
        var rng = SeededRandom(seed: seed)
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        let noise = Float(noiseSigma)
        buffer.withUnsafeBufferPointer { src in
            pixels.withUnsafeMutableBufferPointer { dst in
                for y in 0..<height {
                    for x in 0..<width {
                        // A small noise value shared across the channels, plus a little per channel.
                        let shared = Float(rng.gaussian(1)) * noise
                        for c in 0..<3 {
                            let i = (y * width + x) * 3 + c
                            var value = src[i]
                            if blur, x > 0, y > 0, x + 1 < width, y + 1 < height {
                                let edges = src[i - 3] + src[i + 3] + src[i - width * 3] + src[i + width * 3]
                                value = value * 0.6 + edges * 0.1
                            }
                            let v = value + shared
                            dst[i] = UInt8(max(0, min(255, v)))
                        }
                    }
                }
            }
        }
        return RGBImage(width: width, height: height, pixels: pixels)
    }
}
