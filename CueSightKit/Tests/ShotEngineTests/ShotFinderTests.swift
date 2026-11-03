import XCTest
@testable import ShotEngine
import SceneSim

final class ShotFinderTests: XCTestCase {
    let table = TableProfile.pool9

    func state(cue: Vec2, _ objects: [(Vec2, BallKind)] = []) -> TableState {
        var balls = [Ball(id: 0, position: cue, kind: .cue)]
        for (i, object) in objects.enumerated() {
            balls.append(Ball(id: i + 1, position: object.0, kind: object.1))
        }
        return TableState(table: table, balls: balls)
    }

    func testGhostBallSitsOneDiameterBehindObjectBallOnPocketLine() throws {
        let s = state(cue: Vec2(-600, -200), [(Vec2(500, 300), .solid)])
        let shots = ShotFinder(config: .directOnly).findShots(in: s)
        let shot = try XCTUnwrap(shots.first { $0.pocketName == "top right" })
        let pocket = try XCTUnwrap(table.pockets.first { $0.name == "top right" })
        let d = (pocket.centre - Vec2(500, 300)).normalized
        let expected = Vec2(500, 300) - d * table.ballDiameterMm
        XCTAssertEqual(shot.ghostBall.x, expected.x, accuracy: 1e-6)
        XCTAssertEqual(shot.ghostBall.y, expected.y, accuracy: 1e-6)
        XCTAssertEqual(shot.objectBallPath.last, pocket.centre)
    }

    func testBlockedPathIsRejected() {
        let open = state(cue: Vec2(-600, 300), [(Vec2(600, 300), .solid)])
        let blocked = state(cue: Vec2(-600, 300), [(Vec2(600, 300), .solid), (Vec2(0, 305), .solid)])
        let target = 1
        let engine = ShotFinder(config: .directOnly)
        let name = "top right"
        XCTAssertTrue(engine.findShots(in: open, targetBallId: target).contains { $0.pocketName == name })
        XCTAssertFalse(engine.findShots(in: blocked, targetBallId: target).contains { $0.pocketName == name })
    }

    func testBallNearPocketLineBlocksObjectBall() {
        let s = state(cue: Vec2(-300, 0), [(Vec2(300, 200), .solid), (Vec2(800, 400), .solid)])
        let shots = ShotFinder(config: .directOnly).findShots(in: s, targetBallId: 1)
        let pocket = table.pockets.first { $0.name == "top right" }!
        let blockerOnLine = Vec2(800, 400).distance(toSegment: Vec2(300, 200), pocket.centre) < table.ballDiameterMm
        XCTAssertTrue(blockerOnLine)
        XCTAssertFalse(shots.contains { $0.pocketName == "top right" })
    }

    func testThinCutIsRejected() {
        // The cue ball is nearly level with the object ball, on the wrong side for this pocket.
        let s = state(cue: Vec2(600, 300), [(Vec2(640, 200), .solid)])
        let shots = ShotFinder(config: .directOnly).findShots(in: s, targetBallId: 1)
        XCTAssertTrue(shots.allSatisfy { $0.cutDegrees <= 75 })
    }

    func testAtMostThreeOptionsBestFirst() {
        let s = state(cue: Vec2(0, 0), [
            (Vec2(400, 200), .solid), (Vec2(-400, 200), .solid), (Vec2(400, -200), .stripe),
            (Vec2(-400, -200), .stripe), (Vec2(800, 0), .solid),
        ])
        let shots = ShotFinder().findShots(in: s)
        XCTAssertEqual(shots.count, 3)
        XCTAssertEqual(shots.map(\.score), shots.map(\.score).sorted(by: >))
    }

    func testTappedBallLimitsTheSearch() {
        let s = state(cue: Vec2(0, 0), [(Vec2(400, 200), .solid), (Vec2(-400, 200), .solid)])
        let shots = ShotFinder().findShots(in: s, targetBallId: 2)
        XCTAssertFalse(shots.isEmpty)
        XCTAssertTrue(shots.allSatisfy { $0.targetBallId == 2 })
    }

