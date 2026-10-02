import SwiftUI

@main
struct GazeNotificationApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: appDelegate.model)
        } label: {
            MenuBarLabel(model: appDelegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var terminationSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        DebugCommands.install(model: model)

        // kill/pkill(SIGTERM) 로 끝나도 알림 창을 원위치시키도록 정상 종료 경로로 돌린다
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApp.terminate(nil) }
        source.resume()
        terminationSource = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }
}

private struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.menuBarSymbol)
    }
}
