import SwiftUI

@main
struct AmigaEmuApp: App {
    @StateObject private var emu = EmulatorController.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(emu)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: emu.handleBackground()   // save state for instant restart
            case .active:     emu.handleForeground()
            default: break
            }
        }
    }
}
