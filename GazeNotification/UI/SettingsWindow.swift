import AppKit
import SwiftUI

/// 설정 창 (성능 그래프 · 연산 제한 · 보정 조정). 메뉴 막대 앱이라 직접 NSWindow 를 띄운다.
/// 창이 닫히면 SwiftUI 뷰를 떼어 내 숨은 창이 값 변화에 다시 그려지지 않게 한다.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if window.contentView == nil {
            window.contentView = NSHostingView(rootView: SettingsView(model: model))
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        updateVisibility()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "GazeNotification 설정"
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 520)
        window.center()
        window.setFrameAutosaveName("GazeNotificationSettings")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.isSettingsVisible = false
        window?.contentView = nil
    }

    /// 다른 창에 완전히 가려지거나 최소화되면 보이지 않는 것으로 친다 (실시간 속도·값 갱신 중단)
    func windowDidChangeOcclusionState(_ notification: Notification) {
        updateVisibility()
    }

    private func updateVisibility() {
        guard let window else { return }
        model.isSettingsVisible = window.isVisible && window.occlusionState.contains(.visible)
    }
}

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            PerformanceView(model: model)
                .tabItem { Label(SettingsTab.performance.title, systemImage: SettingsTab.performance.symbol) }
                .tag(SettingsTab.performance)
            LimitsView(model: model)
                .tabItem { Label(SettingsTab.limits.title, systemImage: SettingsTab.limits.symbol) }
                .tag(SettingsTab.limits)
            CalibrationAdjustView(model: model)
                .tabItem { Label(SettingsTab.calibration.title, systemImage: SettingsTab.calibration.symbol) }
                .tag(SettingsTab.calibration)
        }
        .padding(.top, 6)
        .frame(minWidth: 680, minHeight: 520)
    }
}
