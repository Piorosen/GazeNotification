import AppKit
import ApplicationServices
import AVFoundation

enum Permissions {
    static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// 시스템의 "손쉬운 사용 권한" 요청 다이얼로그를 띄운다 (이미 허용이면 아무 일도 없음).
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static var cameraStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openCameraSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
