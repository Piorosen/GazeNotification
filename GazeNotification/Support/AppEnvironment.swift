import Foundation

/// 실행 환경 구분 (일반 / UI 테스트 / 단위 테스트)
enum AppEnvironment {
    /// UI 테스트 모드 (`-uiTesting` 실행 인자). 카메라·알림 창 이동·권한 요청 없이 가짜 얼굴 특징으로 동작하고,
    /// 설정은 별도 저장소에 둬서 실제 설정을 건드리지 않는다. `-uiTestingReset` 이면 시작할 때 그 저장소를 비운다.
    static let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")

    /// 단위 테스트의 호스트로 실행됨 — 앱은 띄우되 카메라·감시를 시작하지 않는다
    static let isUnitTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static let uiTestingSuiteName = "party.udon.GazeNotification.uitesting"

    /// 앱 설정 저장소
    static let defaults: UserDefaults = {
        guard isUITesting, let suite = UserDefaults(suiteName: uiTestingSuiteName) else { return .standard }
        if ProcessInfo.processInfo.arguments.contains("-uiTestingReset") {
            suite.removePersistentDomain(forName: uiTestingSuiteName)
        }
        return suite
    }()

    /// 실제 기기(카메라·NotificationCenter·권한)를 건드려도 되는지
    static var usesRealDevices: Bool { !isUITesting && !isUnitTesting }
}
