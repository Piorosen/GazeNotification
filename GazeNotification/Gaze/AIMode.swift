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
        case .precise: "정밀 · 랜드마크 76점"
        case .light: "가벼움 · 랜드마크 65점"
        case .headPose: "머리 방향만 · 얼굴 검출"
        }
    }

    var shortTitle: String {
        switch self {
        case .precise: "76점"
        case .light: "65점"
        case .headPose: "머리 방향"
        }
    }

    var detail: String {
        switch self {
        case .precise: "코 방향 · 동공 위치 · 얼굴 위치 · 머리 yaw 를 모두 씁니다. 눈동자 움직임까지 반영해 가장 정확합니다."
        case .light: "점이 적은 랜드마크 모델. 같은 특징을 쓰고, 동공 점은 덜 정밀할 수 있습니다."
        case .headPose: "랜드마크 없이 얼굴 상자와 머리 방향만 씁니다. 고개를 돌려 보는 경우에 맞고, 눈만 움직이면 따라가지 못합니다. 매 프레임 얼굴 검출이 필요해 검출 간격 설정은 쓰지 않습니다."
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
        case .automatic: "자동 (Neural Engine 우선)"
        case .neuralEngine: "Neural Engine"
        case .gpu: "GPU"
        case .cpu: "CPU"
        }
    }

    var detail: String {
        switch self {
        case .automatic, .neuralEngine: "전력 효율이 가장 좋습니다. 없으면 GPU → CPU 순."
        case .gpu: "Neural Engine 이 없는 Mac 이나 비교용. 전력을 더 씁니다."
        case .cpu: "비교용. CPU 사용량이 크게 늘어납니다."
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
        case .linear: "선형 회귀"
        case .curve: "곡선 회귀 (3차)"
        case .piecewise: "점별 보간"
        case .formula: "기본 추정식"
        }
    }

    var detail: String {
        switch self {
        case .linear: "x = 평균 + Σ 기울기 × 특징. 가장 단순하고 안정적."
        case .curve: "특징의 세제곱 항을 더해 화면 양 끝으로 갈수록 휘는 관계(고개를 돌린 각도 ↔ 위치)까지 맞춥니다. 보정 점이 적으면 과적합될 수 있음."
        case .piecewise: "선형 회귀가 각 보정 점에서 낸 값을 그 점의 실제 위치로 다시 맞추고, 점 사이는 직선으로 잇습니다."
        case .formula: "보정 없이 쓰는 대략적인 식 (카메라가 모니터 위 가운데, 정면 약 70cm 가정)."
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

    var title: String { kind?.title ?? "자동 (오차가 가장 작은 모델)" }
}
