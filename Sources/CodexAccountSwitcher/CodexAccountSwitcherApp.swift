import CodexAccountSwitcherCore
import Darwin
import SwiftUI

@main
struct CodexAccountSwitcherApp: App {
    @StateObject private var model: AppModel
    @StateObject private var claude = ClaudeDashboardModel()

    init() {
        if CommandLine.arguments.contains("--emergency-restore") {
            Self.runCommand { try CommandLineOperations.emergencyRestore() }
        }
        if CommandLine.arguments.contains("--purge-data") {
            Self.runCommand { try CommandLineOperations.purge() }
        }
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        Task { @MainActor in
            await model.bootstrap()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(model: model, claude: claude)
        } label: {
            Label("Codex Account Switcher", systemImage: "arrow.triangle.2.circlepath.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }

    private static func runCommand(_ operation: () throws -> Void) -> Never {
        do {
            try operation()
            print("완료")
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            fputs("오류: \(Redactor.redact(error.localizedDescription))\n", stderr)
            Darwin.exit(EXIT_FAILURE)
        }
    }
}
