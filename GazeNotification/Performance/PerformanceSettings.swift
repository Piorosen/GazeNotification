import Foundation

/// 연산량 프로필. 자동은 전원 상태(`PowerState`)에 따라 균형/절전 중 하나를 고른다.
enum PerformanceProfile: String, CaseIterable, Identifiable, Codable {
    case automatic, performance, balanced, saver, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "자동")
        case .performance: String(localized: "성능 우선")
        case .balanced: String(localized: "균형")
        case .saver: String(localized: "절전")
        case .custom: String(localized: "사용자 지정")
        }
    }

    var summary: String {
        switch self {
        case .automatic: String(localized: "전원에 연결되어 있으면 균형, 배터리 사용 중이거나 저전력 모드 또는 발열이 높을 때는 절전을 사용합니다.")
        case .performance: String(localized: "반응이 가장 빠르지만 전력 소비가 가장 많습니다.")
        case .balanced: String(localized: "일반적인 사용에 권장하는 설정입니다.")
        case .saver: String(localized: "전력 소비를 줄입니다. 시선 변화가 조금 늦게 반영됩니다.")
        case .custom: String(localized: "아래 값을 직접 설정합니다.")
        }
    }

    /// 프로필 고유값 (자동·사용자 지정은 nil)
    var presetLimits: PerformanceLimits? {
        switch self {
        case .performance: .performance
        case .balanced: .balanced
        case .saver: .saver
        case .automatic, .custom: nil
        }
    }
}

/// 연산 제한값. 처리 횟수는 모두 "초당 Vision 처리 횟수"이고, 카메라 장치 fps 는 이 값에 맞춰 자동으로 정해진다.
struct PerformanceLimits: Codable, Equatable {
    /// 얼굴이 보이고 시선이 움직일 때
    var activeHz: Double
    /// 시선이 한곳에 머물 때
    var stillHz: Double
    /// 얼굴이 보이지 않을 때
    var awayHz: Double
    /// 시선이 이 시간(초) 넘게 머물면 "머묾"
    var stillAfter: Double
    /// 얼굴이 이 시간(초) 넘게 안 보이면 "자리 비움"
    var awayAfter: Double
    /// N 번 처리마다 1번만 전체 얼굴 검출. 그 사이는 직전 얼굴 위치를 따라가며 랜드마크만 찾는다 (1 = 매번 검출)
    var detectionInterval: Int
    /// 알림이 없을 때 창 서버에 알림 창 표시 여부를 묻는 횟수/s
    var notificationCheckHz: Double
    /// 알림이 떠 있는 동안 "움직일 때" 속도로 올려 따라가기를 빠르게
    var boostWhileNotification: Bool
    /// 카메라·AI 연산 CPU 상한 (코어 1개 = 100%). 넘으면 처리 횟수를 자동으로 낮춘다. 0 = 제한 없음
    var cpuLimit: Double
    /// 자리 비움이 이 시간(분) 넘게 이어지면 카메라를 끄고 키보드·마우스 입력이 생기면 다시 켠다. 0 = 끄지 않음
    var cameraOffAfterAway: Double

    static let performance = PerformanceLimits(
        activeHz: 10, stillHz: 5, awayHz: 2, stillAfter: 4, awayAfter: 3, detectionInterval: 1,
        notificationCheckHz: 20, boostWhileNotification: true, cpuLimit: 0, cameraOffAfterAway: 0)
    static let balanced = PerformanceLimits(
        activeHz: 5, stillHz: 2.5, awayHz: 1, stillAfter: 3, awayAfter: 3, detectionInterval: 3,
        notificationCheckHz: 10, boostWhileNotification: true, cpuLimit: 0, cameraOffAfterAway: 10)
    static let saver = PerformanceLimits(
        activeHz: 2.5, stillHz: 1, awayHz: 0.5, stillAfter: 2, awayAfter: 2, detectionInterval: 6,
        notificationCheckHz: 4, boostWhileNotification: true, cpuLimit: 5, cameraOffAfterAway: 3)

    /// 슬라이더 범위 (UI 와 저장값 보정에 함께 사용)
    static let activeRange: ClosedRange<Double> = 0.5...15
    static let stillRange: ClosedRange<Double> = 0.2...10
    static let awayRange: ClosedRange<Double> = 0.1...5
    static let delayRange: ClosedRange<Double> = 1...10
    static let detectionRange: ClosedRange<Int> = 1...10
    static let notificationCheckRange: ClosedRange<Double> = 2...30
    static let cpuLimitRange: ClosedRange<Double> = 0...50
    static let cameraOffRange: ClosedRange<Double> = 0...30

    /// 저장된 값이 범위를 벗어나면 안으로 넣는다
    var sanitized: PerformanceLimits {
        var l = self
        l.activeHz = activeHz.clamped(to: Self.activeRange)
        l.stillHz = stillHz.clamped(to: Self.stillRange)
        l.awayHz = awayHz.clamped(to: Self.awayRange)
        l.stillAfter = stillAfter.clamped(to: Self.delayRange)
        l.awayAfter = awayAfter.clamped(to: Self.delayRange)
        l.detectionInterval = detectionInterval.clamped(to: Self.detectionRange)
        l.notificationCheckHz = notificationCheckHz.clamped(to: Self.notificationCheckRange)
        l.cpuLimit = cpuLimit.clamped(to: Self.cpuLimitRange)
        l.cameraOffAfterAway = cameraOffAfterAway.clamped(to: Self.cameraOffRange)
        return l
    }

    /// "움직일 때" 기준 예상 신경망 추론 횟수/s (얼굴 검출 + 랜드마크)
    var activeInferencesPerSecond: Double {
        activeHz * (1 + 1 / Double(max(1, detectionInterval)))
    }
}

/// 지금 실제로 적용 중인 제한값과 그 이유
struct EffectivePolicy: Equatable {
    /// 실제로 쓰는 프로필 (자동이면 균형/절전 중 하나)
    var applied: PerformanceProfile
    /// 사용자가 고른 프로필
    var selected: PerformanceProfile
    /// 자동일 때 그 프로필을 고른 이유
    var reason: String?
    var limits: PerformanceLimits

    static func resolve(selected: PerformanceProfile, custom: PerformanceLimits, power: PowerState) -> EffectivePolicy {
        switch selected {
        case .automatic:
            let (profile, reason) = automaticChoice(for: power)
            return EffectivePolicy(applied: profile, selected: selected, reason: reason, limits: profile.presetLimits ?? .balanced)
        case .custom:
            return EffectivePolicy(applied: .custom, selected: selected, reason: nil, limits: custom.sanitized)
        case .performance, .balanced, .saver:
            return EffectivePolicy(applied: selected, selected: selected, reason: nil, limits: selected.presetLimits ?? .balanced)
        }
    }

    private static func automaticChoice(for power: PowerState) -> (PerformanceProfile, String) {
        if power.lowPowerMode { return (.saver, String(localized: "저전력 모드")) }
        switch power.thermal {
        case .serious, .critical: return (.saver, String(localized: "발열 높음"))
        default: break
        }
        if power.onBattery {
            return (.saver, power.batteryLevel.map { String(localized: "배터리 사용 중 (\($0)%)") } ?? String(localized: "배터리 사용 중"))
        }
        return (.balanced, String(localized: "전원 연결됨"))
    }
}
