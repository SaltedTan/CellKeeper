import AppKit
import SwiftUI

@main
struct CellKeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: appDelegate.model)
        } label: {
            Image(systemName: appDelegate.model.menuBarSymbolName)
                .accessibilityLabel("CellKeeper")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: appDelegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    /// Gives the controller a bounded chance to restore macOS default charging
    /// before the app exits.
    ///
    /// The restore runs off the main actor and the reply is delivered through
    /// the run loop: `.terminateLater` spins a nested run loop, and if
    /// `terminate(_:)` was called from a main-queue job, main-actor tasks could
    /// not run until it returns.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let controller = model.stopForTermination()
        Task.detached {
            await AppModel.restoreSystemDefaults(using: controller, timeout: AppModel.terminationTimeout)
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    NSApplication.shared.reply(toApplicationShouldTerminate: true)
                }
            }
        }
        return .terminateLater
    }
}
