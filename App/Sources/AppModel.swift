import SwiftUI
import AVFoundation
import simd
import ShotEngine
import TableVision
import SceneSim
import SessionCore

struct TappedCorner {
    var ray: Ray
    var pixel: PixelPoint
    var frameNumber: Int
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var flow: SessionFlow
    @Published var settings: AppSettings { didSet { try? store.save(settings: settings) } }
    @Published private(set) var tables: [TableProfile]
    @Published private(set) var table: TableProfile = .pool9
    @Published var rules: RulesContext = .free { didSet { refreshShots() } }

    // Table setup
    @Published private(set) var still: CameraFrame?
    @Published private(set) var stillImage: UIImage?
    @Published private(set) var stillNumber = 0
    @Published private(set) var corners: [TappedCorner] = []
    @Published private(set) var solution: TableSolution?

    // Scan
    @Published private(set) var scan: ScanSession?
    @Published private(set) var scanImage: UIImage?
    @Published private(set) var scanError: String?

    // Review and shots
    @Published var editor: ReviewEditor?
    @Published private(set) var shots: [ShotOption] = []
    @Published var selectedShot = 0 { didSet { placeDemoPhone() } }
    @Published var targetBallId: Int? { didSet { refreshShots() } }
    @Published private(set) var shotConfig = ShotConfig()

    // Line up
    @Published private(set) var lineUp = false
    /// Changes whenever the demo view behind the lines moves, so the shots screen redraws.
    @Published private(set) var viewNumber = 0
    /// In the demo there's no phone to move, so the player steps sideways by dragging.
    private var demoSidewaysMm = 0.0

    private(set) var source: FrameSource
    let store: TableStore
    let log: CappedLog
    private var scanTask: Task<Void, Never>?
    private var lastScanCSV = ""

