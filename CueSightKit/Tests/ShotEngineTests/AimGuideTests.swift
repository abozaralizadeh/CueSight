import XCTest
@testable import ShotEngine

final class AimGuideTests: XCTestCase {
    let table = TableProfile.pool9

    /// A straight shot along the long axis: cue ball at the left, object ball to its right.
    func guide(strike: StrikePoint = .centre) throws -> AimGuide {
        let balls = [Ball(id: 0, position: Vec2(-600, 0), kind: .cue), Ball(id: 1, position: Vec2(800, 300), kind: .solid)]
        let shots = ShotFinder(config: .directOnly).findShots(in: TableState(table: table, balls: balls))
        var shot = try XCTUnwrap(shots.first)
        shot.strikePoint = strike
        return try XCTUnwrap(AimGuide(shot: shot, table: table))
    }

    func testAimPointsAtTheGhostBall() throws {
        let g = try guide()
        let balls = [Ball(id: 0, position: Vec2(-600, 0), kind: .cue), Ball(id: 1, position: Vec2(800, 300), kind: .solid)]
        let shot = try XCTUnwrap(ShotFinder(config: .directOnly).findShots(in: TableState(table: table, balls: balls)).first)
        let expected = (shot.ghostBall - Vec2(-600, 0)).normalized
        XCTAssertEqual(g.aim.x, expected.x, accuracy: 1e-9)
        XCTAssertEqual(g.aim.y, expected.y, accuracy: 1e-9)
    }

    func testStandingOnTheLineAndFacingAlongItIsOnLine() throws {
        let g = try guide()
        let reading = g.reading(viewer: g.cueBall - g.aim * 500, facing: g.aim)
        XCTAssertEqual(reading.advice, .onLine)
        XCTAssertEqual(reading.behindMm, 500, accuracy: 1e-6)
        XCTAssertEqual(reading.sidewaysMm, 0, accuracy: 1e-6)
    }

    func testStandingToTheRightSaysMoveLeft() throws {
        let g = try guide()
        let right = Vec2(g.aim.y, -g.aim.x)
        let reading = g.reading(viewer: g.cueBall - g.aim * 500 + right * 80, facing: g.aim)
        guard case .moveLeft(let toLeft) = reading.advice else { return XCTFail("Expected move left, got \(reading.advice)") }
        XCTAssertEqual(toLeft, 80, accuracy: 1e-6)
        let left = g.reading(viewer: g.cueBall - g.aim * 500 - right * 60, facing: g.aim)
        guard case .moveRight(let mm) = left.advice else { return XCTFail("Expected move right, got \(left.advice)") }
        XCTAssertEqual(mm, 60, accuracy: 1e-6)
    }

    func testFacingOffTheLineSaysTurnBack() throws {
        let g = try guide()
        let turnedLeft = g.aim.rotated(byRadians: 8 * .pi / 180)
        let reading = g.reading(viewer: g.cueBall - g.aim * 500, facing: turnedLeft)
        guard case .turnRight(let degrees) = reading.advice else { return XCTFail("Expected turn right, got \(reading.advice)") }
        XCTAssertEqual(degrees, 8, accuracy: 1e-6)
        let turnedRight = g.aim.rotated(byRadians: -5 * .pi / 180)
        guard case .turnLeft = g.reading(viewer: g.cueBall - g.aim * 500, facing: turnedRight).advice else {
            return XCTFail("Expected turn left")
        }
    }

    func testInFrontOfTheBallOrFarToTheSideSaysWalkBehind() throws {
        let g = try guide()
        XCTAssertEqual(g.reading(viewer: g.cueBall + g.aim * 300, facing: -g.aim).advice, .walkBehind)
        let right = Vec2(g.aim.y, -g.aim.x)
        XCTAssertEqual(g.reading(viewer: g.cueBall - g.aim * 200 + right * 400, facing: g.aim).advice, .walkBehind)
    }

    func testCueLineRunsBackFromTheCueBall() throws {
        let g = try guide()
        let line = g.cueLine(lengthMm: 600)
        XCTAssertEqual(line.count, 2)
        XCTAssertGreaterThan(line[0].distance(to: g.cueBall), table.ballRadiusMm)
        XCTAssertEqual(line[1].distance(to: line[0]), 600, accuracy: 1e-6)
        XCTAssertLessThan((line[1] - g.cueBall).dot(g.aim), 0, "the cue line should be behind the ball")
    }

    func testStrikeMarkSitsOnTheBackOfTheBall() throws {
        for strike in StrikePoint.allCases {
            let g = try guide(strike: strike)
            let mark = g.strikeMark
            let centre = SIMD3(g.cueBall.x, g.cueBall.y, table.ballRadiusMm)
            let point = SIMD3(mark.point.x, mark.point.y, mark.heightMm)
            let distance = ((point - centre) * (point - centre)).sum().squareRoot()
            XCTAssertEqual(distance, table.ballRadiusMm, accuracy: 1e-6, "\(strike) mark should be on the ball's surface")
            XCTAssertLessThan((mark.point - g.cueBall).dot(g.aim), 0, "\(strike) mark should face the player")
        }
        XCTAssertGreaterThan(try guide(strike: .top).strikeMark.heightMm, try guide(strike: .centre).strikeMark.heightMm)
        XCTAssertLessThan(try guide(strike: .bottom).strikeMark.heightMm, try guide(strike: .centre).strikeMark.heightMm)
    }
}