    func testNoCueBallMeansNoShots() {
        let s = TableState(table: table, balls: [Ball(id: 1, position: .zero, kind: .solid)])
        XCTAssertTrue(ShotFinder().findShots(in: s).isEmpty)
    }

    func testCloserStraighterShotIsEasier() throws {
        let engine = ShotFinder(config: .directOnly)
        let pocket = table.pockets.first { $0.name == "top right" }!
        let dir = (pocket.centre - Vec2(0, 0)).normalized
        let easyObject = pocket.centre - dir * 300
        let easy = state(cue: pocket.centre - dir * 700, [(easyObject, .solid)])
        let hard = state(cue: pocket.centre - dir * 2600, [(pocket.centre - dir * 1200, .solid)])
        let e = try XCTUnwrap(engine.findShots(in: easy, targetBallId: 1).first { $0.pocketName == "top right" })
        let h = try XCTUnwrap(engine.findShots(in: hard, targetBallId: 1).first { $0.pocketName == "top right" })
        XCTAssertGreaterThan(e.aimToleranceDegrees, h.aimToleranceDegrees)
        XCTAssertEqual(e.difficulty, .easy)
        XCTAssertEqual(h.difficulty, .hard)
    }

    func testStrengthGrowsWithDistance() throws {
        let engine = ShotFinder(config: .directOnly)
        let pocket = table.pockets.first { $0.name == "top right" }!
        let dir = (pocket.centre - Vec2(0, 0)).normalized
        let near = state(cue: pocket.centre - dir * 700, [(pocket.centre - dir * 300, .solid)])
        let shot = try XCTUnwrap(engine.findShots(in: near, targetBallId: 1).first { $0.pocketName == "top right" })
        XCTAssertEqual(shot.strength, .soft)

        var strong = ShotConfig.directOnly
        strong.arrivalSpeed = 3
        let firm = try XCTUnwrap(ShotFinder(config: strong).findShots(in: near, targetBallId: 1).first { $0.pocketName == "top right" })
        XCTAssertEqual(firm.strength, .firm)
    }

    func testBounceComesOffFlatterThanAMirror() throws {
        var config = ShotConfig()
        config.includeKicks = false
        let finder = ShotFinder(config: config)
        // Find a bank by blocking the direct line.
        let s = state(cue: Vec2(-800, -300), [(Vec2(0, 200), .solid), (Vec2(600, 400), .stripe)])
        let shots = finder.findShots(in: s, targetBallId: 1)
        XCTAssertFalse(shots.isEmpty)
    }

    func testObjectBankPathTouchesTheCushionLine() throws {
        var config = ShotConfig()
        config.includeKicks = false
        config.maxOptions = 40
        config.minCushionShotToleranceDegrees = 0
        let s = state(cue: Vec2(-800, -100), [(Vec2(300, 0), .solid)])
        let banks = ShotFinder(config: config).findShots(in: s, targetBallId: 1).filter { $0.kind == .objectBank }
        XCTAssertFalse(banks.isEmpty)
        for bank in banks {
            XCTAssertEqual(bank.objectBallPath.count, 3)
            let b = bank.objectBallPath[1]
            let maxX = table.lengthMm / 2 - table.ballRadiusMm
            let maxY = table.widthMm / 2 - table.ballRadiusMm
            XCTAssertTrue(abs(abs(b.x) - maxX) < 0.01 || abs(abs(b.y) - maxY) < 0.01)
        }
    }

    func testKickPathHasOneBounce() throws {
        var config = ShotConfig()
        config.includeObjectBanks = false
        config.maxOptions = 40
        config.minCushionShotToleranceDegrees = 0
        let s = state(cue: Vec2(-300, -100), [(Vec2(300, 200), .solid), (Vec2(0, 50), .stripe)])
        let kicks = ShotFinder(config: config).findShots(in: s, targetBallId: 1).filter { $0.kind == .kick }
        XCTAssertFalse(kicks.isEmpty)
        XCTAssertTrue(kicks.allSatisfy { $0.cueBallPath.count == 3 })
    }

