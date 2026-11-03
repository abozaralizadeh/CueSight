import SwiftUI
import simd
import ShotEngine
import TableVision
import SessionCore

#if targetEnvironment(simulator)

/// The Simulator has no camera or AR tracking, so it always uses the demo table.
enum LiveFrameSource {
    static var isSupported: Bool { false }
}

#else

import ARKit
import RealityKit

/// ARKit on a real iPhone. None of this can run in the Simulator, and none of it has been run on
/// a phone yet. It builds for a device, and that's all that's been checked.
@MainActor
final class LiveFrameSource: NSObject, FrameSource, ARSessionDelegate {
    static var isSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    let isDemo = false
    private(set) var trackingQuality: TrackingQuality = .lost
    var onTrackingChange: ((TrackingQuality) -> Void)?
    private(set) var tablePose: TablePose?

    let arView = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
    private var tableAnchor: ARAnchor?
    private var lastScanTimestamp: TimeInterval = 0
    /// Frames are halved before detection. That keeps a scan quick on older phones.
    var workingScale = 0.5
    var minSecondsBetweenScanFrames = 0.1

    func start(table: TableProfile) {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = []
        arView.session.delegate = self
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        tablePose = nil
        tableAnchor = nil
    }

    func stop() {
        arView.session.pause()
    }

    func stillFrame() async -> CameraFrame? {
        guard let frame = arView.session.currentFrame else { return nil }
        return await convert(frame)
    }

    func scanFrame() async -> CameraFrame? {
        guard let frame = arView.session.currentFrame,
              frame.timestamp - lastScanTimestamp >= minSecondsBetweenScanFrames,
              case .normal = frame.camera.trackingState
        else { return nil }
        lastScanTimestamp = frame.timestamp
        return await convert(frame)
    }

    private func convert(_ frame: ARFrame) async -> CameraFrame? {
        let buffer = frame.capturedImage
        let k = frame.camera.intrinsics
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let camera = CameraModel(
            fx: Double(k[0][0]), fy: Double(k[1][1]), cx: Double(k[2][0]), cy: Double(k[2][1]),
            width: width, height: height,
            transform: Self.double(frame.camera.transform)
        )
        let scale = workingScale
        let image = await Task.detached(priority: .userInitiated) {
            PixelBufferConverter.halfSizeRGB(buffer)
        }.value
        guard let image else { return nil }
        return CameraFrame(image: image, camera: camera.scaled(by: scale))
    }

    func anchorTable(_ pose: TablePose) {
        if let old = tableAnchor { arView.session.remove(anchor: old) }
        let m = pose.transform
        let anchor = ARAnchor(name: "table", transform: simd_float4x4(
            SIMD4(Float(m.columns.0.x), Float(m.columns.0.y), Float(m.columns.0.z), Float(m.columns.0.w)),
            SIMD4(Float(m.columns.1.x), Float(m.columns.1.y), Float(m.columns.1.z), Float(m.columns.1.w)),
            SIMD4(Float(m.columns.2.x), Float(m.columns.2.y), Float(m.columns.2.z), Float(m.columns.2.w)),
            SIMD4(Float(m.columns.3.x), Float(m.columns.3.y), Float(m.columns.3.z), Float(m.columns.3.w))
        ))
        arView.session.add(anchor: anchor)
        tableAnchor = anchor
        tablePose = pose
    }

    func backdrop() -> AnyView {
        AnyView(ARViewContainer(arView: arView).ignoresSafeArea())
    }

    func project(_ world: SIMD3<Double>, in size: CGSize) -> CGPoint? {
        arView.project(SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z)))
    }

    func ray(at point: CGPoint, in size: CGSize) -> Ray? {
        guard let r = arView.ray(through: point) else { return nil }
        return Ray(
            origin: SIMD3(Double(r.origin.x), Double(r.origin.y), Double(r.origin.z)),
            direction: SIMD3(Double(r.direction.x), Double(r.direction.y), Double(r.direction.z))
        )
    }

    var viewTransform: simd_double4x4? {
        arView.session.currentFrame.map { Self.double($0.camera.transform) }
    }

    private static func double(_ t: simd_float4x4) -> simd_double4x4 {
        simd_double4x4(
            SIMD4(Double(t.columns.0.x), Double(t.columns.0.y), Double(t.columns.0.z), Double(t.columns.0.w)),
            SIMD4(Double(t.columns.1.x), Double(t.columns.1.y), Double(t.columns.1.z), Double(t.columns.1.w)),
            SIMD4(Double(t.columns.2.x), Double(t.columns.2.y), Double(t.columns.2.z), Double(t.columns.2.w)),
            SIMD4(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z), Double(t.columns.3.w))
        )
    }

    nonisolated func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let quality: TrackingQuality
        switch camera.trackingState {
        case .normal: quality = .good
        case .limited: quality = .limited
        case .notAvailable: quality = .lost
        }
        Task { @MainActor in
            self.trackingQuality = quality
            self.onTrackingChange?(quality)
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        guard let anchor = anchors.first(where: { $0.name == "table" }) else { return }
        let t = anchor.transform
        let centre = SIMD3(Double(t.columns.3.x), Double(t.columns.3.y), Double(t.columns.3.z))
        // Keep the table level, whatever small tilt the anchor picks up.
        let axis = SIMD3(Double(t.columns.0.x), 0, Double(t.columns.0.z))
        Task { @MainActor in
            if simd_length(axis) > 0.1 {
                self.tablePose = TablePose(centre: centre, xAxis: axis)
            }
        }
    }
}

private struct ARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// ARKit gives full-range YCbCr. This turns it into RGB at half size, which lines the
/// brightness samples up with the colour samples one to one.
enum PixelBufferConverter {
    static func halfSizeRGB(_ buffer: CVPixelBuffer) -> RGBImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(buffer) >= 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let cBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { return nil }
        let width = CVPixelBufferGetWidth(buffer) / 2, height = CVPixelBufferGetHeight(buffer) / 2
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let cStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let yPlane = yBase.assumingMemoryBound(to: UInt8.self)
        let cPlane = cBase.assumingMemoryBound(to: UInt8.self)
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        pixels.withUnsafeMutableBufferPointer { out in
            for y in 0..<height {
                for x in 0..<width {
                    let luma = Double(yPlane[(y * 2) * yStride + x * 2])
                    let cb = Double(cPlane[y * cStride + x * 2]) - 128
                    let cr = Double(cPlane[y * cStride + x * 2 + 1]) - 128
                    let i = (y * width + x) * 3
                    out[i] = UInt8(max(0, min(255, luma + 1.402 * cr)))
                    out[i + 1] = UInt8(max(0, min(255, luma - 0.344 * cb - 0.714 * cr)))
                    out[i + 2] = UInt8(max(0, min(255, luma + 1.772 * cb)))
                }
            }
        }
        return RGBImage(width: width, height: height, pixels: pixels)
    }
}

#endif
