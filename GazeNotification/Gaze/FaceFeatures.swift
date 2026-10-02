import Foundation

/// 한 프레임에서 뽑은 시선 관련 특징. 모든 값은 **미러링되지 않은** 카메라 원본 기준.
///
/// 카메라가 사용자를 마주 보므로, 사용자가 자기 왼쪽(모니터 왼편)을 보면
/// 코/동공은 이미지의 오른쪽(+x)으로 이동한다 → 값이 커질수록 화면 왼쪽을 보는 것.
struct FaceFeatures: Sendable {
    var timestamp: TimeInterval
    /// 얼굴 bounding box 중심 x (0...1, 이미지 좌측=0)
    var faceX: Double
    /// 얼굴 bounding box 폭 (0...1). 카메라와의 거리 추정용.
    var faceWidth: Double
    /// (코끝.x − 두 눈 중점.x) / 눈 사이 거리 — 머리 좌우 회전(yaw) 근사치. 머리 방향 방식에서는 NaN
    var noseOffset: Double
    /// 양쪽 (동공.x − 눈 중심.x) / 눈 폭 의 평균. 눈을 감았거나 검출 실패면 nil
    var pupilOffset: Double?
    /// Vision 이 추정한 yaw (라디안). 없으면 nil
    var yaw: Double?
    /// 보정 중에만: 같은 프레임에서 계산한 분석 방식별 특징 벡터
    var modeVectors: [AnalysisMode: [Double]]?

    static let featureNames = ["nose", "pupil", "faceX", "yaw"]

    /// 회귀 모델 입력 벡터. 결측값은 NaN.
    var vector: [Double] {
        [noseOffset, pupilOffset ?? .nan, faceX, yaw ?? .nan]
    }
}
