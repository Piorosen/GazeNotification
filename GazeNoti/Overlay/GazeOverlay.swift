import AppKit

/// 화면 최상단(메뉴 막대 바로 아래)에 "알림이 뜰 위치"를 얇은 막대로 보여주는 클릭 통과 패널.
@MainActor
final class GazeOverlay {
    private var panel: NSPanel?
    private let barView = NSView()
    private let barSize = CGSize(width: 360, height: 5)

    var isVisible: Bool { panel?.isVisible ?? false }

    func setVisible(_ visible: Bool) {
        if visible {
            let panel = self.panel ?? makePanel()
            self.panel = panel
            panel.orderFrontRegardless()
        } else {
            panel?.orderOut(nil)
        }
    }

    func update(normalizedX: Double?, faceDetected: Bool) {
        guard let panel, panel.isVisible, let normalizedX, let screen = NSScreen.main else { return }
        let frame = screen.frame
        let visible = screen.visibleFrame
        let centerX = frame.minX + CGFloat(normalizedX) * frame.width
        let originX = (centerX - barSize.width / 2)
            .clamped(to: frame.minX + 16...max(frame.minX + 16, frame.maxX - barSize.width - 16))
        panel.setFrame(NSRect(x: originX, y: visible.maxY - barSize.height - 2,
                              width: barSize.width, height: barSize.height), display: false)
        let color: NSColor = faceDetected ? .systemGreen : .systemGray
        barView.layer?.backgroundColor = color.withAlphaComponent(0.85).cgColor
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: barSize),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        barView.wantsLayer = true
        barView.layer?.cornerRadius = barSize.height / 2
        barView.layer?.backgroundColor = NSColor.systemGray.cgColor
        barView.autoresizingMask = [.width, .height]
        panel.contentView = barView
        return panel
    }
}
