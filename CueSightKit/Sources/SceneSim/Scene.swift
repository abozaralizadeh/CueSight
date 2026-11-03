import Foundation
import simd
import ShotEngine
import TableVision

public struct Colour: Codable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double
    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let white = Colour(235, 232, 222)
    public static let greenCloth = Colour(38, 128, 62)
    public static let blueCloth = Colour(30, 84, 150)
    public static let redCloth = Colour(136, 34, 40)
}

public enum Lighting: String, Codable, CaseIterable, Sendable {
    case club, dim, uneven
}

public struct SimBall: Sendable {
    public var ball: Ball
    public var colour: Colour
    public var striped: Bool
    /// Which way the ball happens to be turned.
    public var spinAxis: SIMD3<Double>

    public init(ball: Ball, colour: Colour, striped: Bool, spinAxis: SIMD3<Double>) {
        self.ball = ball
        self.colour = colour
        self.striped = striped
        self.spinAxis = spinAxis
    }
}

public struct SimScene: Sendable {
    public var table: TableProfile
    public var balls: [SimBall]
    public var pose: TablePose
    public var cloth: Colour
    public var lighting: Lighting
    public var seed: UInt64

    public var truthState: TableState {
        TableState(table: table, balls: balls.map(\.ball), scannedAt: Date(timeIntervalSince1970: 0))
    }
}

public enum SceneGenerator {
    static let poolColours: [Colour] = [
        Colour(226, 178, 30), Colour(24, 54, 150), Colour(190, 32, 30), Colour(84, 36, 130),
        Colour(226, 104, 22), Colour(14, 96, 56), Colour(116, 26, 34),
    ]
    static let snookerColours: [(BallKind, Colour)] = [
        (.yellow, Colour(226, 190, 36)), (.green, Colour(10, 92, 44)), (.brown, Colour(96, 52, 24)),
        (.blue, Colour(24, 60, 170)), (.pink, Colour(236, 138, 158)), (.black, Colour(16, 16, 18)),
    ]

    public static func make(
        table: TableProfile,
        ballCount: Int,
        seed: UInt64,
        lighting: Lighting = .club,
        cloth: Colour = .greenCloth,
        touchingPairs: Int = 0
    ) -> SimScene {
        var rng = SeededRandom(seed: seed)
        let yaw = rng.range(-0.6, 0.6)
        let pose = TablePose(
            centre: SIMD3(rng.range(-0.5, 0.5), 0.8, rng.range(-3.5, -2.5)),
            xAxis: SIMD3(cos(yaw), 0, sin(yaw))
        )

        var positions: [Vec2] = []
        var attempts = 0
        let d = table.ballDiameterMm
        while positions.count < ballCount, attempts < 5000 {
            attempts += 1
            var p: Vec2
            if touchingPairs > 0, positions.count % 2 == 1, positions.count / 2 < touchingPairs {
                let a = rng.range(0, 2 * .pi)
                p = positions[positions.count - 1] + Vec2(cos(a), sin(a)) * (d + 0.2)
            } else {
                let mx = table.lengthMm / 2 - d, my = table.widthMm / 2 - d
                p = Vec2(rng.range(-mx, mx), rng.range(-my, my))
            }
            p = table.clamped(ballCentre: p)
            let clearOfPockets = table.pockets.allSatisfy { p.distance(to: $0.centre) > $0.mouthWidth }
            let clearOfBalls = positions.allSatisfy { p.distance(to: $0) >= d }
            if clearOfPockets && clearOfBalls { positions.append(p) }
        }

        var balls: [SimBall] = []
        for (i, p) in positions.enumerated() {
            let axis = simd_normalize(SIMD3(rng.gaussian(), rng.gaussian(), rng.gaussian()))
            balls.append(appearance(index: i, position: p, game: table.game, axis: axis))
        }
        return SimScene(table: table, balls: balls, pose: pose, cloth: cloth, lighting: lighting, seed: seed)
    }

    private static func appearance(index i: Int, position p: Vec2, game: Game, axis: SIMD3<Double>) -> SimBall {
        if i == 0 {
            return SimBall(ball: Ball(id: 0, position: p, kind: .cue), colour: .white, striped: false, spinAxis: axis)
        }
        switch game {
        case .pool:
            if i == 8 {
                return SimBall(ball: Ball(id: i, position: p, kind: .eight), colour: Colour(16, 16, 18), striped: false, spinAxis: axis)
            }
            let striped = i > 8
            let colour = poolColours[(striped ? i - 9 : i - 1) % poolColours.count]
            return SimBall(ball: Ball(id: i, position: p, kind: striped ? .stripe : .solid), colour: colour, striped: striped, spinAxis: axis)
        case .snooker:
            if i <= snookerColours.count {
                let (kind, colour) = snookerColours[i - 1]
                return SimBall(ball: Ball(id: i, position: p, kind: kind), colour: colour, striped: false, spinAxis: axis)
            }
            return SimBall(ball: Ball(id: i, position: p, kind: .red), colour: Colour(176, 22, 26), striped: false, spinAxis: axis)
        }
    }
}

