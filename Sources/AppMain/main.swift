import AppUI
import SwiftUI

@main
@MainActor
struct AILanguageCoachApp: App {

    @State private var state = AppState()

    var body: some Scene {
        WindowGroup {
            MainView(state: state)
                .frame(minWidth: 1020, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
