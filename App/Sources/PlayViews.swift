import SwiftUI
import simd
import ShotEngine
import TableVision
import SessionCore

extension BallKind {
    var displayColour: Color {
        switch self {
        case .cue: return .white
        case .unknownObject: return .gray
        case .solid: return .purple
        case .stripe: return .mint
        case .eight, .black: return .black
        case .red: return .red
        case .yellow: return .yellow
        case .green: return .green
        case .brown: return .brown
        case .blue: return .blue
        case .pink: return .pink
        }
    }

    var label: String {
        switch self {
        case .cue: return "Cue ball"
        case .unknownObject: return "Unknown"
        case .eight: return "8 ball"
        default: return rawValue.capitalized
        }
    }

    static func choices(for game: Game) -> [BallKind] {
        game == .pool ? [.cue, .solid, .stripe, .eight, .unknownObject]
            : [.cue, .red, .yellow, .green, .brown, .blue, .pink, .black, .unknownObject]
    }
}

extension TableProfile {
    /// Where a ball is, in words, for VoiceOver: the nearest pocket if it's close, else the area.
    func spokenSpot(_ p: Vec2) -> String {
        if let pocket = pockets.min(by: { $0.centre.distance(to: p) < $1.centre.distance(to: p) }),
           pocket.centre.distance(to: p) < widthMm * 0.2 {
            return "near the \(pocket.name) pocket"
        }
        let end = p.x < -lengthMm / 6 ? "left end" : p.x > lengthMm / 6 ? "right end" : "middle"
        return "\(end), \(p.y >= 0 ? "top" : "bottom") half"
    }
}

struct ReviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: Int?
    @State private var adding = false
    @State private var dragging: Int?

    var body: some View {
        ZStack {
            if let image = model.stillImage, let still = model.still, let pose = model.pose {
                GeometryReader { geometry in
                    let fit = ImageFit(imageSize: CGSize(width: still.camera.width, height: still.camera.height), viewSize: geometry.size)
                    ZStack {
                        Image(uiImage: image).resizable().aspectRatio(contentMode: .fit)
                            .accessibilityHidden(true)
                        ForEach(model.editor?.balls ?? []) { ball in
                            marker(ball, fit: fit, camera: still.camera, pose: pose)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in handleDrag(value, fit: fit, camera: still.camera, pose: pose) }
                            .onEnded { value in handleEnd(value, fit: fit, camera: still.camera, pose: pose) }
                    )
                }
                .ignoresSafeArea()
            }
            VStack {
                HStack(alignment: .top) {
                    InfoPanel {
                        Text("Check the balls").font(.headline)
                        Text("Drag a marker to fix it. Orange rings need a look. Tap a ball to change it or remove it.")
                            .font(.subheadline)
                        if let error = model.scanError {
                            Text(error).foregroundStyle(.orange).font(.subheadline)
                        }
                        ForEach(model.editor?.problems ?? [], id: \.self) { problem in
                            Text(problem).foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: 360)
                    Spacer()
                    if let id = selected, let ball = model.editor?.balls.first(where: { $0.id == id }) {
                        BallActions(ball: ball, game: model.table.game) { selected = nil }
                    }
                }
                Spacer()
                HStack {
                    Button("Scan again") { model.nextShotWithoutPlaying() }.buttonStyle(PillButtonStyle())
                    if model.scanError != nil {
                        Button("Redo setup") { model.redoSetup() }.buttonStyle(PillButtonStyle())
                    }
                    Button(adding ? "Tap where the ball is" : "Add a ball") { adding.toggle() }
                        .buttonStyle(PillButtonStyle(prominent: adding))
                    Spacer()
                    Button("Show shots") { model.confirmReview() }
                        .buttonStyle(PillButtonStyle(prominent: true))
                        .disabled(!(model.editor?.problems.isEmpty ?? false))
                }
            }
            .padding()
        }
    }

    private func marker(_ ball: Ball, fit: ImageFit, camera: CameraModel, pose: TablePose) -> some View {
        let r = model.table.ballRadiusMm
        let hit = camera.project(pose.world(ball.position, z: r))
        let edge = camera.project(pose.world(ball.position + Vec2(r, 0), z: r))
        let centre = hit.map { fit.toView($0.pixel) } ?? .zero
        let radius = max(10, (edge.map { fit.toView($0.pixel) }.map { hypot($0.x - centre.x, $0.y - centre.y) } ?? 10) + 4)
        let check = model.editor?.needsCheck(ball) ?? false
        return Circle()
            .stroke(check ? Color.orange : .white, style: StrokeStyle(lineWidth: selected == ball.id ? 4 : 2.5, dash: check ? [5, 3] : []))
            .frame(width: radius * 2, height: radius * 2)
            .position(centre)
            .opacity(hit == nil ? 0 : 1)
            .accessibilityLabel("\(ball.kind.label), \(model.table.spokenSpot(ball.position))\(check ? ", needs a check" : "")")
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Change its type or remove it")
            .accessibilityAction { selected = ball.id }
    }

    private func tablePoint(_ location: CGPoint, fit: ImageFit, camera: CameraModel, pose: TablePose) -> Vec2? {
        pose.intersect(camera.ray(through: fit.toPixel(location)), z: model.table.ballRadiusMm)
    }

    private func nearestBall(to point: Vec2) -> Ball? {
        model.editor?.balls
            .filter { $0.position.distance(to: point) < model.table.ballDiameterMm * 1.5 }
            .min { $0.position.distance(to: point) < $1.position.distance(to: point) }
    }

    private func handleDrag(_ value: DragGesture.Value, fit: ImageFit, camera: CameraModel, pose: TablePose) {
        guard !adding, let point = tablePoint(value.location, fit: fit, camera: camera, pose: pose) else { return }
        if dragging == nil, let start = tablePoint(value.startLocation, fit: fit, camera: camera, pose: pose),
           let ball = nearestBall(to: start), value.translation != .zero {
            dragging = ball.id
        }
        if let id = dragging { model.editor?.move(id: id, to: point) }
    }

    private func handleEnd(_ value: DragGesture.Value, fit: ImageFit, camera: CameraModel, pose: TablePose) {
        defer { dragging = nil }
        guard dragging == nil, let point = tablePoint(value.location, fit: fit, camera: camera, pose: pose) else { return }
        if adding {
            model.editor?.add(at: point)
            adding = false
        } else {
            selected = nearestBall(to: point)?.id
        }
    }
}

