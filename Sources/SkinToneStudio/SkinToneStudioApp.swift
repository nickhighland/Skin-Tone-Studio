import SkinToneCore
import SwiftUI

@main
struct SkinToneStudioApp: App {
    @NSApplicationDelegateAdaptor(MenuBarController.self) private var menuBarController

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(nil)
        }
        .defaultSize(width: 1180, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
