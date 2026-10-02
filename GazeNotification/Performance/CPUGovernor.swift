import Foundation

/// 카메라·AI CPU 가 상한을 넘으면 처리 횟수 비율(`scale`)을 비례해 줄이고, 여유가 생기면 천천히 되돌린다.
struct CPUGovernor {
    enum Input {
        /// 제한 없음 또는 카메라 꺼짐 → 비율을 1 로
        case off
        /// 실시간(보정·미리보기)·일시 정지 중 → 비율 유지, 측정값 무시
        case hold
        /// 이번 1초의 카메라·AI CPU (코어 1개 = 100%)
        case measured(Double)
    }

    static let minScale = 0.05

    /// 처리 횟수에 곱할 비율 (1 = 줄이지 않음)
    private(set) var scale = 1.0
    private var average: Double?

    /// - Returns: 비율이 바뀌었으면 true
    mutating func update(_ input: Input, limit: Double) -> Bool {
        let previous = scale
        switch input {
        case .off:
            average = nil
            scale = 1
        case .hold:
            average = nil
        case .measured(let cpu):
            guard limit > 0 else {
                average = nil
                scale = 1
                break
            }
            let smoothed = average.map { $0 * 0.6 + cpu * 0.4 } ?? cpu
            average = smoothed
            if smoothed > limit {
                scale = max(Self.minScale, scale * max(0.5, limit / smoothed))
            } else if smoothed < limit * 0.7 {
                scale = min(1, scale * 1.15)
            }
        }
        return abs(scale - previous) > 0.005
    }
}