private struct BallActions: View {
    @EnvironmentObject var model: AppModel
    let ball: Ball
    let game: Game
    var done: () -> Void

    var body: some View {
        InfoPanel {
            Text(ball.kind.label).font(.headline)
            Menu("Change type") {
                ForEach(BallKind.choices(for: game), id: \.self) { kind in
                    Button(kind.label) { model.editor?.setKind(id: ball.id, kind: kind) }
                }
            }
            Button("Remove", role: .destructive) {
                model.editor?.remove(id: ball.id)
                done()
            }
            Button("Close") { done() }
        }
        .frame(width: 180)
    }
}

struct ShotsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var viewSize: CGSize = .zero

    var body: some View {
        ZStack {
            model.source.backdrop().ignoresSafeArea()
            GeometryReader { geometry in
                TimelineView(.animation(minimumInterval: model.isDemo ? 1 : 1.0 / 30)) { _ in
                    ShotOverlay(size: geometry.size)
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    if !model.lineUp { tapBall(at: location, size: geometry.size) }
                }
                .gesture(DragGesture(minimumDistance: 20).onEnded { value in
                    // Demo only: a sideways drag stands in for stepping sideways with the phone.
                    // Dragging right moves the view right, the way the picture would move.
                    if model.lineUp, model.isDemo { model.demoStep(sidewaysMm: -value.translation.width) }
                })
                .onAppear { viewSize = geometry.size }
                .onChange(of: geometry.size) { _, size in viewSize = size }
            }
            .ignoresSafeArea()
            if model.lineUp {
                LineUpControls()
            } else {
                shotControls
            }
        }
    }

    private var shotControls: some View {
            VStack {
                HStack(alignment: .top) {
                    if cardAtTop { ShotCard() }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 8) {
                        RulesPicker()
                        Button("Fix a ball") { model.fixABall() }.buttonStyle(PillButtonStyle())
                        Button("Change table") { model.changeTable() }.buttonStyle(PillButtonStyle())
                    }
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if model.shots.count > 1 {
                        Button("Option \(model.selectedShot + 1) of \(model.shots.count)") {
                            model.selectedShot = (model.selectedShot + 1) % model.shots.count
                        }
                        .buttonStyle(PillButtonStyle())
                        .accessibilityHint("Shows the next shot option")
                    }
                    if model.targetBallId != nil {
                        Button("All balls") { model.targetBallId = nil }.buttonStyle(PillButtonStyle())
                    }
                    if voiceOver { BallChooser() }
                    Spacer(minLength: 8)
                    if !cardAtTop { ShotCard() }
                    Spacer(minLength: 8)
                    if model.settings.testerMode, model.currentShot != nil {
                        Button("Went in") { model.record(potted: true) }.buttonStyle(PillButtonStyle())
                        Button("Missed") { model.record(potted: false) }.buttonStyle(PillButtonStyle())
                    }
                    if model.currentShot != nil {
                        Button("Line up") { model.startLineUp() }
                            .buttonStyle(PillButtonStyle())
                            .accessibilityHint("Walk behind the cue ball and follow the line on screen")
                    }
                    Button("Next shot") { model.nextShot() }.buttonStyle(PillButtonStyle(prominent: true))
                }
            }
            .padding()
    }

    /// The card goes in whichever half of the screen the shot isn't in, so it never hides the lines.
    private var cardAtTop: Bool {
        guard let shot = model.currentShot, let pose = model.pose, viewSize != .zero else { return true }
        let ys = (shot.cueBallPath + shot.objectBallPath).compactMap {
            model.source.project(pose.world($0, z: model.table.ballRadiusMm), in: viewSize)?.y
        }
        guard let top = ys.min() else { return true }
        // The card is about a third of the screen tall, so the top is free if the shot starts below that.
        return top > viewSize.height * 0.33
    }

    private func tapBall(at location: CGPoint, size: CGSize) {
        guard let ray = model.source.ray(at: location, in: size), let pose = model.pose,
              let point = pose.intersect(ray, z: model.table.ballRadiusMm),
              let ball = model.editor?.balls
                .filter({ $0.kind != .cue && $0.position.distance(to: point) < model.table.ballDiameterMm * 1.5 })
                .min(by: { $0.position.distance(to: point) < $1.position.distance(to: point) })
        else { return }
        model.targetBallId = ball.id
    }
}

