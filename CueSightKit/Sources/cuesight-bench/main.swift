import Foundation
import ShotEngine
import TableVision
import SceneSim
import SessionCore

// Command line checks for the measuring pipeline.
//
//   cuesight-bench accuracy [--table pool9] [--scenes 10] [--lighting club] [--balls 12] [--one-side]
//   cuesight-bench advice   [--table pool9] [--scenes 10]
//   cuesight-bench compare  measured.csv truth.csv [--table pool9]
//   cuesight-bench replay   recording-folder
//   cuesight-bench record   output-folder [--table pool9]
//   cuesight-bench shots    log-file
//
// `accuracy` and `advice` use generated scenes, so they say nothing about a real table.

let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String, default fallback: String) -> String {
    guard let i = arguments.firstIndex(of: "--\(name)"), i + 1 < arguments.count else { return fallback }
    return arguments[i + 1]
}

func flag(_ name: String) -> Bool { arguments.contains("--\(name)") }

func tableNamed(_ name: String) -> TableProfile {
    guard let table = TableProfile.standard.first(where: { $0.id == name }) else {
        fail("Unknown table \(name). Use one of: \(TableProfile.standard.map(\.id).joined(separator: ", "))")
    }
    return table
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func accuracy() {
    let table = tableNamed(option("table", default: "pool9"))
    let lighting = Lighting(rawValue: option("lighting", default: "club")) ?? .club
    let scenes = Int(option("scenes", default: "10")) ?? 10
    let balls = Int(option("balls", default: table.game == .pool ? "16" : "22")) ?? 16
    let clothName = option("cloth", default: "green")
    let cloth: Colour = clothName == "blue" ? .blueCloth : clothName == "red" ? .redCloth : .greenCloth

    var runner = ScanRunner()
    runner.options.bothSides = !flag("one-side")
    if table.game == .snooker { runner.options.frames = 20 }

    var reports: [AccuracyReport] = []
    var correct = 0, checked = 0
    for seed in 1...scenes {
        let scene = SceneGenerator.make(
            table: table, ballCount: balls, seed: UInt64(seed), lighting: lighting, cloth: cloth,
            touchingPairs: seed % 2 == 0 ? 2 : 0
        )
        guard let result = runner.run(scene) else {
            print("scene \(seed): table setup failed")
            continue
        }
        reports.append(result.report)
        correct += result.kindsCorrect
        checked += result.kindsChecked
    }
    let total = AccuracyReport.merged(reports)
    print("GENERATED SCENES ONLY, NOT A REAL TABLE")
    print("\(table.name), \(lighting.rawValue) light, \(clothName) cloth, \(scenes) scenes, \(flag("one-side") ? "one side" : "both sides")")
    print(total.summary)
    print("ball types right: \(correct) of \(checked)")
    print("pass marks on generated scenes: \(total.passes() ? "met" : "NOT met")")
}

func advice() {
    let table = tableNamed(option("table", default: "pool9"))
    let scenes = Int(option("scenes", default: "10")) ?? 10
    let balls = Int(option("balls", default: "8")) ?? 8
    var runner = ScanRunner()
    if table.game == .snooker { runner.options.frames = 20 }
    var total = AdviceCheck.Result()
    let check = AdviceCheck()
    for seed in 1...scenes {
        let scene = SceneGenerator.make(table: table, ballCount: balls, seed: UInt64(seed) + 500)
        guard let result = runner.run(scene) else { continue }
        total.merge(check.run(truth: scene.truthState, measured: result.balls))
    }
    print("GENERATED SCENES AND A SIMULATED TABLE, WITH A PERFECT STROKE, NOT REAL PLAY")
    print("\(table.name), \(total.played) advised shots")
    print("potted using measured positions: \(String(format: "%.1f", total.rate * 100))%")
    print("potted using true positions:     \(String(format: "%.1f", total.perfectRate * 100))%")
}

func compare(_ measuredPath: String, _ truthPath: String) {
    let table = tableNamed(option("table", default: "pool9"))
    guard
        let measured = try? String(contentsOfFile: measuredPath, encoding: .utf8),
        let truth = try? String(contentsOfFile: truthPath, encoding: .utf8)
    else { fail("Couldn't read the CSV files.") }
    let report = AccuracyReport.compare(
        measured: PositionsCSV.parse(measured), truth: PositionsCSV.parse(truth),
        matchWithinMm: table.ballDiameterMm
    )
    print(report.summary)
    print("Phase 0 pass marks: \(report.passes() ? "met" : "NOT met")")
}

func replay(_ path: String) {
    let folder = URL(fileURLWithPath: path)
    do {
        let recording = try SceneRecording.load(from: folder)
        let balls = try recording.replay(folder: folder)
        print(PositionsCSV.format(balls), terminator: "")
        if let truth = recording.truth {
            let report = AccuracyReport.compare(
                measured: balls.map(\.position), truth: truth, matchWithinMm: recording.table.ballDiameterMm
            )
            print(report.summary)
        }
    } catch {
        fail("Couldn't replay \(path): \(error)")
    }
}

func record(_ path: String) {
    let folder = URL(fileURLWithPath: path)
    let table = tableNamed(option("table", default: "pool9"))
    let scene = SceneGenerator.make(table: table, ballCount: 12, seed: 7)
    var rng = SeededRandom(seed: 7)
    let renderer = SceneRenderer()
    do {
        var recording = SceneRecording(table: table, pose: scene.pose, truth: scene.balls.map(\.ball.position))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (i, camera) in SweepPath.cameras(for: scene, options: SweepOptions(), rng: &rng).enumerated() {
            let image = renderer.render(scene, camera: camera, frameSeed: UInt64(i))
            try recording.append(frame: CameraFrame(image: image, camera: camera), in: folder)
        }
        try recording.save(to: folder)
        print("Wrote \(recording.frames.count) frames to \(path)")
    } catch {
        fail("Couldn't record: \(error)")
    }
}

/// The app's own scan loop on the demo table: frames repeat until every area is covered.
func session() {
    let table = tableNamed(option("table", default: "pool8"))
    let scene = SceneGenerator.make(table: table, ballCount: table.game == .pool ? 10 : 16, seed: 42)
    var options = SweepOptions()
    options.width = 800
    options.height = 600
    options.focal = 604
    options.frames = table.game == .pool ? 12 : 18
    var rng = SeededRandom(seed: 45)
    let cameras = SweepPath.cameras(for: scene, options: options, rng: &rng)
    let runner = ScanRunner()
    var tapRng = SeededRandom(seed: 9)
    var rays: [Ray] = []
    for corner in runner.corners(of: table) {
        let camera = SweepPath.cornerCamera(for: scene, corner: corner, options: options, rng: &tapRng)
        let hit = camera.project(scene.pose.world(corner))!.pixel
        rays.append(camera.ray(through: PixelPoint(hit.x + tapRng.gaussian(3), hit.y + tapRng.gaussian(3))))
    }
    let pose = TableSolver.solve(rays: rays, lengthMm: table.lengthMm, widthMm: table.widthMm)!.pose
    var scan = ScanSession(table: table, pose: pose)
    var i = 0
    while !scan.isComplete && i < 120 {
        let camera = cameras[i % cameras.count]
        scan.add(CameraFrame(image: SceneRenderer().render(scene, camera: camera, frameSeed: UInt64(i)), camera: camera))
        i += 1
    }
    let balls = scan.finish()
    let report = AccuracyReport.compare(measured: balls.map(\.position), truth: scene.balls.map(\.ball.position), matchWithinMm: table.ballDiameterMm)
    print("GENERATED DEMO TABLE: \(i) frames, coverage \(Int(scan.coverage * 100))%, view disagreement \(String(format: "%.1f", scan.tracker.viewDisagreement))")
    print(report.summary)
}

func shots(_ path: String) {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("Couldn't read \(path)") }
    let results = text.split(whereSeparator: \.isNewline).compactMap { ShotResult(logLine: String($0)) }
    let rates = ShotLogSummary.potRates(results)
    for band in [Difficulty.easy, .medium, .hard] {
        let entry = rates[band] ?? (0, 0)
        let rate = entry.total > 0 ? Double(entry.potted) / Double(entry.total) * 100 : 0
        print("\(band.rawValue): \(entry.potted) of \(entry.total) potted (\(String(format: "%.0f", rate))%)")
    }
}

switch arguments.first {
case "accuracy": accuracy()
case "advice": advice()
case "compare" where arguments.count >= 3: compare(arguments[1], arguments[2])
case "replay" where arguments.count >= 2: replay(arguments[1])
case "record" where arguments.count >= 2: record(arguments[1])
case "shots" where arguments.count >= 2: shots(arguments[1])
case "session": session()
default:
    print("Usage: cuesight-bench accuracy | advice | compare a.csv b.csv | replay folder | record folder | shots log")
    exit(2)
}
