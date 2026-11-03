import XCTest
import simd
import ShotEngine
@testable import TableVision
import SceneSim

final class GeometryTests: XCTestCase {
    func testProjectAndRayAgree() throws {
        let camera = CameraModel.look(from: SIMD3(1, 1.5, 2), at: SIMD3(0, 0.8, -1), fx: 700, width: 960, height: 720)
        let world = SIMD3<Double>(0.3, 0.85, -0.6)
        let hit = try XCTUnwrap(camera.project(world))
        let ray = camera.ray(through: hit.pixel)
        let t = simd_dot(world - ray.origin, ray.direction)
        XCTAssertLessThan(simd_distance(ray.origin + ray.direction * t, world), 1e-9)
    }

    func testPointBehindTheCameraDoesNotProject() {
        let camera = CameraModel.look(from: SIMD3(0, 1, 0), at: SIMD3(0, 1, -1), fx: 700, width: 960, height: 720)
        XCTAssertNil(camera.project(SIMD3(0, 1, 1)))
    }

    func testTablePoseRoundTrips() throws {
        let pose = TablePose(centre: SIMD3(0.4, 0.8, -3), xAxis: SIMD3(0.8, 0, 0.6))
        let p = Vec2(321, -123)
        let back = pose.table(pose.world(p, z: 28))
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        let ray = Ray(origin: pose.world(p, z: 900), direction: SIMD3(0, -1, 0))
        let hit = try XCTUnwrap(pose.intersect(ray, z: 28.5))
        XCTAssertEqual(hit.x, p.x, accuracy: 1e-9)
    }

    func testCameraModelSurvivesJSON() throws {
        let camera = CameraModel.look(from: SIMD3(1, 1.5, 2), at: SIMD3(0, 0.8, -1), fx: 700, width: 960, height: 720)
        let back = try JSONDecoder().decode(CameraModel.self, from: JSONEncoder().encode(camera))
        XCTAssertEqual(back.position, camera.position)
    }
}

final class TableSolverTests: XCTestCase {
    func rays(for pose: TablePose, table: TableProfile, order: [Vec2], jitter: Double = 0) -> [Ray] {
        var rng = SeededRandom(seed: 11)
        return order.enumerated().map { index, corner in
            let camera = CameraModel.look(
                from: pose.world(corner * 1.3, z: 600),
                at: pose.world(corner),
                fx: 1450, width: 1920, height: 1440
            )
            let hit = camera.project(pose.world(corner))!
            _ = index
            return camera.ray(through: PixelPoint(hit.pixel.x + rng.gaussian(jitter), hit.pixel.y + rng.gaussian(jitter)))
        }
    }

    func corners(_ t: TableProfile) -> [Vec2] {
        let l = t.lengthMm / 2, w = t.widthMm / 2
        return [Vec2(-l, -w), Vec2(l, -w), Vec2(l, w), Vec2(-l, w)]
    }

    func check(_ solved: TableSolution, _ pose: TablePose, _ table: TableProfile, within limit: Double) {
        // The table looks the same turned end for end, so test whichever way it came out.
        let probe = Vec2(table.lengthMm / 2, table.widthMm / 2)
        let direct = pose.table(solved.pose.world(probe))
        let flipped = Vec2(-direct.x, -direct.y)
        let error = min(direct.distance(to: probe), flipped.distance(to: probe))
        XCTAssertLessThan(error, limit)
        XCTAssertEqual(solved.pose.centre.y, pose.centre.y, accuracy: limit / 1000)
    }

    func testPerfectTapsGiveThePoseBack() throws {
        let pose = TablePose(centre: SIMD3(0.3, 0.8, -3), xAxis: SIMD3(0.9, 0, 0.43))
        let table = TableProfile.pool9
        let solved = try XCTUnwrap(TableSolver.solve(rays: rays(for: pose, table: table, order: corners(table)), lengthMm: table.lengthMm, widthMm: table.widthMm))
        check(solved, pose, table, within: 0.5)
        XCTAssertLessThan(solved.residualMm, 0.5)
    }

    func testAnyStartCornerAndDirectionWork() throws {
        let pose = TablePose(centre: SIMD3(0, 0.75, -2), xAxis: SIMD3(1, 0, 0))
        let table = TableProfile.pool8
        let c = corners(table)
        let orders = [[c[1], c[2], c[3], c[0]], [c[3], c[2], c[1], c[0]], [c[2], c[1], c[0], c[3]]]
        for order in orders {
            let solved = try XCTUnwrap(TableSolver.solve(rays: rays(for: pose, table: table, order: order), lengthMm: table.lengthMm, widthMm: table.widthMm))
            check(solved, pose, table, within: 0.5)
        }
    }

    func testTapErrorStaysSmallFromCloseUp() throws {
        let pose = TablePose(centre: SIMD3(0.3, 0.8, -3), xAxis: SIMD3(0.9, 0, 0.43))
        let table = TableProfile.pool9
        let solved = try XCTUnwrap(TableSolver.solve(rays: rays(for: pose, table: table, order: corners(table), jitter: 3), lengthMm: table.lengthMm, widthMm: table.widthMm))
        check(solved, pose, table, within: 8)
    }

