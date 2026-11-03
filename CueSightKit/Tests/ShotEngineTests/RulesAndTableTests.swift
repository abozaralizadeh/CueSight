import XCTest
import ShotEngine

final class RulesAndTableTests: XCTestCase {
    func ball(_ id: Int, _ kind: BallKind) -> Ball {
        Ball(id: id, position: Vec2(Double(id) * 100, 0), kind: kind)
    }

    func testFreeRulesAllowEveryObjectBall() {
        let balls = [ball(0, .cue), ball(1, .eight), ball(2, .solid)]
        XCTAssertEqual(RulesContext.free.legalTargets(in: balls).map(\.id), [1, 2])
    }

    func testOpenTableLeavesOutTheEight() {
        let balls = [ball(0, .cue), ball(1, .eight), ball(2, .solid), ball(3, .stripe)]
        XCTAssertEqual(RulesContext.eightBall(.open).legalTargets(in: balls).map(\.id), [2, 3])
    }

    func testOwnGroupOnly() {
        let balls = [ball(0, .cue), ball(1, .eight), ball(2, .solid), ball(3, .stripe)]
        XCTAssertEqual(RulesContext.eightBall(.solids).legalTargets(in: balls).map(\.id), [2])
        XCTAssertEqual(RulesContext.eightBall(.stripes).legalTargets(in: balls).map(\.id), [3])
    }

    func testEightBecomesLegalWhenGroupIsCleared() {
        let balls = [ball(0, .cue), ball(1, .eight), ball(3, .stripe)]
        XCTAssertEqual(RulesContext.eightBall(.solids).legalTargets(in: balls).map(\.id), [1])
    }

    func testUnknownBallStaysLegalSoThePlayerDecides() {
        let balls = [ball(0, .cue), ball(1, .eight), ball(2, .unknownObject)]
        XCTAssertEqual(RulesContext.eightBall(.solids).legalTargets(in: balls).map(\.id), [2])
    }

    func testSnookerRedThenColour() {
        let balls = [ball(0, .cue), ball(1, .red), ball(2, .blue), ball(3, .black)]
        XCTAssertEqual(RulesContext.snooker(.red).legalTargets(in: balls).map(\.id), [1])
        XCTAssertEqual(RulesContext.snooker(.colour).legalTargets(in: balls).map(\.id), [2, 3])
    }

    func testSnookerColoursInOrderOnceRedsAreGone() {
        let balls = [ball(0, .cue), ball(1, .pink), ball(2, .blue), ball(3, .black)]
        XCTAssertEqual(RulesContext.snooker(.red).legalTargets(in: balls).map(\.id), [2])
    }

    func testAnyColourStraightAfterTheLastRed() {
        let balls = [ball(0, .cue), ball(1, .pink), ball(2, .blue)]
        XCTAssertEqual(RulesContext.snooker(.colour).legalTargets(in: balls).map(\.id), [1, 2])
    }

    func testPocketsSitWhereTheyShould() {
        let table = TableProfile.pool9
        XCTAssertEqual(table.pockets.count, 6)
        let side = table.pockets.first { $0.name == "top side" }!
        XCTAssertEqual(side.centre, Vec2(0, 635))
        XCTAssertEqual(side.mouthWidth, 133, accuracy: 1e-9)
        let corner = table.pockets.first { $0.name == "top right" }!
        XCTAssertEqual(corner.mouthWidth, 117, accuracy: 1e-6)
    }

    func testPocketOpeningShrinksAtAnAngle() {
        let side = TableProfile.pool9.pockets.first { $0.name == "top side" }!
        XCTAssertEqual(side.effectiveOpening(arrivingAlong: Vec2(0, 1)), 133, accuracy: 1e-9)
        XCTAssertEqual(side.effectiveOpening(arrivingAlong: Vec2(1, 1)), 133 * 0.7071, accuracy: 0.01)
        XCTAssertEqual(side.effectiveOpening(arrivingAlong: Vec2(0, -1)), 0)
    }

    func testCustomTableKeepsTheGameBallSize() {
        let table = TableProfile.custom(game: .snooker, lengthMm: 2000, widthMm: 1000)
        XCTAssertEqual(table.ballDiameterMm, 52.5)
        XCTAssertEqual(table.lengthMm, 2000)
    }

    func testBallsStayOnTheCloth() {
        let table = TableProfile.pool9
        let p = table.clamped(ballCentre: Vec2(5000, -5000))
        XCTAssertTrue(table.contains(ballCentre: p))
    }

    func testProfilesSurviveJSON() throws {
        let data = try JSONEncoder().encode(TableProfile.standard)
        XCTAssertEqual(try JSONDecoder().decode([TableProfile].self, from: data), TableProfile.standard)
    }

    func testRulesSurviveJSON() throws {
        let data = try JSONEncoder().encode(RulesContext.snooker(.colour))
        XCTAssertEqual(try JSONDecoder().decode(RulesContext.self, from: data), .snooker(.colour))
    }
}
