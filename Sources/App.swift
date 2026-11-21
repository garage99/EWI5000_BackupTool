// EWI5000 Bank Manager for macOS
// AKAI EWI5000 のユーザーバンクを USB MIDI でバックアップ・復元するアプリ（Swift / SwiftUI / CoreMIDI）

import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in AppModel.shared.openFile(url) }
    }
}

@main
struct EWI5000BankManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel.shared

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest"), i + 1 < args.count {
            exit(SelfTest.run(args[i + 1]))
        }
    }

    var body: some Scene {
        Window("EWI5000 Bank Manager", id: "main") {
            ContentView().environmentObject(model)
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("ファイルを開く…") { model.openFile() }.keyboardShortcut("o")
            }
        }
    }
}
