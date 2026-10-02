import Foundation

/// UI 테스트용 가상 카메라: 실제 카메라·Vision 대신 "가상 사용자"의 얼굴 특징을 만든다.
///
/// 가상 사용자는 `lookTarget` 이 있으면 그 점을 보고(보정 중에는 화면의 점), 없으면 화면을 좌우로 천천히 오간다.
/// 특징은 실제 측정에서 본 관계를 흉내 낸다: 머리 yaw = −atan(2.4·(x−0.5))·0.8, 코 방향 ≈ yaw/2 (실측에서 둘의 부호가 같음),
/// 동공은 남은 눈 움직임. 오른쪽을 볼수록 코·동공·yaw 값은 작아진다 (`FaceFeatures` 의 부호 규칙).
/// 여러 스레드에서 쓰므로 바뀌는 값은 잠금으로 보호한다.
final class SimulatedFaceSource: @unchecked Sendable {
    static let deviceName = "가상 카메라 (UI 테스트)"
    /// C922 와 같은 지원 fps
    static let supportedFPS: [Double] = [5, 7.5, 10, 15, 20, 24, 30]

    private let lock = NSLock()
    private var target: Double?
    private var faceVisible = true

    /// 가상 사용자가 바라볼 화면 가로 위치 (nil = 좌우로 천천히 왕복)
    var lookTarget: Double? {
        get { lock.withLock { target } }
        set { lock.withLock { target = newValue } }
    }

    /// false 면 얼굴이 안 보이는 것처럼 (자리 비움 시험용)
    var isFaceVisible: Bool {
        get { lock.withLock { faceVisible } }
        set { lock.withLock { faceVisible = newValue } }
    }

    func gaze(at time: TimeInterval) -> Double {
        lookTarget ?? 0.5 + 0.4 * sin(time * 0.6)
    }

    /// 한 프레임 처리 결과 (단계별 시간도 실제와 비슷한 값으로 채운다)
    func extraction(at time: TimeInterval, mode: AnalysisMode, computeAllModes: Bool, detected: Bool) -> Extraction {
        var timing = StageTiming()
        if detected || mode == .headPose { timing.detect = .init(count: 1, wall: 0.012, cpu: 0.009) }
        guard isFaceVisible else { return Extraction(features: nil, timing: timing) }
        if mode != .headPose { timing.landmarks = .init(count: computeAllModes ? 2 : 1, wall: 0.006, cpu: 0.005) }
        timing.features = .init(count: 1, wall: 0.0001, cpu: 0.0001)

        var features = Self.features(gaze: gaze(at: time), time: time, mode: mode)
        if computeAllModes {
            features.modeVectors = Dictionary(uniqueKeysWithValues: AnalysisMode.allCases.map { other in
                (other, Self.features(gaze: gaze(at: time), time: time, mode: other).vector)
            })
        }
        return Extraction(features: features, timing: timing)
    }

    /// 화면 가로 위치 → 그 위치를 보는 사람의 특징 (작은 흔들림 포함)
    static func features(gaze x: Double, time: TimeInterval, mode: AnalysisMode) -> FaceFeatures {
        let c = x - 0.5
        let wobble = sin(time * 7.3) * 0.004
        let yaw = -atan(c * 2.4) * 0.8 + wobble
        let faceX = 0.55 + sin(time * 0.37) * 0.005
        if mode == .headPose {
            return FaceFeatures(timestamp: time, faceX: faceX, faceWidth: 0.18, noseOffset: .nan, pupilOffset: nil, yaw: yaw)
        }
        let nose = yaw / 2 + sin(time * 5.1) * 0.003
        let pupil = -c * 0.15 + sin(time * 3.7) * 0.004
        return FaceFeatures(timestamp: time, faceX: faceX, faceWidth: 0.18, noseOffset: nose, pupilOffset: pupil, yaw: yaw)
    }
}