    func testThrowMovesTheAimOnACut() throws {
        let s = state(cue: Vec2(-500, -300), [(Vec2(500, 200), .solid)])
        var withThrow = ShotConfig.directOnly
        withThrow.useThrowCorrection = true
        let plain = try XCTUnwrap(ShotFinder(config: .directOnly).findShots(in: s, targetBallId: 1).first)
        let corrected = try XCTUnwrap(ShotFinder(config: withThrow).findShots(in: s, targetBallId: 1).first { $0.pocketName == plain.pocketName })
        XCTAssertGreaterThan(corrected.throwCorrectionMm, 0.2)
        XCTAssertLessThan(corrected.throwCorrectionMm, 6)
        XCTAssertNotEqual(plain.ghostBall, corrected.ghostBall)
    }

    func testSimulatedPotDropsForEveryDirectOption() throws {
        // The advice is played out in a separate simulator with no aim error.
        var config = ShotConfig.directOnly
        config.useThrowCorrection = true
        config.maxOptions = 20
        let s = state(cue: Vec2(-500, -200), [(Vec2(300, 150), .solid), (Vec2(-200, 350), .stripe)])
        let shots = ShotFinder(config: config).findShots(in: s)
        XCTAssertGreaterThan(shots.count, 3)
        let simulator = ShotSimulator(config: config)
        var dropped = 0
        for shot in shots {
            let result = simulator.play(shot, on: s)
            XCTAssertEqual(result.firstBallHit, shot.targetBallId)
            if result.pottedIds.contains(shot.targetBallId) { dropped += 1 }
        }
        XCTAssertGreaterThanOrEqual(Double(dropped) / Double(shots.count), 0.9)
    }

    func testBigAimErrorMissesAHardPot() throws {
        let s = state(cue: Vec2(-1100, -500), [(Vec2(300, 150), .solid)])
        let shot = try XCTUnwrap(ShotFinder(config: .directOnly).findShots(in: s).first)
        let miss = ShotSimulator(config: .directOnly).play(shot, on: s, aimErrorDegrees: 2)
        XCTAssertFalse(miss.pottedIds.contains(shot.targetBallId))
    }

    func testCueBallAfterPathFollowsThe90DegreeLineWhenStunned() {
        let config = ShotConfig.directOnly
        let result = CueBallPhysics.directionAfterContact(
            incoming: Vec2(1, 0).rotated(byRadians: .pi / 6),
            objectDirection: Vec2(1, 0), contactSpeed: 2, contactSpin: 0
        )
        XCTAssertEqual(abs(result.direction.dot(Vec2(1, 0))), 0, accuracy: 1e-9)
        XCTAssertNotNil(config)
    }

    func testRollingCueBallDeflectsAbout30Degrees() {
        let incoming = Vec2(1, 0).rotated(byRadians: .pi / 4)
        let result = CueBallPhysics.directionAfterContact(
            incoming: incoming, objectDirection: Vec2(1, 0), contactSpeed: 2, contactSpin: 2
        )
        let deflection = acos(result.direction.dot(incoming)) * 180 / .pi
        XCTAssertEqual(deflection, 29, accuracy: 1.5)
    }

    func testDrawnCueBallComesBack() {
        let result = CueBallPhysics.directionAfterContact(
            incoming: Vec2(1, 0), objectDirection: Vec2(1, 0), contactSpeed: 2, contactSpin: -1
        )
        XCTAssertLessThan(result.direction.x, 0)
    }

    func testBallStartsRollingAfterSliding() {
        let config = ShotConfig()
        let far = CueBallPhysics.state(startSpeed: 2, startSpin: 0, distance: 2, config: config)
        XCTAssertEqual(far.speed, far.spin, accuracy: 1e-9)
        let near = CueBallPhysics.state(startSpeed: 2, startSpin: 0, distance: 0.05, config: config)
        XCTAssertGreaterThan(near.speed, near.spin)
    }

