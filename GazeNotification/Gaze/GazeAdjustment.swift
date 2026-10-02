import Foundation

/// 사람이 손으로 맞추는 시선 보정값. 보정 모델(또는 기본 추정식)의 출력에 차례로 적용된다.
///
/// 모델 출력 x → `featureGains` 로 특징별 기여 조절 → 좌우 이동·범위 → One Euro 필터(`smoothing`, `responsiveness`) → 구역 맞춤
struct GazeAdjustment: Codable, Equatable {
    /// 좌우 이동 (화면 폭 비율, + = 오른쪽)
    var offset: Double = 0
    /// 가운데보다 왼쪽을 볼 때의 범위 배율 (1 = 그대로, 크면 더 왼쪽 끝까지 감)
    var leftGain: Double = 1
    /// 가운데보다 오른쪽을 볼 때의 범위 배율
    var rightGain: Double = 1
    /// 특징별 기여 배율 (`GazeFeature` 순서: 코 방향, 동공, 얼굴 위치, 머리 yaw). 0 = 사용 안 함
    var featureGains: [Double] = [1, 1, 1, 1]
    /// 필터의 기본 차단 주파수(Hz). 낮을수록 떨림이 줄지만 느리게 따라온다
    var smoothing: Double = 0.8
    /// 빠르게 움직일 때 필터를 얼마나 풀지. 클수록 큰 시선 이동에 빨리 반응
    var responsiveness: Double = 2.0
    /// 화면을 N 구역으로 나눠 구역 가운데로 맞춤. 0 = 끔
    var zones: Int = 0
    /// 떠 있는 알림은 목표가 화면 폭의 이 비율 이상 바뀔 때만 따라간다
    var followThreshold: Double = 0.08

    static let offsetRange: ClosedRange<Double> = -0.3...0.3
    static let gainRange: ClosedRange<Double> = 0.4...2.5
    static let featureGainRange: ClosedRange<Double> = 0...2
    static let smoothingRange: ClosedRange<Double> = 0.1...3
    static let responsivenessRange: ClosedRange<Double> = 0...8
    static let zoneChoices = [0, 2, 3, 4, 5, 6]
    static let followRange: ClosedRange<Double> = 0.02...0.25

    var isPositionDefault: Bool { offset == 0 && leftGain == 1 && rightGain == 1 }

    func featureGain(_ feature: GazeFeature) -> Double {
        feature.rawValue < featureGains.count ? featureGains[feature.rawValue] : 1
    }

    /// 좌우 이동 후 가운데(0.5)를 기준으로 왼쪽/오른쪽 범위를 따로 늘이거나 줄인다
    func mapPosition(_ x: Double) -> Double {
        let shifted = x + offset
        return 0.5 + (shifted - 0.5) * (shifted < 0.5 ? leftGain : rightGain)
    }

    func resettingPosition() -> GazeAdjustment {
        var copy = self
        copy.offset = 0
        copy.leftGain = 1
        copy.rightGain = 1
        return copy
    }

    /// 저장값이 범위를 벗어났거나 특징 수가 다르면 바로잡는다
    var sanitized: GazeAdjustment {
        var a = self
        a.offset = offset.clamped(to: Self.offsetRange)
        a.leftGain = leftGain.clamped(to: Self.gainRange)
        a.rightGain = rightGain.clamped(to: Self.gainRange)
        a.featureGains = GazeFeature.allCases.map { feature in
            (feature.rawValue < featureGains.count ? featureGains[feature.rawValue] : 1).clamped(to: Self.featureGainRange)
        }
        a.smoothing = smoothing.clamped(to: Self.smoothingRange)
        a.responsiveness = responsiveness.clamped(to: Self.responsivenessRange)
        a.zones = Self.zoneChoices.contains(zones) ? zones : 0
        a.followThreshold = followThreshold.clamped(to: Self.followRange)
        return a
    }

    /// 빠른 위치 맞춤: 왼쪽·가운데·오른쪽 점을 볼 때의 모델 출력 평균으로 이동량과 좌우 범위를 구한다.
    static func fit(left: (target: Double, raw: Double), center: (target: Double, raw: Double),
                    right: (target: Double, raw: Double)) -> Result<(offset: Double, leftGain: Double, rightGain: Double), FitError> {
        let offset = center.target - center.raw
        guard center.raw - left.raw > 0.03, right.raw - center.raw > 0.03 else { return .failure(.noSpread) }
        let leftGain = (left.target - center.target) / (left.raw - center.raw)
        let rightGain = (right.target - center.target) / (right.raw - center.raw)
        guard offsetRange.contains(offset) else { return .failure(.outOfRange) }
        return .success((offset, leftGain.clamped(to: gainRange), rightGain.clamped(to: gainRange)))
    }

    enum FitError: Error {
        case noSpread, outOfRange

        var message: String {
            switch self {
            case .noSpread: String(localized: "왼쪽, 가운데, 오른쪽을 볼 때의 추정값 차이가 너무 작습니다. 먼저 시선 보정을 실행하세요.")
            case .outOfRange: String(localized: "추정 위치가 허용 범위를 벗어났습니다. 먼저 시선 보정을 실행하세요.")
            }
        }
    }
}

/// 화면을 N 구역으로 나눠 구역 가운데 값을 돌려준다. 경계 근처에서 왔다 갔다 하지 않도록 이력(hysteresis)을 둔다.
struct ZoneSnapper {
    private var current: Int?
    private var zones = 0

    mutating func reset() { current = nil }

    mutating func snap(_ x: Double, zones n: Int) -> Double {
        guard n > 1 else { return x }
        if n != zones { zones = n; current = nil }
        let width = 1 / Double(n)
        if let current {
            // 현재 구역에서 구역 폭의 20% 더 벗어나야 옮긴다
            let margin = width * 0.2
            let low = Double(current) * width - margin, high = Double(current + 1) * width + margin
            if x >= low && x <= high { return (Double(current) + 0.5) * width }
        }
        let zone = min(n - 1, max(0, Int(x * Double(n))))
        current = zone
        return (Double(zone) + 0.5) * width
    }
}