    func testNeedsFourCorners() {
        XCTAssertNil(TableSolver.solve(rays: [], lengthMm: 2540, widthMm: 1270))
    }
}

final class ClassifierTests: XCTestCase {
    func evidence(_ white: Double, _ black: Double, _ coloured: Double, hue: Double = 0, s: Double = 0.8, v: Double = 0.7) -> ColourEvidence {
        var e = ColourEvidence()
        e.samples = 100
        e.white = white
        e.black = black
        e.coloured = coloured
        let a = hue * .pi / 180
        e.hueX = cos(a) * coloured
        e.hueY = sin(a) * coloured
        e.saturationSum = s * coloured
        e.valueSum = v * coloured
        return e
    }

    func testPoolKinds() {
        XCTAssertEqual(BallClassifier.kind(evidence(90, 0, 5), game: .pool), .cue)
        XCTAssertEqual(BallClassifier.kind(evidence(5, 80, 5), game: .pool), .eight)
        XCTAssertEqual(BallClassifier.kind(evidence(45, 0, 50), game: .pool), .stripe)
        XCTAssertEqual(BallClassifier.kind(evidence(8, 2, 85), game: .pool), .solid)
    }

    func testSnookerKinds() {
        XCTAssertEqual(BallClassifier.kind(evidence(80, 0, 10), game: .snooker), .cue)
        XCTAssertEqual(BallClassifier.kind(evidence(0, 80, 10), game: .snooker), .black)
        XCTAssertEqual(BallClassifier.kind(evidence(0, 0, 90, hue: 0, s: 0.85, v: 0.65), game: .snooker), .red)
        XCTAssertEqual(BallClassifier.kind(evidence(0, 0, 90, hue: 20, s: 0.75, v: 0.35), game: .snooker), .brown)
        XCTAssertEqual(BallClassifier.kind(evidence(0, 0, 90, hue: 350, s: 0.4, v: 0.9), game: .snooker), .pink)
        XCTAssertEqual(BallClassifier.kind(evidence(0, 0, 90, hue: 50), game: .snooker), .yellow)
        XCTAssertEqual(BallClassifier.kind(evidence(0, 0, 90, hue: 140), game: .snooker), .green)
        XCTAssertEqual(BallClassifier.kind(evidence(0, 0, 90, hue: 225), game: .snooker), .blue)
    }

    func testHueAveragesAcrossZero() {
        var e = ColourEvidence()
        e.add(HSV(r: 200, g: 20, b: 30))
        e.add(HSV(r: 200, g: 30, b: 20))
        XCTAssertTrue(e.hue < 10 || e.hue > 350)
    }

    func testNoEvidenceStaysUnknown() {
        XCTAssertEqual(BallClassifier.kind(ColourEvidence(), game: .pool), .unknownObject)
    }
}

final class TrackerTests: XCTestCase {
    private func sighting(_ x: Double, _ y: Double) -> Sighting {
        Sighting(position: Vec2(x, y), informationXX: 1, informationXY: 0, informationYY: 1, colour: ColourEvidence(), score: 1)
    }

    func testSomethingSeenInFewOfManyViewsIsDropped() {
        var tracker = BallTracker(table: .pool9)
        for frame in 0..<12 {
            var found = [sighting(0, 0)]
            // A flicker that shows up in 3 of 12 frames that could all see it.
            if frame % 4 == 0 { found.append(sighting(500, 200)) }
            tracker.add(found)
            tracker.noteFrame { _ in true }
        }
        let balls = tracker.finish()
        XCTAssertEqual(balls.count, 1)
        XCTAssertEqual(balls.first?.position.x ?? 99, 0, accuracy: 1)
    }
}

final class AccuracyReportTests: XCTestCase {
    func testMatchingAndNumbers() {
        let truth = [Vec2(0, 0), Vec2(100, 0), Vec2(200, 0), Vec2(300, 0)]
        let measured = [Vec2(1, 0), Vec2(103, 0), Vec2(200, 2), Vec2(800, 800)]
        let report = AccuracyReport.compare(measured: measured, truth: truth, matchWithinMm: 57)
        XCTAssertEqual(report.errorsMm.count, 3)
        XCTAssertEqual(report.falseBalls, 1)
        XCTAssertEqual(report.foundShare, 0.75)
        XCTAssertEqual(report.medianMm, 2)
        XCTAssertFalse(report.passes())
    }

    func testOneMeasuredBallCannotMatchTwice() {
        let report = AccuracyReport.compare(measured: [Vec2(0, 0)], truth: [Vec2(1, 0), Vec2(2, 0)], matchWithinMm: 57)
        XCTAssertEqual(report.errorsMm.count, 1)
    }

