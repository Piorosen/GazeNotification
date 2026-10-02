import CoreML
import Vision

/// 얼굴 분석 방식 (어떤 Vision 요청으로 어떤 특징을 뽑는지)
enum AnalysisMode: String, CaseIterable, Identifiable, Codable {
    /// 얼굴 검출 + 랜드마크 76점 (동공 포함)
    case precise
    /// 얼굴 검출 + 랜드마크 65점
    case light
    /// 얼굴 검출만 — 머리 방향(yaw)과 얼굴 위치
    case headPose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .precise: String(localized: "정밀 (랜드마크 76개)")
        case .light: String(localized: "경량 (랜드마크 65개)")
        case .headPose: String(localized: "머리 방향만")
        }
    }

    var shortTitle: String {
        switch self {
        case .precise: String(localized: "정밀")
        case .light: String(localized: "경량")
        case .headPose: String(localized: "머리 방향")
        }
    }

    var detail: String {
        switch self {
        case .precise: String(localized: "코 방향, 동공 위치, 얼굴 위치, 머리 회전을 사용합니다. 눈의 움직임까지 반영하여 가장 정확합니다.")
        case .light: String(localized: "랜드마크가 적은 모델을 사용합니다. 동공 위치의 정확도가 낮을 수 있습니다.")
        case .headPose: String(localized: "랜드마크 없이 얼굴 위치와 머리 방향만 사용합니다. 눈만 움직이는 경우는 반영되지 않으며, 얼굴 검출 간격 설정이 적용되지 않습니다.")
        }
    }

    var constellation: VNRequestFaceLandmarksConstellation? {
        switch self {
        case .precise: .constellation76Points
        case .light: .constellation65Points
        case .headPose: nil
        }
    }

    /// 이 방식이 계산하는 특징
    var features: [GazeFeature] {
        switch self {
        case .precise, .light: GazeFeature.allCases
        case .headPose: [.faceX, .yaw]
        }
    }
}

/// Vision 신경망을 돌릴 장치
enum ComputePreference: String, CaseIterable, Identifiable, Codable {
    case automatic, neuralEngine, gpu, cpu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: String(localized: "자동 (Neural Engine 우선)")
        case .neuralEngine: "Neural Engine"
        case .gpu: "GPU"
        case .cpu: "CPU"
        }
    }

    var detail: String {
        switch self {
        case .automatic, .neuralEngine: String(localized: "전력 효율이 가장 높습니다. Neural Engine을 사용할 수 없으면 GPU, CPU 순으로 사용합니다.")
        case .gpu: String(localized: "Neural Engine이 없는 Mac에서 사용합니다. 전력 소비가 늘어납니다.")
        case .cpu: String(localized: "CPU 사용량이 크게 늘어납니다. 비교할 때만 사용하세요.")
        }
    }

    /// 지원 장치 목록에서 이 선호에 맞는 장치
    func pick(from devices: [MLComputeDevice]) -> MLComputeDevice? {
        let ane = devices.first { if case .neuralEngine = $0 { true } else { false } }
        let gpu = devices.first { if case .gpu = $0 { true } else { false } }
        let cpu = devices.first { if case .cpu = $0 { true } else { false } }
        switch self {
        case .automatic, .neuralEngine: return ane ?? gpu ?? cpu
        case .gpu: return gpu ?? cpu
        case .cpu: return cpu
        }
    }
}

/// 시선 추정 모델 종류
enum EstimatorKind: String, CaseIterable, Identifiable, Codable {
    /// 특징 → 화면 x 선형 회귀 (ridge)
    case linear
    /// 특징과 그 세제곱으로 회귀 — 초광폭 화면 양 끝처럼 휘어지는 관계를 잡는다
    case curve
    /// 선형 회귀 출력을 보정 점마다 다시 맞춰 점 사이를 직선으로 잇는다
    case piecewise
    /// 보정 없이 쓰는 고정 식
    case formula

    var id: String { rawValue }

    var title: String {
        switch self {
        case .linear: String(localized: "선형 회귀")
        case .curve: String(localized: "곡선 회귀 (3차)")
        case .piecewise: String(localized: "점별 보간")
        case .formula: String(localized: "기본 추정식")
        }
    }

    var detail: String {
        switch self {
        case .linear: String(localized: "각 특징과 위치의 관계를 직선으로 계산합니다. 가장 단순하고 안정적입니다.")
        case .curve: String(localized: "화면 양 끝에서 휘어지는 관계까지 반영합니다. 보정 점이 적으면 정확도가 떨어질 수 있습니다.")
        case .piecewise: String(localized: "선형 회귀 결과를 각 보정 점의 실제 위치에 맞추고, 점 사이는 직선으로 보간합니다.")
        case .formula: String(localized: "보정 없이 사용하는 기본 계산식입니다. 카메라가 모니터 위 가운데에 있고 약 70cm 거리에서 화면을 본다고 가정합니다.")
        }
    }
}

/// 사용자가 고른 추정 모델 (자동 = 교차검증 오차가 가장 작은 것)
enum EstimatorChoice: String, CaseIterable, Identifiable, Codable {
    case automatic, linear, curve, piecewise, formula

    var id: String { rawValue }

    var kind: EstimatorKind? {
        switch self {
        case .automatic: nil
        case .linear: .linear
        case .curve: .curve
        case .piecewise: .piecewise
        case .formula: .formula
        }
    }

    var title: String { kind?.title ?? String(localized: "자동 (오차가 가장 작은 모델)") }
}
