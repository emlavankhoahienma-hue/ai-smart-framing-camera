import SwiftUI

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
