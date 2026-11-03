import XCTest
import ShotEngine
import TableVision
import SceneSim
import SessionCore

final class SessionFlowTests: XCTestCase {
    func testHappyPathFollowsTheFlowDoc() {
        var flow = SessionFlow(firstRunDone: false)
        XCTAssertEqual(flow.step, .firstRun)
        XCTAssertEqual(flow.send(.firstRunDone), .start)
        XCTAssertEqual(flow.send(.tableChosen), .tableSetup)
        XCTAssertEqual(flow.send(.tableConfirmed), .scan)
        XCTAssertEqual(flow.send(.scanFinished), .review)
        XCTAssertEqual(flow.send(.reviewConfirmed), .shots)
        XCTAssertEqual(flow.send(.nextShot), .scan)
    }

    func testSkipsFirstRunWhenDone() {
        XCTAssertEqual(SessionFlow(firstRunDone: true).step, .start)
    }

    func testEventsThatDoNotApplyChangeNothing() {
        var flow = SessionFlow(firstRunDone: true)
        XCTAssertEqual(flow.send(.scanFinished), .start)
        XCTAssertEqual(flow.send(.reviewConfirmed), .start)
    }

    func testLinesHideWhenTrackingDrops() {
        var flow = reachShots()
        XCTAssertTrue(flow.showsLines)
        flow.send(.trackingLimited)
        XCTAssertEqual(flow.step, .trackingLost(resumeAt: .shots))
        XCTAssertFalse(flow.showsLines)
    }

    func testRecoveryReturnsToWhereYouWere() {
        var flow = reachShots()
        flow.send(.trackingLimited)
        XCTAssertEqual(flow.send(.trackingRecovered), .shots)

        flow.send(.nextShot)
        flow.send(.trackingLimited)
        XCTAssertEqual(flow.send(.trackingRecovered), .scan)
    }

    func testFailedRecoveryRedoesSetup() {
        var flow = reachShots()
        flow.send(.trackingLimited)
        XCTAssertEqual(flow.send(.trackingNotRecovered), .tableSetup)
    }

    func testFixABallGoesBackToReview() {
        var flow = reachShots()
        XCTAssertEqual(flow.send(.fixABall), .review)
    }

    func reachShots() -> SessionFlow {
        var flow = SessionFlow(firstRunDone: true)
        for event in [SessionEvent.tableChosen, .tableConfirmed, .scanFinished, .reviewConfirmed] {
            flow.send(event)
        }
        return flow
    }
}

final class CappedLogTests: XCTestCase {
    func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("logs/cuesight.log")
    }

    func testWritesLines() {
        let log = CappedLog(fileURL: tempURL())
        log.write("hello")
        log.write("boom", level: "error")
        let text = log.contents()
        XCTAssertTrue(text.contains("[info] hello"))
        XCTAssertTrue(text.contains("[error] boom"))
    }

    func testStaysUnderTheCapAndKeepsTheNewestLines() throws {
        let url = tempURL()
        let log = CappedLog(fileURL: url, maxBytes: 2000)
        for i in 0..<500 { log.write("line number \(i)") }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, 2000)
        let text = log.contents()
        XCTAssertTrue(text.contains("line number 499"))
        XCTAssertFalse(text.contains("line number 0\n"))
        XCTAssertTrue(text.hasSuffix("\n"))
    }

    func testClear() {
        let log = CappedLog(fileURL: tempURL())
        log.write("hello")
        log.clear()
        XCTAssertEqual(log.contents(), "")
    }
}

final class TableStoreTests: XCTestCase {
    func store() -> TableStore {
        TableStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    func testSavesAndDeletesCustomTables() throws {
        let s = store()
        XCTAssertEqual(s.allTables().count, TableProfile.standard.count)
        let custom = TableProfile.custom(game: .pool, lengthMm: 2100, widthMm: 1050)
        try s.save(custom: custom)
        try s.save(custom: custom)
        XCTAssertEqual(s.customTables(), [custom])
        try s.delete(customId: custom.id)
        XCTAssertTrue(s.customTables().isEmpty)
    }

    func testSettingsRoundTrip() throws {
        let s = store()
        XCTAssertFalse(s.settings().firstRunDone)
        var settings = AppSettings()
        settings.firstRunDone = true
        settings.useInches = true
        settings.rules = .eightBall
        try s.save(settings: settings)
        XCTAssertEqual(s.settings(), settings)
    }
}

final class ReviewEditorTests: XCTestCase {
    func editor() -> ReviewEditor {
        ReviewEditor(table: .pool9, balls: [
            Ball(id: 1, position: Vec2(0, 0), kind: .cue, confidence: 0.9),
            Ball(id: 2, position: Vec2(300, 0), kind: .solid, confidence: 0.3),
        ])
    }

    func testDragMarksTheBallAsFixed() {
        var e = editor()
        XCTAssertTrue(e.needsCheck(e.balls[1]))
        e.move(id: 2, to: Vec2(400, 100))
        XCTAssertEqual(e.balls[1].position, Vec2(400, 100))
        XCTAssertFalse(e.needsCheck(e.balls[1]))
    }

