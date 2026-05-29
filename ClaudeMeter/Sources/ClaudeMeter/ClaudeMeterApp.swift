import SwiftUI

@main
struct ClaudeMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 메뉴바 전용 앱 — 별도 윈도우 없음
        Settings {
            EmptyView()
        }
    }
}
