import AppKit

extension NSScreen {
    /// Accessibility / Quartz 전역 좌표계(주 디스플레이 좌상단 원점, y 아래로 증가)로 변환한 frame.
    var axFrame: CGRect {
        let primaryMaxY = NSScreen.screens.first?.frame.maxY ?? frame.maxY
        return CGRect(x: frame.minX, y: primaryMaxY - frame.maxY, width: frame.width, height: frame.height)
    }

    static func screen(containingAXPoint point: CGPoint) -> NSScreen? {
        screens.first { $0.axFrame.contains(point) }
    }

    /// 마우스 커서가 올라가 있는 화면 기준 0...1 가로 위치.
    static func normalizedMouseX() -> Double? {
        let mouse = NSEvent.mouseLocation
        guard let screen = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? main else { return nil }
        return Double((mouse.x - screen.frame.minX) / screen.frame.width)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