public struct SweepOptions: Sendable {
    public var frames = 14
    public var width = 960
    public var height = 720
    public var focal = 725.0
    /// Height of the phone above the cloth, in metres. Chest or head height at a normal table.
    public var heightAboveCloth = 0.75
    public var standOff = 0.5
    /// Also walk round to the opposite side, which helps a lot along the line of sight.
    public var bothSides = true
    public var handShakeDegrees = 0.15
    /// Simulated AR tracking drift of the camera position, in millimetres over the sweep.
    public var trackingDriftMm = 1.5

    public init() {}
}

public enum SweepPath {
    /// A walk along the table's long side, looking across it. Optionally back along the far side.
    public static func cameras(for scene: SimScene, options: SweepOptions, rng: inout SeededRandom) -> [CameraModel] {
        let table = scene.table
        let halfL = table.lengthMm / 2000, halfW = table.widthMm / 2000
        var cameras: [CameraModel] = []
        let sides: [Double] = options.bothSides ? [-1, 1] : [-1]
        let perSide = max(2, options.frames / sides.count)
        var drift = SIMD3<Double>(repeating: 0)
        let driftStep = options.trackingDriftMm / 1000 / Double(max(1, options.frames)).squareRoot()

        for side in sides {
            for i in 0..<perSide {
                let t = perSide > 1 ? Double(i) / Double(perSide - 1) : 0.5
                let x = (t * 2 - 1) * halfL * 0.75 * (side < 0 ? 1 : -1)
                let y = side * (halfW + options.standOff)
                let world = scene.pose.world(Vec2(x * 1000, y * 1000), z: options.heightAboveCloth * 1000)
                let lookX = x * 0.7 + rng.range(-0.1, 0.1)
                let lookY = -side * rng.range(-0.05, 0.15)
                let target = scene.pose.world(Vec2(lookX * 1000, lookY * 1000))
                drift += SIMD3(rng.gaussian(driftStep), rng.gaussian(driftStep), rng.gaussian(driftStep))
                let shake = options.handShakeDegrees * .pi / 180 * simd_length(world - target)
                let shaken = target + SIMD3(rng.gaussian(shake), rng.gaussian(shake), rng.gaussian(shake))
                cameras.append(.look(from: world + drift, at: shaken + drift, fx: options.focal, width: options.width, height: options.height))
            }
        }
        return cameras
    }

    /// A full-size camera a short way out from one corner, as when tapping it during setup.
    public static func cornerCamera(
        for scene: SimScene,
        corner: Vec2,
        options: SweepOptions,
        rng: inout SeededRandom
    ) -> CameraModel {
        let out = Vec2(corner.x.sign == .minus ? -1 : 1, corner.y.sign == .minus ? -1 : 1)
        let from = corner + Vec2(out.x * rng.range(150, 450), out.y * rng.range(450, 800))
        let world = scene.pose.world(from, z: rng.range(450, 750))
        let drift = options.trackingDriftMm / 1000
        let shifted = world + SIMD3(rng.gaussian(drift), rng.gaussian(drift), rng.gaussian(drift))
        return .look(from: shifted, at: scene.pose.world(corner), fx: 1450, width: 1920, height: 1440)
    }

    /// One wide view of the whole table, for demo screens.
    public static func overview(for scene: SimScene, width: Int, height: Int) -> CameraModel {
        let halfW = scene.table.widthMm / 2, halfL = scene.table.lengthMm / 2
        let focal = Double(width) * 0.75
        let corners = [Vec2(-halfL, -halfW), Vec2(halfL, -halfW), Vec2(halfL, halfW), Vec2(-halfL, halfW)]
        var distance = halfL
        while true {
            let from = scene.pose.world(Vec2(0, -(halfW + distance * 0.8)), z: distance)
            let camera = CameraModel.look(from: from, at: scene.pose.world(Vec2(0, halfW * 0.3)), fx: focal, width: width, height: height)
            let fits = corners.allSatisfy { corner in
                guard let hit = camera.project(scene.pose.world(corner)) else { return false }
                return hit.pixel.x > 24 && hit.pixel.y > 24
                    && hit.pixel.x < Double(width) - 24 && hit.pixel.y < Double(height) - 24
            }
            if fits || distance > halfL * 8 { return camera }
            distance *= 1.06
        }
    }
}