    var isDemo: Bool { source.isDemo }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        store = TableStore(directory: support.appendingPathComponent("CueSight"))
        log = CappedLog(fileURL: support.appendingPathComponent("CueSight/logs/cuesight.log"))
        let saved = store.settings()
        settings = saved
        tables = store.allTables()
        flow = SessionFlow(firstRunDone: saved.firstRunDone)
        source = AppModel.makeSource(demo: saved.demoMode)
        table = tables.first { $0.id == saved.selectedTableId } ?? .pool9
        rules = AppModel.rules(for: table.game, saved.rules)
        source.onTrackingChange = { [weak self] in self?.trackingChanged($0) }
        log.write("app started, demo=\(source.isDemo)")
    }

    private static func makeSource(demo: Bool) -> FrameSource {
        #if targetEnvironment(simulator)
        return DemoFrameSource()
        #else
        return demo || !LiveFrameSource.isSupported ? DemoFrameSource() : LiveFrameSource()
        #endif
    }

    private static func rules(for game: Game, _ saved: AppSettings.SavedRules) -> RulesContext {
        switch (game, saved) {
        case (.snooker, .snooker): return .snooker(.red)
        case (.pool, .eightBall): return .eightBall(.open)
        default: return .free
        }
    }

    // MARK: First run and start

    func finishFirstRun() {
        settings.firstRunDone = true
        flow.send(.firstRunDone)
    }

    func setDemoMode(_ on: Bool) {
        settings.demoMode = on
        source.stop()
        source = AppModel.makeSource(demo: on)
        source.onTrackingChange = { [weak self] in self?.trackingChanged($0) }
        if flow.step != .start && flow.step != .firstRun { flow.send(.changeTable) }
    }

    func addCustomTable(game: Game, lengthMm: Double, widthMm: Double) {
        let custom = TableProfile.custom(game: game, lengthMm: lengthMm, widthMm: widthMm)
        try? store.save(custom: custom)
        tables = store.allTables()
    }

    func deleteCustomTable(_ table: TableProfile) {
        try? store.delete(customId: table.id)
        tables = store.allTables()
    }

    func choose(_ chosen: TableProfile) {
        table = chosen
        settings.selectedTableId = chosen.id
        if chosen.game == .snooker, case .snooker = rules {} else if chosen.game == .snooker {
            rules = .snooker(.red)
        } else if case .snooker = rules {
            rules = .free
        }
        source.start(table: chosen)
        corners = []
        solution = nil
        flow.send(.tableChosen)
        log.write("table chosen \(chosen.id)")
        Task { await freeze() }
    }

    func changeTable() {
        endLineUp()
        scanTask?.cancel()
        flow.send(.changeTable)
    }

    // MARK: Table setup

    func freeze() async {
        guard let frame = await source.stillFrame() else { return }
        still = frame
        stillImage = frame.uiImage
        stillNumber += 1
    }

    func tapCorner(at pixel: PixelPoint) {
        guard let still, corners.count < 4 else { return }
        corners.append(TappedCorner(ray: still.camera.ray(through: pixel), pixel: pixel, frameNumber: stillNumber))
        if corners.count == 4 { solve() }
    }

    func undoCorner() {
        guard !corners.isEmpty else { return }
        corners.removeLast()
        solution = nil
    }

    func restartSetup() {
        corners = []
        solution = nil
    }

    private func solve() {
        solution = TableSolver.solve(rays: corners.map(\.ray), lengthMm: table.lengthMm, widthMm: table.widthMm)
        if let solution {
            log.write(String(format: "table solved, corner fit %.1f mm", solution.residualMm))
        } else {
            log.write("table solve failed", level: "warn")
        }
    }

    /// The corner fit is checked by eye on the outline, but a big miss is worth flagging too.
    var setupLooksOff: Bool { (solution?.residualMm ?? 0) > 25 }

    func confirmTable() {
        guard let solution else { return }
        source.anchorTable(solution.pose)
        flow.send(.tableConfirmed)
        startScan()
    }

    func redoSetup() {
        endLineUp()
        scanTask?.cancel()
        restartSetup()
        flow.send(.redoSetup)
        Task { await freeze() }
    }

    var pose: TablePose? { source.tablePose ?? solution?.pose }

    // MARK: Scan

    func startScan() {
        guard let pose else { return }
        scanTask?.cancel()
        scan = ScanSession(table: table, pose: pose)
        scanError = nil
        scanTask = Task { [weak self] in await self?.runScan() }
    }

    private func runScan() async {
        while !Task.isCancelled, flow.step == .scan, var session = scan, !session.isComplete {
            guard let frame = await source.scanFrame() else {
                try? await Task.sleep(nanoseconds: 50_000_000)
                continue
            }
            if source.isDemo {
                scanImage = frame.uiImage
                // Roughly a walking pace, so the coverage map can be watched filling in.
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            session = await Task.detached(priority: .userInitiated) {
                var copy = session
                copy.add(frame)
                return copy
            }.value
            guard !Task.isCancelled, flow.step == .scan else { return }
            scan = session
        }
        if !Task.isCancelled, flow.step == .scan, scan?.isComplete == true {
            await finishScan()
        }
    }

    var canFinishScanEarly: Bool { (scan?.framesUsed ?? 0) >= 5 }

    func finishScan() async {
        scanTask?.cancel()
        guard let scan else { return }
        let balls = scan.finish()
        if scan.viewsDisagree {
            scanError = "The views don't line up. Check the table size, then redo setup."
        }
        lastScanCSV = PositionsCSV.format(balls)
        log.write(String(
            format: "scan done: %d balls, %d frames, coverage %.0f%%, view disagreement %.1f",
            balls.count, scan.framesUsed, scan.coverage * 100, scan.tracker.viewDisagreement
        ))
        for ball in balls {
            log.write(String(format: "ball %@ x=%.1f y=%.1f confidence=%.2f", ball.kind.rawValue, ball.position.x, ball.position.y, ball.confidence))
        }
        editor = ReviewEditor(table: table, balls: balls)
        targetBallId = nil
        if let demo = source as? DemoFrameSource, let frame = await demo.overviewFrame() {
            still = frame
            stillImage = frame.uiImage
            stillNumber += 1
        } else {
            await freeze()
        }
        flow.send(.scanFinished)
    }

    // MARK: Review

    func confirmReview() {
        guard let editor, editor.problems.isEmpty else { return }
        lastScanCSV = PositionsCSV.format(editor.balls)
        flow.send(.reviewConfirmed)
        selectedShot = 0
        refreshShots()
        log.write("review confirmed, \(editor.balls.filter(\.fixedByPlayer).count) balls fixed by hand")
    }

    func fixABall() {
        endLineUp()
        flow.send(.fixABall)
    }

    // MARK: Shots

    func setShotConfig(_ config: ShotConfig) {
        shotConfig = config
        refreshShots()
    }

    func refreshShots() {
        guard let editor else {
            shots = []
            return
        }
        shots = ShotFinder(config: shotConfig).findShots(in: editor.state, rules: rules, targetBallId: targetBallId)
        if selectedShot >= shots.count { selectedShot = 0 }
        if flow.step == .shots { log.write("shots found: \(shots.count)") }
        if lineUp {
            if currentShot == nil { endLineUp() } else { placeDemoPhone() }
        }
    }

    var currentShot: ShotOption? { shots.indices.contains(selectedShot) ? shots[selectedShot] : nil }

    func nextShot() {
        endLineUp()
        if let demo = source as? DemoFrameSource, let shot = currentShot, let editor {
            demo.play(shot, measured: editor.state)
        }
        targetBallId = nil
        flow.send(.nextShot)
        startScan()
    }

    /// From review: scan again without playing anything.
    func nextShotWithoutPlaying() {
        endLineUp()
        targetBallId = nil
        flow.send(.nextShot)
        startScan()
    }

    func record(potted: Bool) {
        guard let shot = currentShot else { return }
        let result = ShotResult(difficulty: shot.difficulty, kind: shot.kind, aimToleranceDegrees: shot.aimToleranceDegrees, potted: potted)
        log.write(result.logLine)
    }

    // MARK: Line up

    var aimGuide: AimGuide? { currentShot.flatMap { AimGuide(shot: $0, table: table) } }

    func startLineUp() {
        guard currentShot != nil else { return }
        lineUp = true
        // The demo phone starts a little to the right, so there's something to fix.
        demoSidewaysMm = 80
        placeDemoPhone()
        log.write("line up started")
    }

    func endLineUp() {
        guard lineUp else { return }
        lineUp = false
        if let demo = source as? DemoFrameSource {
            demo.endLineUp()
            viewNumber = demo.viewNumber
        }
        log.write("line up ended")
    }

    /// Demo only: step the pretend phone sideways. Positive is to the right, looking along the shot.
    func demoStep(sidewaysMm: Double) {
        demoSidewaysMm += sidewaysMm
        placeDemoPhone()
    }

    private func placeDemoPhone() {
        guard lineUp, let demo = source as? DemoFrameSource, let guide = aimGuide else { return }
        demo.lineUp(guide, sidewaysMm: demoSidewaysMm)
        viewNumber = demo.viewNumber
    }

    /// Where the phone is against the aim line, right now.
    func aimReading() -> AimGuide.Reading? {
        guard let guide = aimGuide, let pose, let m = source.viewTransform else { return nil }
        let position = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let forward = -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let viewer = pose.table(position)
        return guide.reading(viewer: viewer, facing: pose.table(position + forward) - viewer)
    }

    // MARK: Tracking

    private func trackingChanged(_ quality: TrackingQuality) {
        log.write("tracking \(quality.rawValue)")
        switch (quality, flow.step) {
        case (.limited, .scan), (.lost, .scan), (.limited, .shots), (.lost, .shots):
            scanTask?.cancel()
            flow.send(.trackingLimited)
        case (.good, .trackingLost(let resume)):
            flow.send(.trackingRecovered)
            if resume == .scan { startScan() }
        default:
            break
        }
    }

    func giveUpOnTracking() {
        flow.send(.trackingNotRecovered)
        restartSetup()
        Task { await freeze() }
    }

    // MARK: Exports

    func lastScanFile() -> URL? {
        guard !lastScanCSV.isEmpty else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cuesight-scan.csv")
        try? lastScanCSV.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func format(_ mm: Double) -> String {
        settings.useInches ? String(format: "%.1f in", mm / 25.4) : String(format: "%.0f mm", mm)
    }
}
