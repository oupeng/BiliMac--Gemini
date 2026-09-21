import SwiftUI

@main
struct BiliMacApp: App {
    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 1020, minHeight: 660)
        }
        // 🌟 现代 macOS 一体化窗口设计（去除古老的灰白粗标题栏，与现代系统风格完全贴合）
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
    }
}
