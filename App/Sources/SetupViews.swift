import SwiftUI
import simd
import ShotEngine
import TableVision
import SessionCore

/// Shows a frozen camera frame and lets the player place points on it, with a magnifier.
struct FrozenFrameView<Overlay: View>: View {
    let image: UIImage
    let camera: CameraModel
    var onTap: (PixelPoint) -> Void
    @ViewBuilder var overlay: (ImageFit) -> Overlay
    @State private var touch: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            let fit = ImageFit(imageSize: CGSize(width: camera.width, height: camera.height), viewSize: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                overlay(fit)
                if let touch {
                    Magnifier(image: image, fit: fit, point: touch)
                        .position(x: touch.x < 160 ? geometry.size.width - 80 : 80, y: 80)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Camera picture of the table")
            .accessibilityHint("Tap each corner of the playing area in order. This step needs sight.")
            .onAppear { touch = nil }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { touch = $0.location }
                    .onEnded { value in
                        touch = nil
                        onTap(fit.toPixel(value.location))
                    }
            )
        }
    }
}

private struct Magnifier: View {
    let image: UIImage
    let fit: ImageFit
    let point: CGPoint
    let zoom: CGFloat = 4
    let size: CGFloat = 130

    var body: some View {
        let shown = CGSize(width: fit.imageSize.width * fit.scale * zoom, height: fit.imageSize.height * fit.scale * zoom)
        let local = CGPoint(x: (point.x - fit.origin.x) * zoom, y: (point.y - fit.origin.y) * zoom)
        ZStack {
            Image(uiImage: image)
                .resizable()
                .frame(width: shown.width, height: shown.height)
                .offset(x: shown.width / 2 - local.x, y: shown.height / 2 - local.y)
            Image(systemName: "plus").font(.title2.weight(.light)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(.white, lineWidth: 2))
        .accessibilityHidden(true)
    }
}

struct TableSetupView: View {
    @EnvironmentObject var model: AppModel

    private var cornerNames: [String] {
        ["first corner", "next corner along a side", "third corner", "last corner"]
    }

    var body: some View {
        ZStack {
            if let image = model.stillImage, let still = model.still {
                FrozenFrameView(image: image, camera: still.camera, onTap: { model.tapCorner(at: $0) }) { fit in
                    SetupOverlay(fit: fit, camera: still.camera)
                }
                .ignoresSafeArea()
            } else {
                ProgressView("Getting the camera ready")
            }
            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        if model.solution == nil {
                            Text("Corner \(model.corners.count + 1) of 4: tap the \(cornerNames[min(model.corners.count, 3)]).")
                                .font(.subheadline.bold())
                            Text("Go round in order. Drag to fine-tune. If a corner is out of view, walk closer and tap New view.")
                                .font(.caption)
                        } else {
                            Text("Does the outline match the cushions?").font(.subheadline.bold())
                            if model.setupLooksOff {
                                Text("The corners don't fit this table size well. Check the size and the taps.")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }
                    }
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .frame(maxWidth: 380, alignment: .leading)
                    Spacer()
                    Button("Change table") { model.changeTable() }.buttonStyle(PillButtonStyle())
                }
                Spacer()
                HStack(alignment: .bottom) {
                    Spacer()
                    Button("New view") { Task { await model.freeze() } }.buttonStyle(PillButtonStyle())
                    Button("Undo") { model.undoCorner() }.buttonStyle(PillButtonStyle()).disabled(model.corners.isEmpty)
                    if model.solution != nil {
                        Button("Start again") { model.restartSetup() }.buttonStyle(PillButtonStyle())
                        Button("Looks right") { model.confirmTable() }.buttonStyle(PillButtonStyle(prominent: true))
                    }
                }
            }
            .padding()
        }
    }
}

private struct SetupOverlay: View {
    @EnvironmentObject var model: AppModel
    let fit: ImageFit
    let camera: CameraModel

    var body: some View {
        let taps = model.corners.filter { $0.frameNumber == model.stillNumber }.map { fit.toView($0.pixel) }
        let outline = outlinePath()
        Canvas { context, _ in
            for p in taps {
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18)), with: .color(.yellow), lineWidth: 2)
            }
            if let outline {
                context.stroke(outline, with: .color(.black.opacity(0.6)), lineWidth: 5)
                context.stroke(outline, with: .color(.white), lineWidth: 2.5)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func outlinePath() -> Path? {
        guard let pose = model.solution?.pose else { return nil }
        let l = model.table.lengthMm / 2, w = model.table.widthMm / 2
        var path = Path()
        var started = false
        for point in [Vec2(-l, -w), Vec2(l, -w), Vec2(l, w), Vec2(-l, w), Vec2(-l, -w)] {
            guard let hit = camera.project(pose.world(point)) else { continue }
            let v = fit.toView(hit.pixel)
            if started { path.addLine(to: v) } else { path.move(to: v); started = true }
        }
        return path
    }
}

struct ScanView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            if model.isDemo {
                if let image = model.scanImage {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).ignoresSafeArea()
                        .accessibilityHidden(true)
                } else {
                    ProgressView("Starting the scan")
                }
            } else {
                model.source.backdrop().ignoresSafeArea()
            }
            VStack {
                HStack(alignment: .top) {
                    InfoPanel {
                        Text("Scan the balls").font(.headline)
                        Text("Walk slowly along the table, holding the phone at chest height. Then go round to the other side. Looking from both sides makes it much more accurate.")
                            .font(.subheadline)
                        if let scan = model.scan {
                            CoverageMap(scan: scan)
                            Text("\(Int(scan.coverage * 100))% of the table seen, \(scan.framesUsed) frame\(scan.framesUsed == 1 ? "" : "s")")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 360)
                    Spacer()
                    Button("Redo setup") { model.redoSetup() }.buttonStyle(PillButtonStyle())
                }
                Spacer()
                HStack {
                    Spacer()
                    Button("Finish scan") { Task { await model.finishScan() } }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .disabled(!model.canFinishScanEarly)
                }
            }
            .padding()
        }
    }
}

private struct CoverageMap: View {
    let scan: ScanSession

    var body: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach((0..<ScanSession.rows).reversed(), id: \.self) { row in
                GridRow {
                    ForEach(0..<ScanSession.columns, id: \.self) { column in
                        let index = row * ScanSession.columns + column
                        Rectangle()
                            .fill(scan.isCovered(index) ? Color.green : scan.cellViews[index] > 0 ? Color.yellow : Color.gray.opacity(0.4))
                            .frame(width: 22, height: 14)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Table coverage \(Int(scan.coverage * 100)) percent")
    }
}

struct TrackingLostView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            model.source.backdrop().ignoresSafeArea()
            InfoPanel {
                Text("Lost track of the table").font(.headline)
                Text("Point the phone back at the table and hold it steady. The lines are hidden until tracking is back, so they can't be in the wrong place.")
                HStack {
                    Spacer()
                    Button("Redo setup") { model.giveUpOnTracking() }.buttonStyle(PillButtonStyle(prominent: true))
                }
            }
            .frame(maxWidth: 420)
        }
    }
}
