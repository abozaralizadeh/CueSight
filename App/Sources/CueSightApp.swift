import SwiftUI

@main
struct CueSightApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch model.flow.step {
            case .firstRun: FirstRunView()
            case .start: StartView()
            // The camera screens are landscape overlays on the table, so text stops growing at
            // the largest standard size. Otherwise panels would cover the table they're about.
            case .tableSetup: TableSetupView().dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            case .scan: ScanView().dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            case .review: ReviewView().dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            case .shots: ShotsView().dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            case .trackingLost: TrackingLostView().dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
        }
    }
}

/// Shared look for buttons over a camera image.
struct PillButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        Pill(label: configuration.label, prominent: prominent, pressed: configuration.isPressed)
    }

    private struct Pill<Label: View>: View {
        @Environment(\.isEnabled) private var isEnabled
        let label: Label
        let prominent: Bool
        let pressed: Bool

        var body: some View {
            label
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(prominent && isEnabled ? Color.accentColor : Color.black.opacity(0.65), in: Capsule())
                .foregroundStyle(isEnabled ? .white : .gray)
                .opacity(pressed ? 0.7 : 1)
        }
    }
}

struct InfoPanel<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        // Text wraps to its full height rather than cutting off at large text sizes.
        VStack(alignment: .leading, spacing: 8) { content }
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
