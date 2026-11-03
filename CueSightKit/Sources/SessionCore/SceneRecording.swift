import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import ShotEngine
import TableVision

/// A saved scan: frames plus camera poses, in a folder. Development builds record these on a real
/// phone, and `cuesight-bench replay` runs them again on a Mac, so a table visit gives data to keep.
public struct SceneRecording: Codable, Sendable {
    public struct Frame: Codable, Sendable {
        public var file: String
        public var camera: CameraModel
        public init(file: String, camera: CameraModel) {
            self.file = file
            self.camera = camera
        }
    }

    public var table: TableProfile
    public var pose: TablePose
    public var frames: [Frame]
    /// True positions, when they were measured.
    public var truth: [Vec2]?

    public init(table: TableProfile, pose: TablePose, frames: [Frame] = [], truth: [Vec2]? = nil) {
        self.table = table
        self.pose = pose
        self.frames = frames
        self.truth = truth
    }

    public static let manifestName = "recording.json"

    public static func load(from folder: URL) throws -> SceneRecording {
        let data = try Data(contentsOf: folder.appendingPathComponent(manifestName))
        return try JSONDecoder().decode(SceneRecording.self, from: data)
    }

    public func save(to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: folder.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    public mutating func append(frame: CameraFrame, in folder: URL) throws {
        let name = String(format: "frame-%05d.png", frames.count)
        try ImageFiles.writePNG(frame.image, to: folder.appendingPathComponent(name))
        frames.append(Frame(file: name, camera: frame.camera))
    }

    public func replay(folder: URL, detector: any BallDetecting = ClassicBallDetector()) throws -> [Ball] {
        var scan = ScanSession(table: table, pose: pose, detector: detector)
        for frame in frames {
            let image = try ImageFiles.readImage(folder.appendingPathComponent(frame.file))
            scan.add(CameraFrame(image: image, camera: frame.camera))
        }
        return scan.finish()
    }
}

public enum ImageFiles {
    public enum Failure: Error {
        case cantRead, cantWrite
    }

    public static func cgImage(_ image: RGBImage) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: image.width * image.height * 4)
        for i in 0..<(image.width * image.height) {
            rgba[i * 4] = image.pixels[i * 3]
            rgba[i * 4 + 1] = image.pixels[i * 3 + 1]
            rgba[i * 4 + 2] = image.pixels[i * 3 + 2]
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(
            width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    public static func writePNG(_ image: RGBImage, to url: URL) throws {
        guard
            let cg = cgImage(image),
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure.cantWrite }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.cantWrite }
    }

    public static func readImage(_ url: URL) throws -> RGBImage {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cg = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw Failure.cantRead }
        let width = cg.width, height = cg.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw Failure.cantRead }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
            rgb[i * 3] = rgba[i * 4]
            rgb[i * 3 + 1] = rgba[i * 4 + 1]
            rgb[i * 3 + 2] = rgba[i * 4 + 2]
        }
        return RGBImage(width: width, height: height, pixels: rgb)
    }
}
