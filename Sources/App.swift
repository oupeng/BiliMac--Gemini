import SwiftUI

@main
struct BiliMacApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
    }
}