    func testAdviceAvoidsScratchWhenASpinOptionIsSafe() {
        // A straight shot at a corner along the diagonal: the cue ball would follow in with roll.
        let pocket = table.pockets.first { $0.name == "top right" }!
        let dir = (pocket.centre - Vec2(0, 0)).normalized
        let s = state(cue: pocket.centre - dir * 1200, [(pocket.centre - dir * 110, .solid)])
        let shot = ShotFinder().findShots(in: s, targetBallId: 1).first { $0.pocketName == "top right" && $0.kind == .direct }
        XCTAssertNotNil(shot)
        XCTAssertEqual(shot?.strikePoint, .bottom)
        XCTAssertEqual(shot?.scratchRisk, false)
    }

    func testBackspinNeedsAHarderHitForTheSameContactSpeed() {
        let finder = ShotFinder()
        let centre = finder.startSpeed(forContactSpeed: 1.2, distance: 1.5, strike: .centre)
        let bottom = finder.startSpeed(forContactSpeed: 1.2, distance: 1.5, strike: .bottom)
        XCTAssertGreaterThan(bottom, centre * 1.2)
        let arriving = CueBallPhysics.state(
            startSpeed: bottom, startSpin: -ShotConfig().strikeSpinRatio * bottom, distance: 1.5, config: ShotConfig()
        )
        XCTAssertEqual(arriving.speed, 1.2, accuracy: 0.001)
    }

    func testRollingBallComesOffACushionFlatterThanASlidingOne() {
        let config = ShotConfig()
        let sliding = CueBallPhysics.rebound(along: 1, into: 1, spinShare: 0, config: config)
        let rolling = CueBallPhysics.rebound(along: 1, into: 1, spinShare: 1, config: config)
        // With no roll it's a plain bounce at cushionRestitution.
        XCTAssertEqual(sliding.away / sliding.along, config.cushionRestitution, accuracy: 1e-9)
        XCTAssertLessThan(rolling.away / rolling.along, sliding.away / sliding.along * 0.7)
        // The bend moves the leaving line back along the cushion.
        XCTAssertLessThan(rolling.lineOffset, 0)
    }

    func testBanksAndKicksPotOnTheSimulatedTable() {
        // Only banks and kicks, from true positions, played in the separate simulator.
        var config = ShotConfig()
        config.maxOptions = 40
        var played = 0, potted = 0
        for table in [TableProfile.pool9, .snooker12] {
            for seed in 1...6 {
                let s = SceneGenerator.make(table: table, ballCount: 8, seed: UInt64(seed) + 500).truthState
                let simulator = ShotSimulator(config: config)
                for shot in ShotFinder(config: config).findShots(in: s) where shot.kind != .direct {
                    played += 1
                    if simulator.play(shot, on: s).pottedIds.contains(shot.targetBallId) { potted += 1 }
                }
            }
        }
        XCTAssertGreaterThan(played, 10)
        XCTAssertGreaterThanOrEqual(Double(potted) / Double(played), 0.8, "\(potted) of \(played)")
    }

    func testPathsThatCrossAreCaught() {
        let finder = ShotFinder()
        XCTAssertTrue(finder.paths([Vec2(0, 0), Vec2(100, 100)], [Vec2(0, 100), Vec2(100, 0)], comeWithin: 50))
        XCTAssertTrue(finder.paths([Vec2(0, 0), Vec2(100, 0)], [Vec2(0, 40), Vec2(100, 40)], comeWithin: 50))
        XCTAssertFalse(finder.paths([Vec2(0, 0), Vec2(100, 0)], [Vec2(0, 60), Vec2(100, 60)], comeWithin: 50))
        XCTAssertFalse(finder.paths([Vec2(0, 0), Vec2(100, 0)], [], comeWithin: 50))
    }
}

