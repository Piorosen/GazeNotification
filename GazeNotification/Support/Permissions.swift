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

    /// 이 앱의 손쉬운 사용 항목을 지운다 (관리자 권한 없이 됨). 권한은 코드 서명에 묶여서, 서명이 다른 이전 버전·개발 빌드가
    /// 허용받은 항목이 남아 있으면 목록에는 켜진 채로 보이는데 이 앱은 허용되지 않고, 껐다 켜도 풀리지 않는다.
    @MainActor
    static func resetAccessibility(completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "party.udon.GazeNotification"]
        task.terminationHandler = { process in
            let succeeded = process.terminationStatus == 0
            Task { @MainActor in completion(succeeded) }
        }
        do {
            try task.run()
        } catch {
            completion(false)
        }
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
