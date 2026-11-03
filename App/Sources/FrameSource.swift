import SwiftUI
import simd
import ShotEngine
import TableVision
import SessionCore

/// Where camera frames come from. On a phone it's ARKit. In the Simulator, or with demo mode on,
/// it's a generated table, so the whole app can be tried without a real table.
@MainActor
protocol FrameSource: AnyObject {
    var isDemo: Bool { get }
    var trackingQuality: TrackingQuality { get }
    var onTrackingChange: ((TrackingQuality) -> Void)? { get set }
    /// Kept up to date by AR as it corrects itself, once the table is anchored.
    var tablePose: TablePose? { get }

    func start(table: TableProfile)
    func stop()
    /// A frame to freeze for tapping corners or reviewing balls.
    func stillFrame() async -> CameraFrame?
    /// The next frame for the scan. Nil when there isn't a fresh one yet.
    func scanFrame() async -> CameraFrame?
    func anchorTable(_ pose: TablePose)

    /// The live view behind the lines on the shots screen.
    func backdrop() -> AnyView
    /// World point to a point in the backdrop, for drawing lines over it.
    func project(_ world: SIMD3<Double>, in size: CGSize) -> CGPoint?
    /// A point in the backdrop to a ray in the world, for tapping a ball.
    func ray(at point: CGPoint, in size: CGSize) -> Ray?
    /// Camera to world for the view behind the lines right now. Used to cut lines where they pass
    /// behind the phone, and to tell the player how to line up.
    var viewTransform: simd_double4x4? { get }
}

/// How a camera image sits inside a view when scaled to fit.
struct ImageFit {
    var imageSize: CGSize
    var viewSize: CGSize

    var scale: CGFloat { min(viewSize.width / imageSize.width, viewSize.height / imageSize.height) }
    var origin: CGPoint {
        CGPoint(x: (viewSize.width - imageSize.width * scale) / 2, y: (viewSize.height - imageSize.height * scale) / 2)
    }

    func toView(_ p: PixelPoint) -> CGPoint {
        CGPoint(x: origin.x + CGFloat(p.x) * scale, y: origin.y + CGFloat(p.y) * scale)
    }

    func toPixel(_ p: CGPoint) -> PixelPoint {
        PixelPoint(Double((p.x - origin.x) / scale), Double((p.y - origin.y) / scale))
    }
}

extension CameraFrame {
    var uiImage: UIImage? {
        ImageFiles.cgImage(image).map { UIImage(cgImage: $0) }
    }
}
