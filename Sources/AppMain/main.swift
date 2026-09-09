import AppUI
import SwiftUI

@main
@MainActor
struct AILanguageCoachApp: App {

    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            MainView(state: state)
                .frame(minWidth: 1080, minHeight: 720)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1280, height: 820)
    }
}
