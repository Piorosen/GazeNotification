import AppKit
import SwiftUI

/// 개발용: 터미널에서 분산 알림으로 앱을 조작한다 (`scripts/debug.sh test|dump|status`).
/// Debug 빌드는 항상, Release 빌드는 `defaults write party.udon.GazeNoti debugCommands -bool YES` 일 때만 켜진다.
@MainActor
enum DebugCommands {
    static let prefix = "party.udon.GazeNoti.debug."

    static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        UserDefaults.standard.bool(forKey: "debugCommands")
        #endif
    }

    static func install(model: AppModel) {
        guard isEnabled else { return }
        let handlers: [(String, @MainActor (AppModel) -> Void)] = [
            ("test", { $0.sendTestNotification(after: 0) }),
            ("dump", { $0.dumpAccessibilityTree(reveal: false) }),
            ("status", { $0.logStatus() }),
            ("snapshot", { snapshotMenu(model: $0) }),
        ]
        let center = DistributedNotificationCenter.default()
        for (name, handler) in handlers {
            center.addObserver(forName: Notification.Name(prefix + name), object: nil, queue: .main) { [weak model] _ in
                MainActor.assumeIsolated {
                    guard let model else { return }
                    Log.info("debug command: \(name)")
                    handler(model)
                }
            }
        }
    }
}

extension DebugCommands {
    /// 메뉴 패널을 화면 밖 창에 그려 ~/Library/Logs/GazeNoti/menu.png 로 저장 (레이아웃 확인용)
    static func snapshotMenu(model: AppModel) {
        let root = MenuView(model: model).background(Color(nsColor: .windowBackgroundColor))
        let hosting = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 420, height: 2000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()

        // 값이 채워지도록 잠시 기다린 뒤 캡처 (1초 요약 타이머, 프레임 처리)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            MainActor.assumeIsolated {
                hosting.layoutSubtreeIfNeeded()
                let size = hosting.fittingSize
                window.setContentSize(size)
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        let url = Log.directory.appendingPathComponent("menu.png")
                        try? data.write(to: url)
                        Log.info("메뉴 스냅샷 저장: \(url.path) \(Int(size.width))x\(Int(size.height))")
                    }
                }
                window.orderOut(nil)
                window.contentView = nil
            }
        }
    }
}
