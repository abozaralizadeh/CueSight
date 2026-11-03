import Foundation
import simd
import ShotEngine
import TableVision

/// Runs a generated scene through the same steps as the app: tap corners, solve the table,
/// sweep, detect, merge. Tap error is added on purpose, because a finger isn't perfect.
public struct ScanRunner: Sendable {
    public var options = SweepOptions()
    public var cornerTapErrorPixels = 3.0
    public var detector: any BallDetecting = ClassicBallDetector()
    public var renderer = SceneRenderer()

    public init() {}

    public struct Result: Sendable {
        public var balls: [Ball]
        public var pose: TablePose
        public var tableResidualMm: Double
        public var report: AccuracyReport
        public var kindsCorrect: Int
        public var kindsChecked: Int
    }

    public func corners(of table: TableProfile) -> [Vec2] {
        let l = table.lengthMm / 2, w = table.widthMm / 2
        return [Vec2(-l, -w), Vec2(l, -w), Vec2(l, w), Vec2(-l, w)]
    }

    public func run(_ scene: SimScene) -> Result? {
        var rng = SeededRandom(seed: scene.seed &* 31 &+ 7)

        // Each corner is tapped from up close on a frozen full-size frame, as in the app.
        var rays: [Ray] = []
        for corner in corners(of: scene.table) {
            let camera = SweepPath.cornerCamera(for: scene, corner: corner, options: options, rng: &rng)
            guard let hit = camera.project(scene.pose.world(corner)) else { return nil }
            let tapped = PixelPoint(hit.pixel.x + rng.gaussian(cornerTapErrorPixels), hit.pixel.y + rng.gaussian(cornerTapErrorPixels))
            rays.append(camera.ray(through: tapped))
        }
        guard let solved = TableSolver.solve(rays: rays, lengthMm: scene.table.lengthMm, widthMm: scene.table.widthMm) else { return nil }

        var tracker = BallTracker(table: scene.table)
        let cameras = SweepPath.cameras(for: scene, options: options, rng: &rng)
        for (i, camera) in cameras.enumerated() {
            let image = renderer.render(scene, camera: camera, frameSeed: scene.seed &+ UInt64(i))
            tracker.add(detector.detect(image: image, camera: camera, pose: solved.pose, table: scene.table))
            let pose = solved.pose, radius = scene.table.ballRadiusMm
            tracker.noteFrame { spot in
                guard let hit = camera.project(pose.world(spot, z: radius)) else { return false }
                return hit.pixel.x > 20 && hit.pixel.y > 20
                    && hit.pixel.x < Double(camera.width) - 20 && hit.pixel.y < Double(camera.height) - 20
            }
        }
        let balls = tracker.finish()

        // Positions are compared in the table's own frame, so a small turn in the solved pose
        // counts as error, as it would on a real table.
        let truth = scene.balls.map(\.ball.position)
        let report = AccuracyReport.compare(
            measured: balls.map(\.position), truth: truth, matchWithinMm: scene.table.ballDiameterMm
        )

        var correct = 0, checked = 0
        for ball in balls {
            guard let nearest = scene.balls.min(by: {
                $0.ball.position.distance(to: ball.position) < $1.ball.position.distance(to: ball.position)
            }) else { continue }
            guard nearest.ball.position.distance(to: ball.position) < scene.table.ballDiameterMm else { continue }
            checked += 1
            if nearest.ball.kind == ball.kind { correct += 1 }
        }
        return Result(
            balls: balls, pose: solved.pose, tableResidualMm: solved.residualMm,
            report: report, kindsCorrect: correct, kindsChecked: checked
        )
    }
}