private struct ShotOverlay: View {
    @EnvironmentObject var model: AppModel
    let size: CGSize

    private struct Line {
        var path: Path
        var colour: Color
        var dashed: Bool
    }

    var body: some View {
        // Paths are worked out here, on the main actor, and only drawn inside the canvas.
        let lines = makeLines()
        let ghost = ghostCircle()
        let strike = model.lineUp ? strikeDot() : nil
        let onLine = model.lineUp && model.aimReading()?.advice == .onLine
        Canvas { context, canvasSize in
            for line in lines {
                let dash: [CGFloat] = line.dashed ? [10, 8] : []
                context.stroke(line.path, with: .color(.black.opacity(0.7)), style: StrokeStyle(lineWidth: 7, lineCap: .round, dash: dash))
                context.stroke(line.path, with: .color(line.colour), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: dash))
            }
            if let ghost {
                // The ghost ball: where the cue ball must be at contact.
                let circle = Path(ellipseIn: ghost)
                context.fill(circle, with: .color(.white.opacity(0.3)))
                context.stroke(circle, with: .color(.white), lineWidth: 2)
            }
            if let strike {
                // Where to hit the cue ball, on the side facing the player.
                let dot = Path(ellipseIn: strike)
                context.fill(dot, with: .color(Color(red: 0.9, green: 0.1, blue: 0.1)))
                context.stroke(dot, with: .color(.white), lineWidth: 1.5)
            }
            if model.lineUp {
                // Marks at the middle of the top and bottom edges. On the line, the aim line runs
                // straight between them, and they turn green.
                let mark = onLine ? Color.green : Color.white.opacity(0.7)
                let x = canvasSize.width / 2
                for (y0, y1) in [(0.0, 28.0), (canvasSize.height - 28, canvasSize.height)] {
                    var tick = Path()
                    tick.move(to: CGPoint(x: x, y: y0))
                    tick.addLine(to: CGPoint(x: x, y: y1))
                    context.stroke(tick, with: .color(.black.opacity(0.7)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    context.stroke(tick, with: .color(mark), style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func makeLines() -> [Line] {
        guard model.flow.showsLines, let shot = model.currentShot, let pose = model.pose else { return [] }
        // Lining up, the lines run through the middle of the balls, the height you sight along.
        // From above it makes no difference, so they stay on the cloth there.
        let height = model.lineUp ? model.table.ballRadiusMm : 0
        let viewer = model.source.viewTransform
        func path(_ points: [Vec2]) -> Path {
            var p = Path()
            for (a, b) in zip(points, points.dropFirst()) {
                guard let (wa, wb) = clip(pose.world(a, z: height), pose.world(b, z: height), viewer),
                      let va = model.source.project(wa, in: size),
                      let vb = model.source.project(wb, in: size)
                else { continue }
                if p.currentPoint != va { p.move(to: va) }
                p.addLine(to: vb)
            }
            return p
        }
        // Fixed colours, not the system ones that change with light and dark mode. Each one is
        // drawn over a dark outline, so it stands out on green, blue and red cloth in bright or
        // dim light (contrast checked in docs/DESIGN.md).
        var lines: [Line] = []
        if model.lineUp, let guide = model.aimGuide {
            // Where the cue goes: straight back from the cue ball towards the player.
            lines.append(Line(path: path(guide.cueLine()), colour: .white.opacity(0.8), dashed: true))
        }
        return lines + [
            Line(path: path(shot.cueBallPath), colour: .white, dashed: false),
            Line(path: path(shot.objectBallPath), colour: Color(red: 1, green: 0.84, blue: 0.04), dashed: false),
            Line(path: path(shot.cueBallAfterPath), colour: Color(red: 0.39, green: 0.82, blue: 1), dashed: true),
        ]
    }

    /// Cuts a world segment to the part in front of the phone. Close up, the cue line runs back
    /// under the phone, and a point behind the camera would land somewhere wrong on screen.
    private func clip(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ viewer: simd_double4x4?) -> (SIMD3<Double>, SIMD3<Double>)? {
        guard let m = viewer else { return (a, b) }
        let position = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let forward = -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let near = 0.05
        let da = simd_dot(a - position, forward), db = simd_dot(b - position, forward)
        if da < near && db < near { return nil }
        if da < near { return (a + (b - a) * ((near - da) / (db - da)), b) }
        if db < near { return (a, a + (b - a) * ((da - near) / (da - db))) }
        return (a, b)
    }

    private func strikeDot() -> CGRect? {
        guard let guide = model.aimGuide, let pose = model.pose else { return nil }
        let mark = guide.strikeMark
        let r = model.table.ballRadiusMm
        guard let dot = model.source.project(pose.world(mark.point, z: mark.heightMm), in: size),
              let centre = model.source.project(pose.world(guide.cueBall, z: r), in: size),
              let edge = model.source.project(pose.world(guide.cueBall + Vec2(guide.aim.y, -guide.aim.x) * r, z: r), in: size)
        else { return nil }
        let radius = max(4, hypot(edge.x - centre.x, edge.y - centre.y) * 0.2)
        return CGRect(x: dot.x - radius, y: dot.y - radius, width: radius * 2, height: radius * 2)
    }

    private func ghostCircle() -> CGRect? {
        guard model.flow.showsLines, let shot = model.currentShot, let pose = model.pose else { return nil }
        let r = model.table.ballRadiusMm
        guard let centre = model.source.project(pose.world(shot.ghostBall, z: r), in: size),
              let edge = model.source.project(pose.world(shot.ghostBall + Vec2(r, 0), z: r), in: size)
        else { return nil }
        let radius = max(6, hypot(edge.x - centre.x, edge.y - centre.y))
        return CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
    }
}

/// The panel while lining up: what to do next, and how to hit it once you're there.
private struct LineUpControls: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: model.isDemo ? 1 : 0.2)) { _ in
            let reading = model.aimReading()
            VStack {
                HStack(alignment: .top) {
                    InfoPanel {
                        if let shot = model.currentShot, let target = model.editor?.balls.first(where: { $0.id == shot.targetBallId }) {
                            Text("Lining up: \(target.kind.label) into the \(shot.pocketName)").font(.footnote).foregroundStyle(.secondary)
                            Text(adviceTitle(reading?.advice)).font(.title3.bold())
                                .foregroundStyle(reading?.advice == .onLine ? .green : .primary)
                            Text(adviceDetail(reading?.advice, shot: shot)).font(.subheadline)
                        }
                    }
                    .frame(maxWidth: 400)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.updatesFrequently)
                    Spacer()
                }
                Spacer()
                HStack(alignment: .bottom) {
                    if model.isDemo {
                        Text("Demo: drag sideways to step left or right")
                            .font(.footnote)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(Color.black.opacity(0.65), in: Capsule())
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Button("Done") { model.endLineUp() }.buttonStyle(PillButtonStyle(prominent: true))
                }
            }
            .padding()
            .sensoryFeedback(.success, trigger: reading?.advice == .onLine) { _, now in now }
        }
    }

    private func adviceTitle(_ advice: AimGuide.Advice?) -> String {
        switch advice {
        case .none: return "Finding the phone"
        case .walkBehind: return "Go behind the white ball"
        case .moveLeft(let mm): return "Step left \(distance(mm))"
        case .moveRight(let mm): return "Step right \(distance(mm))"
        case .turnLeft: return "Turn the phone a little left"
        case .turnRight: return "Turn the phone a little right"
        case .onLine: return "You're on the line"
        }
    }

    private func adviceDetail(_ advice: AimGuide.Advice?, shot: ShotOption) -> String {
        switch advice {
        case .none: return "Hold the phone steady for a moment."
        case .walkBehind: return "Stand where you'd play from, hold the phone low over the cue line and point it along the shot."
        case .moveLeft, .moveRight, .turnLeft, .turnRight:
            return "The dashed white line is where your cue goes."
        case .onLine:
            return "Cue along the dashed line and hit the red dot, \(shot.strength.rawValue)."
        }
    }

    /// Rounded to the nearest centimetre or half inch. Finer than that is noise for a phone in hand.
    private func distance(_ mm: Double) -> String {
        model.format(model.settings.useInches ? (mm / 12.7).rounded() * 12.7 : (mm / 10).rounded() * 10)
    }
}

private struct ShotCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        InfoPanel {
            if let shot = model.currentShot, let target = model.editor?.balls.first(where: { $0.id == shot.targetBallId }) {
                HStack {
                    Text("\(target.kind.label) into the \(shot.pocketName)").font(.headline)
                    if model.table.game == .snooker {
                        Text("Rough guide").font(.caption.bold()).padding(4).background(.orange, in: Capsule())
                    }
                }
                Text("Hit it \(shot.strength.rawValue), \(strikeText(shot.strikePoint)). \(kindText(shot))")
                    .font(.subheadline)
                Text("\(shot.difficulty.rawValue.capitalized) shot, \(Int(shot.cutDegrees.rounded())) degree cut. Aim at the white circle.")
                    .font(.footnote).foregroundStyle(.secondary)
                if shot.scratchRisk {
                    Text("The cue ball may follow it in.").font(.footnote).foregroundStyle(.orange)
                }
            } else {
                Text("No clear pot").font(.headline)
                Text(model.targetBallId == nil
                    ? "There's no direct or one-cushion pot for a legal ball from here."
                    : "No pot found for that ball. Tap All balls to see others.")
                    .font(.subheadline)
            }
        }
        .frame(maxWidth: 420)
        .accessibilityElement(children: .combine)
    }

