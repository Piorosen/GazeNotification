import AppKit
import SwiftUI

/// 설정 창 (성능 그래프 · 연산 제한 · 보정 조정). 메뉴 막대 앱이라 직접 NSWindow 를 띄운다.
/// 창이 닫히면 SwiftUI 뷰를 떼어 내 숨은 창이 값 변화에 다시 그려지지 않게 한다.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private unowned let model: AppModel
    private var window: NSWindow?
    /// SwiftUI 화면이 붙어 있는지 (NSWindow 는 만들 때 빈 contentView 를 갖고 있어 nil 검사로는 알 수 없다)
    private var hasContent = false

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if !hasContent {
            window.contentView = NSHostingView(rootView: SettingsView(model: model)
                .defaultAppStorage(AppEnvironment.defaults))
            hasContent = true
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        updateVisibility()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = String(localized: "GazeNotification 설정")
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 680, height: 520)
        window.center()
        if AppEnvironment.isUITesting, let screen = NSScreen.main?.visibleFrame {
            // UI 테스트: 스크롤 없이 모든 컨트롤이 보이도록 화면 높이만큼 (위치·크기를 저장하지 않음)
            let height = min(screen.height - 40, 1900)
            window.setFrame(NSRect(x: screen.midX - 380, y: screen.maxY - height - 20, width: 760, height: height), display: false)
        } else {
            window.setFrameAutosaveName("GazeNotificationSettings")
        }
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        model.isSettingsVisible = false
        window?.contentView = nil
        hasContent = false
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
            AIModeView(model: model)
                .tabItem { Label(SettingsTab.ai.title, systemImage: SettingsTab.ai.symbol) }
                .tag(SettingsTab.ai)
            CalibrationAdjustView(model: model)
                .tabItem { Label(SettingsTab.calibration.title, systemImage: SettingsTab.calibration.symbol) }
                .tag(SettingsTab.calibration)
        }
        .padding(.top, 6)
        .frame(minWidth: 680, minHeight: 520)
    }
}
