import Foundation

/// The steps from docs/LOGICAL-FLOW.md.
public enum SessionStep: Equatable, Sendable {
    case firstRun
    case start
    case tableSetup
    case scan
    case review
    case shots
    case trackingLost(resumeAt: Resume)

    public enum Resume: Equatable, Sendable {
        case scan, shots
    }
}

public enum SessionEvent: Equatable, Sendable {
    case firstRunDone
    case tableChosen
    case tableConfirmed
    case scanFinished
    case reviewConfirmed
    case fixABall
    case nextShot
    case redoSetup
    case changeTable
    case trackingLimited
    /// Tracking came back and the table outline still lines up.
    case trackingRecovered
    /// Tracking came back or timed out, and the outline no longer lines up.
    case trackingNotRecovered
}

public struct SessionFlow: Equatable, Sendable {
    public private(set) var step: SessionStep

    public init(firstRunDone: Bool) {
        step = firstRunDone ? .start : .firstRun
    }

    /// Moves to the next step. An event that doesn't apply to the current step changes nothing.
    @discardableResult
    public mutating func send(_ event: SessionEvent) -> SessionStep {
        switch (step, event) {
        case (.firstRun, .firstRunDone): step = .start
        case (.start, .tableChosen): step = .tableSetup
        case (.tableSetup, .tableConfirmed): step = .scan
        case (.scan, .scanFinished): step = .review
        case (.review, .reviewConfirmed): step = .shots
        case (.shots, .fixABall): step = .review
        case (.shots, .nextShot), (.review, .nextShot): step = .scan
        case (.scan, .redoSetup), (.review, .redoSetup), (.shots, .redoSetup): step = .tableSetup
        case (.tableSetup, .changeTable), (.scan, .changeTable), (.review, .changeTable), (.shots, .changeTable):
            step = .start
        case (.scan, .trackingLimited): step = .trackingLost(resumeAt: .scan)
        case (.shots, .trackingLimited): step = .trackingLost(resumeAt: .shots)
        case (.trackingLost(let resume), .trackingRecovered):
            step = resume == .scan ? .scan : .shots
        case (.trackingLost, .trackingNotRecovered): step = .tableSetup
        default: break
        }
        return step
    }

    /// Lines must never show while tracking is bad. A wrong line looks just as confident as a right one.
    public var showsLines: Bool { step == .shots }
}