    func testDragStaysOnTheCloth() {
        var e = editor()
        e.move(id: 2, to: Vec2(9000, 0))
        XCTAssertTrue(e.table.contains(ballCentre: e.balls[1].position))
    }

    func testBallsCannotOverlap() {
        var e = editor()
        e.move(id: 2, to: Vec2(10, 0))
        XCTAssertEqual(e.balls[1].position, Vec2(300, 0))
        XCTAssertNil(e.add(at: Vec2(5, 5)))
    }

    func testAddAndRemove() {
        var e = editor()
        let added = e.add(at: Vec2(-300, 100), kind: .stripe)
        XCTAssertEqual(added?.id, 3)
        e.remove(id: 2)
        XCTAssertEqual(e.balls.map(\.id), [1, 3])
    }

    func testOnlyOneCueBall() {
        var e = editor()
        e.setCueBall(id: 2)
        XCTAssertEqual(e.balls.filter { $0.kind == .cue }.map(\.id), [2])
        XCTAssertEqual(e.balls[0].kind, .unknownObject)
    }

    func testProblems() {
        var e = editor()
        XCTAssertTrue(e.problems.isEmpty)
        e.remove(id: 1)
        XCTAssertFalse(e.problems.isEmpty)
    }
}

final class ScanSessionTests: XCTestCase {
    func testCoverageGrowsAndFinishes() throws {
        let scene = SceneGenerator.make(table: .pool7, ballCount: 4, seed: 12)
        var options = SweepOptions()
        options.frames = 10
        options.width = 640
        options.height = 480
        options.focal = 480
        var rng = SeededRandom(seed: 1)
        let renderer = SceneRenderer()
        var scan = ScanSession(table: scene.table, pose: scene.pose)
        XCTAssertEqual(scan.coverage, 0)
        XCTAssertNotNil(scan.nextAreaToScan)
        for (i, camera) in SweepPath.cameras(for: scene, options: options, rng: &rng).enumerated() {
            let image = renderer.render(scene, camera: camera, frameSeed: UInt64(i))
            scan.add(CameraFrame(image: image, camera: camera))
        }
        XCTAssertGreaterThan(scan.coverage, 0.9)
        let report = AccuracyReport.compare(
            measured: scan.finish().map(\.position), truth: scene.balls.map(\.ball.position),
            matchWithinMm: scene.table.ballDiameterMm
        )
        XCTAssertGreaterThanOrEqual(report.foundShare, 0.75)
    }
}

final class RecordingTests: XCTestCase {
    func testImagesRoundTripThroughPNG() throws {
        let scene = SceneGenerator.make(table: .pool7, ballCount: 2, seed: 2)
        let camera = SweepPath.overview(for: scene, width: 160, height: 120)
        let image = SceneRenderer().render(scene, camera: camera, frameSeed: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try ImageFiles.writePNG(image, to: url)
        let back = try ImageFiles.readImage(url)
        XCTAssertEqual(back.width, 160)
        XCTAssertEqual(back.pixels.count, image.pixels.count)
        let difference = zip(back.pixels, image.pixels).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(difference, 2)
    }

    func testRecordingManifestRoundTrips() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let scene = SceneGenerator.make(table: .pool7, ballCount: 2, seed: 2)
        let recording = SceneRecording(table: scene.table, pose: scene.pose, truth: scene.balls.map(\.ball.position))
        try recording.save(to: folder)
        let back = try SceneRecording.load(from: folder)
        XCTAssertEqual(back.table, scene.table)
        XCTAssertEqual(back.truth, recording.truth)
        XCTAssertEqual(back.pose, scene.pose)
    }
}

final class ShotLogTests: XCTestCase {
    func testResultRoundTripsThroughALogLine() {
        let result = ShotResult(difficulty: .medium, kind: .objectBank, aimToleranceDegrees: 0.123, potted: true)
        XCTAssertEqual(ShotResult(logLine: "2026-11-02T10:00:00Z [info] " + result.logLine), result)
        XCTAssertNil(ShotResult(logLine: "something else"))
    }

    func testPotRates() {
        let results = [
            ShotResult(difficulty: .easy, kind: .direct, aimToleranceDegrees: 1, potted: true),
            ShotResult(difficulty: .easy, kind: .direct, aimToleranceDegrees: 1, potted: false),
            ShotResult(difficulty: .hard, kind: .direct, aimToleranceDegrees: 0.01, potted: false),
        ]
        let rates = ShotLogSummary.potRates(results)
        XCTAssertEqual(rates[.easy]?.potted, 1)
        XCTAssertEqual(rates[.easy]?.total, 2)
        XCTAssertEqual(rates[.hard]?.potted, 0)
    }

    func testCSV() {
        let balls = [Ball(id: 1, position: Vec2(10.25, -3), kind: .cue)]
        let text = PositionsCSV.format(balls)
        XCTAssertTrue(text.hasPrefix("kind,x_mm,y_mm"))
        let parsed = PositionsCSV.parse(text)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].y, -3)
    }
}
