import SwiftUI
import simd
import ShotEngine
import TableVision
import SceneSim
import SessionCore

/// A generated table that behaves like the camera. It also plays the chosen shot when the player
/// taps Next shot, so the loop can be tried end to end. Everything here is made up on purpose.
@MainActor
final class DemoFrameSource: FrameSource {
    let isDemo = true
    var trackingQuality: TrackingQuality = .good
    var onTrackingChange: ((TrackingQuality) -> Void)?
    private(set) var tablePose: TablePose?

    private(set) var scene: SimScene?
    private var sweep: [CameraModel] = []
    private var sweepIndex = 0
    private var stillIndex = 0
    private var overviewImage: UIImage?
    private var overviewCamera: CameraModel?
    /// A low view from behind the cue ball, standing in for the phone while lining up.
    private var aimCamera: CameraModel?
    private var aimImage: UIImage?
    /// Bumped whenever the view behind the lines changes, so the backdrop redraws.
    private(set) var viewNumber = 0
    private var viewCamera: CameraModel? { aimCamera ?? overviewCamera }
    private let renderer = SceneRenderer()
    private let width = 800, height = 600

    func start(table: TableProfile) {
        let count = table.game == .pool ? 10 : 16
        // Launch with `-demoCloth blue` or `-demoCloth red` to try the other cloth colours.
        let cloth: Colour = switch UserDefaults.standard.string(forKey: "demoCloth") {
        case "blue": .blueCloth
        case "red": .redCloth
        default: .greenCloth
        }
        scene = SceneGenerator.make(table: table, ballCount: count, seed: 42, cloth: cloth)
        prepare()
    }

    func stop() {}

    private func prepare() {
        guard let scene else { return }
        var options = SweepOptions()
        options.width = width
        options.height = height
        options.focal = 604
        options.frames = scene.table.game == .pool ? 12 : 18
        var rng = SeededRandom(seed: scene.seed &+ 3)
        sweep = SweepPath.cameras(for: scene, options: options, rng: &rng)
        sweepIndex = 0
        overviewCamera = SweepPath.overview(for: scene, width: width, height: height)
        overviewImage = nil
    }

    /// The first still is a view of the whole table. Asking again moves to each corner in turn.
    func stillFrame() async -> CameraFrame? {
        guard let scene else { return nil }
        let camera: CameraModel
        if stillIndex % 5 == 0, let overview = overviewCamera {
            // Double size, so corners can be placed about as finely as on a phone's camera image.
            camera = overview.scaled(by: 2)
        } else {
            let l = scene.table.lengthMm / 2, w = scene.table.widthMm / 2
            let corners = [Vec2(-l, -w), Vec2(l, -w), Vec2(l, w), Vec2(-l, w)]
            var rng = SeededRandom(seed: UInt64(stillIndex))
            var options = SweepOptions()
            options.trackingDriftMm = 0
            let full = SweepPath.cornerCamera(for: scene, corner: corners[(stillIndex % 5) - 1], options: options, rng: &rng)
            camera = full.scaled(by: Double(width * 2) / Double(full.width))
        }
        stillIndex += 1
        return await render(camera)
    }

    /// The whole-table view, used for review.
    func overviewFrame() async -> CameraFrame? {
        guard let camera = overviewCamera else { return nil }
        return await render(camera)
    }

    func scanFrame() async -> CameraFrame? {
        guard !sweep.isEmpty else { return nil }
        let camera = sweep[sweepIndex % sweep.count]
        sweepIndex += 1
        return await render(camera)
    }

    private func render(_ camera: CameraModel) async -> CameraFrame? {
        guard let scene else { return nil }
        let renderer = self.renderer
        let seed = UInt64(sweepIndex + stillIndex)
        let image = await Task.detached(priority: .userInitiated) {
            renderer.render(scene, camera: camera, frameSeed: seed)
        }.value
        return CameraFrame(image: image, camera: camera)
    }

    func anchorTable(_ pose: TablePose) {
        tablePose = pose
    }

    func backdrop() -> AnyView {
        AnyView(DemoBackdrop(source: self, viewNumber: viewNumber))
    }

    /// The picture behind the lines: the whole table, or the view from behind the cue ball.
    func view() async -> UIImage? {
        if let camera = aimCamera {
            if let aimImage { return aimImage }
            let number = viewNumber
            let image = await render(camera)?.uiImage
            // The player may have stepped again while this was drawing.
            if number == viewNumber { aimImage = image }
            return image
        }
        if let overviewImage { return overviewImage }
        guard let camera = overviewCamera else { return nil }
        overviewImage = await render(camera)?.uiImage
        return overviewImage
    }

    var viewTransform: simd_double4x4? { viewCamera?.transform }

    /// Puts the demo phone behind the cue ball, low down, as a player would hold it to line up.
    /// `sidewaysMm` moves it off the line to the right, so the guide has something to say.
    func lineUp(_ guide: AimGuide, sidewaysMm: Double) {
        guard let scene else { return }
        let right = Vec2(guide.aim.y, -guide.aim.x)
        let from = guide.cueBall - guide.aim * 480 + right * sidewaysMm
        let target = guide.cueBall + guide.aim * 700 + right * sidewaysMm
        aimCamera = .look(from: scene.pose.world(from, z: 220), at: scene.pose.world(target), fx: 604, width: width, height: height)
        aimImage = nil
        viewNumber += 1
    }

    func endLineUp() {
        guard aimCamera != nil else { return }
        aimCamera = nil
        aimImage = nil
        viewNumber += 1
    }

    func project(_ world: SIMD3<Double>, in size: CGSize) -> CGPoint? {
        guard let camera = viewCamera, let hit = camera.project(world) else { return nil }
        let fit = ImageFit(imageSize: CGSize(width: camera.width, height: camera.height), viewSize: size)
        return fit.toView(hit.pixel)
    }

    func ray(at point: CGPoint, in size: CGSize) -> Ray? {
        guard let camera = viewCamera else { return nil }
        let fit = ImageFit(imageSize: CGSize(width: camera.width, height: camera.height), viewSize: size)
        return camera.ray(through: fit.toPixel(point))
    }

    /// Plays the shot on the true table, so the next scan sees where the balls really went.
    func play(_ shot: ShotOption, measured: TableState) {
        guard var scene, let trueCue = scene.truthState.cueBall else { return }
        let truth = scene.truthState
        let target = measured.balls.first { $0.id == shot.targetBallId }
        guard let target, let trueTarget = truth.balls.min(by: {
            $0.position.distance(to: target.position) < $1.position.distance(to: target.position)
        }) else { return }
        _ = trueTarget
        var played = shot
        played.cueBallPath[0] = trueCue.position
        let outcome = ShotSimulator().play(played, on: truth)
        scene.balls = scene.balls.compactMap { ball in
            if let p = outcome.finalPositions[ball.ball.id] {
                var moved = ball
                moved.ball.position = scene.table.clamped(ballCentre: p)
                return moved
            }
            // A potted cue ball comes back out, as if placed by hand.
            if ball.ball.kind == .cue {
                var back = ball
                back.ball.position = Vec2(-scene.table.lengthMm / 4, 0)
                return back
            }
            return nil
        }
        self.scene = scene
        prepare()
    }
}

private struct DemoBackdrop: View {
    let source: DemoFrameSource
    let viewNumber: Int
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).accessibilityHidden(true)
            } else {
                ProgressView("Drawing the demo table")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .task(id: viewNumber) { image = await source.view() }
    }
}
