import SwiftUI
import AVFoundation
import ShotEngine
import SessionCore

struct FirstRunView: View {
    @EnvironmentObject var model: AppModel
    @State private var denied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("CueSight").font(.largeTitle.bold())
                Text("Point your phone at a pool or snooker table and see your shot options drawn on it: the lines the balls take, where to aim and how hard to hit.")
                Text("The camera is used to see the table and the balls. Images stay on your phone. Nothing is uploaded and there's no account.")
                    .foregroundStyle(.secondary)
                InfoPanel {
                    Label("Lines are a guide. Real shots vary with your stroke, the cloth and the table.", systemImage: "info.circle")
                    Label("It's for practice and casual play. Competitions may not allow it.", systemImage: "flag")
                    Label("Accuracy hasn't been checked on a real table yet.", systemImage: "ruler")
                }
                if denied {
                    Text("Camera access is off. Turn it on in Settings to use a real table, or keep going with the demo table.")
                        .foregroundStyle(.orange)
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
                Button(model.isDemo ? "Start with the demo table" : "Allow camera and start") {
                    Task { await start() }
                }
                .buttonStyle(PillButtonStyle(prominent: true))
            }
            .padding(24)
            .frame(maxWidth: 640, alignment: .leading)
        }
    }

    private func start() async {
        if model.isDemo {
            model.finishFirstRun()
            return
        }
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        if allowed {
            model.finishFirstRun()
        } else {
            denied = true
        }
    }
}

struct StartView: View {
    @EnvironmentObject var model: AppModel
    @State private var showSettings = false
    @State private var showCustom = false

    var body: some View {
        NavigationStack {
            List {
                if model.isDemo {
                    Section {
                        Label("Demo table. The camera isn't used, and the table is generated.", systemImage: "sparkles")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Choose your table") {
                    ForEach(model.tables) { table in
                        Button {
                            model.choose(table)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(table.name).font(.headline)
                                Text("\(model.format(table.lengthMm)) x \(model.format(table.widthMm))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            if table.id.hasPrefix("custom") {
                                Button("Delete", role: .destructive) { model.deleteCustomTable(table) }
                            }
                        }
                    }
                    Button("Add a custom size") { showCustom = true }
                }
            }
            .navigationTitle("CueSight")
            .toolbar {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showCustom) { CustomTableView() }
        }
    }
}

struct CustomTableView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var game: Game = .pool
    @State private var length = ""
    @State private var width = ""

    private var factor: Double { model.settings.useInches ? 25.4 : 1 }
    private var lengthMm: Double? { Double(length).map { $0 * factor } }
    private var widthMm: Double? { Double(width).map { $0 * factor } }
    private var valid: Bool {
        guard let l = lengthMm, let w = widthMm else { return false }
        return l > w && w > 500 && l < 4000
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker("Game", selection: $game) {
                    Text("Pool").tag(Game.pool)
                    Text("Snooker").tag(Game.snooker)
                }
                Section {
                    TextField("Length", text: $length).keyboardType(.decimalPad)
                    TextField("Width", text: $width).keyboardType(.decimalPad)
                } header: {
                    Text("Playing area, cushion to cushion, in \(model.settings.useInches ? "inches" : "mm")")
                } footer: {
                    Text("Measure inside the cushions. A wrong size shows up later as views that don't line up.")
                }
            }
            .navigationTitle("Custom table")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let l = lengthMm, let w = widthMm { model.addCustomTable(game: game, lengthMm: l, widthMm: w) }
                        dismiss()
                    }
                    .disabled(!valid)
                }
            }
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show inches", isOn: $model.settings.useInches)
                    Toggle("Tester mode", isOn: $model.settings.testerMode)
                    #if !targetEnvironment(simulator)
                    Toggle("Demo table", isOn: Binding(get: { model.settings.demoMode }, set: { model.setDemoMode($0) }))
                    #endif
                } footer: {
                    Text("Tester mode adds Went in and Missed buttons, so the difficulty labels can be tuned from real shots.")
                }
                Section("Help with problems") {
                    ShareLink(item: model.log.fileURL) { Label("Export log", systemImage: "doc.text") }
                    if let scan = model.lastScanFile() {
                        ShareLink(item: scan) { Label("Export last scan (CSV)", systemImage: "tablecells") }
                    }
                    Button("Clear log", role: .destructive) { model.log.clear() }
                }
                Section("About") {
                    NavigationLink("Privacy") { TextPage(title: "Privacy", text: AboutText.privacy) }
                    NavigationLink("Licences") { LicencesView() }
                    NavigationLink("About CueSight") { TextPage(title: "About", text: AboutText.about) }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}

struct TextPage: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView { Text(text).padding() }.navigationTitle(title)
    }
}

struct LicencesView: View {
    var body: some View {
        List(Licences.entries, id: \.name) { entry in
            VStack(alignment: .leading) {
                Text(entry.name).font(.headline)
                Text(entry.licence)
                Text(entry.note).foregroundStyle(.secondary).font(.footnote)
            }
        }
        .navigationTitle("Licences")
    }
}

enum AboutText {
    static let privacy = """
    CueSight uses the camera to see the table and the balls. Camera images are processed on your phone and thrown away. They're never saved or sent anywhere.

    There's no account, no analytics and no advertising.

    The app keeps a small log of what it did, such as "scan done, 12 balls", so problems can be fixed. The log has no images and stays on your phone unless you choose to export it.

    This is a draft and needs a proper review before the app is released.
    """

    static let about = """
    CueSight (working name) shows shot options on a real pool or snooker table: the lines the balls take, where to aim and how hard to hit.

    Lines are a guide. Real shots vary with your stroke, the cloth and the table.

    It's for practice and casual play. Competitions may not allow it.

    Accuracy hasn't been checked on a real table yet. So far it's only been tested on generated tables.
    """
}
