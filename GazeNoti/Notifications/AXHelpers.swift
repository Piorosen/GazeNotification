import ApplicationServices
import CoreGraphics

/// AXUIElement 속성 읽기/쓰기 헬퍼.
enum AX {
    /// 누적 AX 호출 수 (모두 메인 스레드에서 호출됨, 메뉴의 "AX 호출/s" 표시용)
    static var callCount = 0

    static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard counted(AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)) == .success else { return nil }
        return ref as? String
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard counted(AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref)) == .success else { return [] }
        return ref as? [AXUIElement] ?? []
    }

    static func windows(of app: AXUIElement) -> (windows: [AXUIElement], error: AXError) {
        var ref: CFTypeRef?
        let error = counted(AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref))
        return (ref as? [AXUIElement] ?? [], error)
    }

    static func position(_ element: AXUIElement) -> CGPoint? {
        guard let value = axValue(element, kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement) -> CGSize? {
        guard let value = axValue(element, kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    /// 전역 AX 좌표계(주 디스플레이 좌상단 원점) 기준 frame.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let origin = position(element), let size = size(element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> AXError {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return .failure }
        return counted(AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value))
    }

    static func isPositionSettable(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return counted(AXUIElementIsAttributeSettable(element, kAXPositionAttribute as CFString, &settable)) == .success
            && settable.boolValue
    }

    private static func counted(_ error: AXError) -> AXError {
        callCount += 1
        return error
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var ref: CFTypeRef?
        guard counted(AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)) == .success,
              let ref, CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        return (ref as! AXValue)
    }

    /// 진단용 트리 덤프. 알림 본문이 로그에 남지 않도록 title/description 은 길이만 기록한다.
    static func describe(_ element: AXUIElement, depth: Int = 0, maxDepth: Int = 14, into output: inout String) {
        var line = String(repeating: "  ", count: depth) + (string(element, kAXRoleAttribute) ?? "?")
        if let subrole = string(element, kAXSubroleAttribute) { line += " [\(subrole)]" }
        if let identifier = string(element, kAXIdentifierAttribute), !identifier.isEmpty { line += " id=\(identifier)" }
        if let title = string(element, kAXTitleAttribute), !title.isEmpty { line += " title(len=\(title.count))" }
        if let desc = string(element, kAXDescriptionAttribute), !desc.isEmpty { line += " desc(len=\(desc.count))" }
        if let frame = frame(element) {
            line += " frame=(\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)))"
        }
        if isPositionSettable(element) { line += " pos-settable" }
        output += line + "\n"
        guard depth < maxDepth else { return }
        for child in children(element) {
            describe(child, depth: depth + 1, maxDepth: maxDepth, into: &output)
        }
    }
}