    private func kindText(_ shot: ShotOption) -> String {
        switch shot.kind {
        case .direct: return "Direct, no cushions."
        case .objectBank: return "Off one cushion into the pocket."
        case .kick: return "Cue ball off one cushion first."
        }
    }

    private func strikeText(_ strike: StrikePoint) -> String {
        switch strike {
        case .centre: return "middle of the cue ball"
        case .top: return "above the middle for follow"
        case .bottom: return "below the middle for draw"
        }
    }
}

private struct RulesPicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            if model.table.game == .pool {
                Button("No rules") { model.rules = .free }
                Button("8-ball, open table") { model.rules = .eightBall(.open) }
                Button("8-ball, I'm on solids") { model.rules = .eightBall(.solids) }
                Button("8-ball, I'm on stripes") { model.rules = .eightBall(.stripes) }
            } else {
                Button("On a red") { model.rules = .snooker(.red) }
                Button("On a colour") { model.rules = .snooker(.colour) }
            }
        } label: {
            Text(rulesLabel).font(.headline)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.black.opacity(0.65), in: Capsule())
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Rules: \(rulesLabel)")
    }

    private var rulesLabel: String {
        switch model.rules {
        case .free: return "No rules"
        case .eightBall(.open): return "8-ball: open"
        case .eightBall(.solids): return "8-ball: solids"
        case .eightBall(.stripes): return "8-ball: stripes"
        case .snooker(.red): return "On a red"
        case .snooker(.colour): return "On a colour"
        }
    }
}

/// With VoiceOver on, balls can't be tapped on the picture, so they're listed here instead.
private struct BallChooser: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.editor?.balls.filter { $0.kind != .cue } ?? []) { ball in
                Button("\(ball.kind.label), \(model.table.spokenSpot(ball.position))") { model.targetBallId = ball.id }
            }
        } label: {
            Text("Choose a ball").font(.headline)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.black.opacity(0.65), in: Capsule())
                .foregroundStyle(.white)
        }
    }
}