    func testPassMarks() {
        let report = AccuracyReport(errorsMm: [Double](repeating: 3, count: 100), trueBalls: 100, falseBalls: 0)
        XCTAssertTrue(report.passes())
        XCTAssertFalse(AccuracyReport(errorsMm: [6, 6, 6], trueBalls: 3, falseBalls: 0).passes())
        XCTAssertFalse(AccuracyReport(errorsMm: [Double](repeating: 3, count: 90), trueBalls: 100, falseBalls: 0).passes())
    }
}

/// End-to-end on small generated scenes. Bigger runs live in `cuesight-bench`.
final class GeneratedScanTests: XCTestCase {
    func runner() -> ScanRunner {
        var r = ScanRunner()
        r.options.frames = 8
        r.options.width = 800
        r.options.height = 600
        r.options.focal = 604
        return r
    }

    func testFindsAndPlacesBallsOnGreenCloth() throws {
        let scene = SceneGenerator.make(table: .pool9, ballCount: 8, seed: 3)
        let result = try XCTUnwrap(runner().run(scene))
        XCTAssertGreaterThanOrEqual(result.report.foundShare, 0.85)
        XCTAssertLessThan(result.report.medianMm, 8)
        XCTAssertLessThanOrEqual(result.report.falseBalls, 1)
    }

    func testPocketsAreNotCountedAsBalls() throws {
        let scene = SceneGenerator.make(table: .pool9, ballCount: 3, seed: 4)
        let result = try XCTUnwrap(runner().run(scene))
        XCTAssertEqual(result.report.falseBalls, 0)
    }

    func testFindsTheCueBall() throws {
        let scene = SceneGenerator.make(table: .pool9, ballCount: 8, seed: 5)
        let result = try XCTUnwrap(runner().run(scene))
        let cue = try XCTUnwrap(result.balls.first { $0.kind == .cue })
        XCTAssertLessThan(cue.position.distance(to: scene.balls[0].ball.position), 15)
    }

    func testWorksOnBlueCloth() throws {
        let scene = SceneGenerator.make(table: .pool9, ballCount: 8, seed: 6, cloth: .blueCloth)
        let result = try XCTUnwrap(runner().run(scene))
        XCTAssertGreaterThanOrEqual(result.report.foundShare, 0.75)
    }

    func testAnEmptyTableGivesNoBalls() throws {
        let scene = SceneGenerator.make(table: .pool9, ballCount: 0, seed: 9)
        let result = try XCTUnwrap(runner().run(scene))
        XCTAssertTrue(result.balls.isEmpty)
    }

    func testWrongTableSizeMakesTheViewsDisagree() throws {
        // A real 9 ft table, but the player picked 8 ft. The corner fit alone can't see this,
        // because a lower or higher table can look the right size from where the corners were tapped.
        let scene = SceneGenerator.make(table: .pool9, ballCount: 8, seed: 21)
        let right = disagreement(scene, tableUsed: .pool9)
        let wrong = disagreement(scene, tableUsed: .pool8)
        XCTAssertLessThan(right, 3)
        XCTAssertGreaterThan(wrong, right * 2)
    }

    private func disagreement(_ scene: SimScene, tableUsed: TableProfile) -> Double {
        var rng = SeededRandom(seed: 5)
        let r = runner()
        var rays: [Ray] = []
        for corner in r.corners(of: scene.table) {
            let camera = SweepPath.cornerCamera(for: scene, corner: corner, options: r.options, rng: &rng)
            rays.append(camera.ray(through: camera.project(scene.pose.world(corner))!.pixel))
        }
        let pose = TableSolver.solve(rays: rays, lengthMm: tableUsed.lengthMm, widthMm: tableUsed.widthMm)!.pose
        var tracker = BallTracker(table: tableUsed)
        for (i, camera) in SweepPath.cameras(for: scene, options: r.options, rng: &rng).enumerated() {
            let image = r.renderer.render(scene, camera: camera, frameSeed: UInt64(i))
            tracker.add(r.detector.detect(image: image, camera: camera, pose: pose, table: tableUsed))
        }
        return tracker.viewDisagreement
    }

    func testRendererIsRepeatable() {
        let scene = SceneGenerator.make(table: .pool7, ballCount: 4, seed: 2)
        let camera = SweepPath.overview(for: scene, width: 320, height: 240)
        let a = SceneRenderer().render(scene, camera: camera, frameSeed: 1)
        let b = SceneRenderer().render(scene, camera: camera, frameSeed: 1)
        XCTAssertEqual(a.pixels, b.pixels)
    }

    func testPlayerCanSeeTheOutlineWithTheOverviewCamera() {
        let scene = SceneGenerator.make(table: .pool9, ballCount: 4, seed: 2)
        let camera = SweepPath.overview(for: scene, width: 800, height: 600)
        let l = scene.table.lengthMm / 2, w = scene.table.widthMm / 2
        for corner in [Vec2(-l, -w), Vec2(l, -w), Vec2(l, w), Vec2(-l, w)] {
            let hit = camera.project(scene.pose.world(corner))
            XCTAssertNotNil(hit)
            XCTAssertTrue((0...800.0).contains(hit!.pixel.x))
            XCTAssertTrue((0...600.0).contains(hit!.pixel.y))
        }
    }
}
