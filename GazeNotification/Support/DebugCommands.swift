import AppKit
import SwiftUI

/// 개발용: 터미널에서 분산 알림으로 앱을 조작한다 (`scripts/debug.sh test|dump|status|snapshot|settings-*`).
/// Debug 빌드는 항상, Release 빌드는 `defaults write party.udon.GazeNotification debugCommands -bool YES` 일 때만 켜진다.
@MainActor
enum DebugCommands {
    static let prefix = "party.udon.GazeNotification.debug."

    static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        UserDefaults.standard.bool(forKey: "debugCommands")
        #endif
    }

    static func install(model: AppModel) {
        guard isEnabled else { return }
        typealias Handler = (String, @MainActor (AppModel) -> Void)
        // 타입을 명시하지 않으면 map 결과의 클로저가 @MainActor 가 아닌 타입으로 추론돼 배열을 합칠 때 실행 중 형변환이 실패한다
        var handlers: [Handler] = [
            ("test", { $0.sendTestNotification(after: 0) }),
            ("dump", { $0.dumpAccessibilityTree(reveal: false) }),
            ("status", { $0.logStatus() }),
            ("snapshot", { snapshotMenu(model: $0) }),
        ]
        handlers += SettingsTab.allCases.map { tab -> Handler in
            ("settings-\(tab.rawValue)", { snapshotSettings(model: $0, tab: tab) })
        }
        handlers += AnalysisMode.allCases.map { mode -> Handler in ("mode-\(mode.rawValue)", { $0.analysisMode = mode }) }
        handlers += ComputePreference.allCases.map { device -> Handler in
            ("device-\(device.rawValue)", { $0.computePreference = device })
        }
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
    /// 설정 창의 탭 내용을 화면 밖 창에 그려 ~/Library/Logs/GazeNotification/settings-<탭>.png 로 저장 (레이아웃 확인용).
    /// 그리는 동안은 설정 창이 열린 것처럼 실시간 값을 흘려보낸다.
    static func snapshotSettings(model: AppModel, tab: SettingsTab) {
        let wasVisible = model.isSettingsVisible
        let previousTab = model.settingsTab
        model.settingsTab = tab
        model.isSettingsVisible = true
        let content: AnyView = switch tab {
        case .performance: AnyView(PerformanceView(model: model))
        case .limits: AnyView(LimitsView(model: model))
        case .ai: AnyView(AIModeView(model: model))
        case .calibration: AnyView(CalibrationAdjustView(model: model))
        }
        render(content, name: "settings-\(tab.rawValue).png", width: 760, height: 1400, delay: 4) {
            if !wasVisible {
                model.isSettingsVisible = false
                model.settingsTab = previousTab
            }
        }
    }

    private static func render(_ content: AnyView, name: String, width: CGFloat, height: CGFloat,
                               delay: TimeInterval, completion: @escaping @MainActor () -> Void) {
        let hosting = NSHostingView(rootView: content.frame(width: width, height: height)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: width, height: height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                hosting.layoutSubtreeIfNeeded()
                if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
                    hosting.cacheDisplay(in: hosting.bounds, to: rep)
                    if let data = rep.representation(using: .png, properties: [:]) {
                        let url = Log.directory.appendingPathComponent(name)
                        try? data.write(to: url)
                        Log.info("스냅샷 저장: \(url.path)")
                    }
                }
                window.orderOut(nil)
                window.contentView = nil
                completion()
            }
        }
    }

    /// 메뉴 패널을 화면 밖 창에 그려 ~/Library/Logs/GazeNotification/menu.png 로 저장 (레이아웃 확인용)
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
