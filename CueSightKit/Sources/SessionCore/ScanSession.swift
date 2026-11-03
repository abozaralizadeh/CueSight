import Foundation
import ShotEngine
import TableVision

/// One frame from whatever is providing the camera: ARKit on a phone, or generated scenes in the demo.
public struct CameraFrame: Sendable {
    public var image: RGBImage
    public var camera: CameraModel

    public init(image: RGBImage, camera: CameraModel) {
        self.image = image
        self.camera = camera
    }
}

public enum TrackingQuality: String, Sendable {
    case good, limited, lost
}

/// Feeds frames through the detector and keeps count of which parts of the table have been seen.
public struct ScanSession: Sendable {
    public static let columns = 8
    public static let rows = 4

    public let table: TableProfile
    public let pose: TablePose
    public var detector: any BallDetecting
    /// Frames needed on a cell before it counts as seen.
    public var viewsPerCell = 2
    public var maxViewDistanceMetres = 4.5
    public var disagreementLimit = 4.0

    public private(set) var tracker: BallTracker
    public private(set) var cellViews: [Int]
    /// The directions each cell was seen from, as compass angles in radians.
    private var cellDirections: [[Double]]
    public private(set) var framesUsed = 0
    /// A cell only counts as seen once views of it are this far apart in direction. One side of
    /// the table alone leaves the distance along the line of sight poorly measured.
    public var minDirectionSpreadDegrees = 120.0

    public init(table: TableProfile, pose: TablePose, detector: any BallDetecting = ClassicBallDetector()) {
        self.table = table
        self.pose = pose
        self.detector = detector
        tracker = BallTracker(table: table)
        cellViews = [Int](repeating: 0, count: Self.columns * Self.rows)
        cellDirections = [[Double]](repeating: [], count: Self.columns * Self.rows)
    }

    public mutating func add(_ frame: CameraFrame) {
        tracker.add(detector.detect(image: frame.image, camera: frame.camera, pose: pose, table: table))
        let camera = frame.camera, pose = self.pose, radius = table.ballRadiusMm
        tracker.noteFrame { spot in
            guard let hit = camera.project(pose.world(spot, z: radius)) else { return false }
            let margin = 20.0
            return hit.pixel.x > margin && hit.pixel.y > margin
                && hit.pixel.x < Double(camera.width) - margin && hit.pixel.y < Double(camera.height) - margin
        }
        framesUsed += 1
        for row in 0..<Self.rows {
            for column in 0..<Self.columns where isVisible(column, row, frame.camera) {
                let index = row * Self.columns + column
                cellViews[index] += 1
                let seenFrom = pose.table(frame.camera.position) - cellCentre(column: column, row: row)
                cellDirections[index].append(atan2(seenFrom.y, seenFrom.x))
            }
        }
    }

    public func cellCentre(column: Int, row: Int) -> Vec2 {
        let cellW = table.lengthMm / Double(Self.columns), cellH = table.widthMm / Double(Self.rows)
        return Vec2(-table.lengthMm / 2 + cellW * (Double(column) + 0.5), -table.widthMm / 2 + cellH * (Double(row) + 0.5))
    }

    private func isVisible(_ column: Int, _ row: Int, _ camera: CameraModel) -> Bool {
        guard let hit = camera.project(pose.world(cellCentre(column: column, row: row))) else { return false }
        return hit.pixel.x >= 0 && hit.pixel.y >= 0
            && hit.pixel.x < Double(camera.width) && hit.pixel.y < Double(camera.height)
            && hit.depth <= maxViewDistanceMetres
    }

    public func isCovered(_ index: Int) -> Bool {
        guard cellViews[index] >= viewsPerCell else { return false }
        let directions = cellDirections[index]
        let limit = minDirectionSpreadDegrees * .pi / 180
        for a in directions {
            for b in directions {
                var gap = abs(a - b)
                if gap > .pi { gap = 2 * .pi - gap }
                if gap >= limit { return true }
            }
        }
        return false
    }

    public var coverage: Double {
        Double(cellViews.indices.filter(isCovered).count) / Double(cellViews.count)
    }

    public var isComplete: Bool { coverage >= 0.95 && framesUsed >= 5 }

    /// The first area that still needs a look, to point the player towards it.
    public var nextAreaToScan: Vec2? {
        for row in 0..<Self.rows {
            for column in 0..<Self.columns where !isCovered(row * Self.columns + column) {
                return cellCentre(column: column, row: row)
            }
        }
        return nil
    }

    public func finish() -> [Ball] { tracker.finish() }

    /// True when views of the same ball don't line up, which usually means the table size or
    /// the setup is wrong. The fix is to check the size and redo setup.
    public var viewsDisagree: Bool { tracker.viewDisagreement > disagreementLimit }
}
