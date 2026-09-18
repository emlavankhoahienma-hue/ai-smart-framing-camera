import SwiftUI
import AppIntents

struct OpenAlignAICameraIntent: AppIntent {
    static let title: LocalizedStringResource = "Open AlignAI Camera"
    static let description = IntentDescription("Open AlignAI Studio directly in the camera viewfinder.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        .result()
    }
}

struct AlignAICameraShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenAlignAICameraIntent(),
            phrases: [
                "Open \(.applicationName) camera",
                "Take a photo with \(.applicationName)"
            ],
            shortTitle: "Open Camera",
            systemImageName: "camera.viewfinder"
        )
    }
}

@main
struct AISmartFramingCameraApp: App {
    init() {
        // Keep screen awake while using the AI camera
        UIApplication.shared.isIdleTimerDisabled = true
    }
    
    var body: some Scene {
        WindowGroup {
            CameraMainView()
                .preferredColorScheme(.dark)
        }
    }
}
