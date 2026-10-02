import CoreGraphics
import CoreML
import CoreVideo
import QuartzCore
import Vision

/// Vision 으로 얼굴 → 랜드마크(눈, 동공, 코)를 검출해 `FaceFeatures` 로 변환.
/// 비디오 큐 한 곳에서만 사용한다 (스레드 안전하지 않음).
///
/// - 분석 방식(`mode`): 랜드마크 76점 / 65점 / 얼굴 검출만(머리 방향). 보정 중(`computeAllModes`)에는
///   한 프레임에서 세 방식의 특징을 모두 계산해, 보정 한 번으로 모든 방식의 모델을 학습할 수 있게 한다.
/// - 신경망 단계는 `ComputePreference` 에 따라 Neural Engine / GPU / CPU 에 고정한다.
/// - 랜드마크 방식에서는 전체 얼굴 검출을 `detectionInterval` 번에 1번만 한다. 그 사이 프레임은 직전 얼굴 상자를
///   눈 위치에 맞춰 옮겨 랜드마크 요청에 바로 넘긴다 (M4 Max 측정: 검출 1회 ≈ 프로세스 CPU 9ms + Neural Engine 대기 11ms).
///   랜드마크 신뢰도가 낮거나 얼굴이 화면 밖으로 나가면 그 프레임에서 바로 다시 검출한다.
///   머리 yaw 는 얼굴 검출만 계산하므로(랜드마크 결과는 넘긴 값을 그대로 복사) 추적 프레임은 마지막 검출 yaw 를 쓴다.
///   대신 코 방향이 검출 때보다 크게 바뀌면(고개를 돌림) 다음 프레임에서 바로 다시 검출한다.
///   (코 방향 변화로 yaw 를 보정해 보면 코 값의 프레임 간 흔들림 때문에 오히려 오차가 커졌다: 그대로 0.6~3° vs 보정 1.4~9.7°)
final class FaceFeatureExtractor {
    /// 요청별 실행 장치 (예: "ANE")
    private(set) var devices = VisionDevices()

    var mode: AnalysisMode = .precise {
        didSet { if mode != oldValue { tracked = nil } }
    }
    /// 보정 중: 모든 분석 방식의 특징 벡터를 함께 계산 (`FaceFeatures.modeVectors`)
    var computeAllModes = false
    /// N 번 처리마다 1번 전체 얼굴 검출 (1 = 매번). 머리 방향 방식은 항상 매번.
    var detectionInterval = 1

    private let rectanglesRequest = VNDetectFaceRectanglesRequest()
    private let landmarks76: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.constellation = .constellation76Points
        return request
    }()
    private let landmarks65: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.constellation = .constellation65Points
        return request
    }()

    /// 마지막 검출 결과와, 그때 얼굴 상자에 대한 눈의 상대 위치
    private struct TrackedFace {
        var detection: VNFaceObservation
        /// 두 눈 중점의 상자 안 상대 위치 (0...1)
        var eyeAnchor: CGPoint
        /// 눈 사이 거리 ÷ 상자 폭
        var eyeSpan: CGFloat
        /// 지금 쓰는 (옮겨진) 상자
        var current: VNFaceObservation
        /// 검출 프레임의 코 방향
        var noseOffset: Double
    }
    private var tracked: TrackedFace?
    private var framesSinceDetection = 0
    /// 추적 중인 프레임에서 이보다 랜드마크 신뢰도가 낮으면 다시 검출
    private let minTrackingConfidence: Float = 0.5
    /// 추적 중 코 방향이 검출 때보다 이만큼 바뀌면 다음 프레임에서 다시 검출 (화면 폭 기준 약 1/10)
    private let redetectNoseChange = 0.06

    init() {
        setComputePreference(.automatic)
    }

    /// 신경망 단계를 돌릴 장치를 바꾼다 (다음 요청부터 적용, 처음 한 번은 모델을 다시 불러와 느림)
    func setComputePreference(_ preference: ComputePreference) {
        devices = VisionDevices(preference: preference,
                                detection: Self.assign(rectanglesRequest, preference),
                                landmarks76: Self.assign(landmarks76, preference),
                                landmarks65: Self.assign(landmarks65, preference))
        Log.info("Vision 연산 장치(\(preference.title)): 얼굴검출=\(devices.detection) 랜드마크76=\(devices.landmarks76) 랜드마크65=\(devices.landmarks65)")
    }

    /// 요청의 각 단계에 선호 장치를 지정하고 결과를 "ANE" 처럼 돌려준다 (단계가 여럿이면 "ANE/CPU")
    private static func assign(_ request: VNRequest, _ preference: ComputePreference) -> String {
        guard let stages = try? request.supportedComputeStageDevices else { return "기본" }
        var chosen: [String] = []
        for (stage, available) in stages.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let device = preference.pick(from: available) else { continue }
            request.setComputeDevice(device, for: stage)
            switch device {
            case .neuralEngine: chosen.append("ANE")
            case .gpu: chosen.append("GPU")
            default: chosen.append("CPU")
            }
        }
        return chosen.isEmpty ? "기본" : chosen.joined(separator: "/")
    }

    /// 눈 높이/폭 비율이 이보다 작으면 감은 것으로 보고 동공 값을 버린다.
    private let minEyeOpenness: CGFloat = 0.12

    /// 한 프레임 처리: ① 얼굴 검출(또는 추적) → ② 랜드마크 → ③ 특징 계산. 단계별 소요 시간도 함께 돌려준다.
    func extract(from pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> Extraction {
        var timing = StageTiming()
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        // ① 얼굴 검출: 이미지 전체에서 얼굴 상자 + 머리 방향(yaw/roll/pitch). 가장 큰(=가장 가까운) 얼굴 하나만 추적
        func detect() -> VNFaceObservation? {
            framesSinceDetection = 0
            let ok: Bool = timing.measure(\.detect) { (try? handler.perform([rectanglesRequest])) != nil }
            guard ok else { return nil }
            return rectanglesRequest.results?.max(by: { $0.boundingBox.area < $1.boundingBox.area })
        }

        // ② 랜드마크: 얼굴 상자를 넘겨 그 안에서 점만 찾는다
        func landmarks(_ request: VNDetectFaceLandmarksRequest, in face: VNFaceObservation) -> VNFaceObservation? {
            request.inputFaceObservations = [face]
            let ok: Bool = timing.measure(\.landmarks) { (try? handler.perform([request])) != nil }
            return ok ? request.results?.first : nil
        }

        func noFace() -> Extraction {
            tracked = nil
            return Extraction(features: nil, timing: timing)
        }

        // 보정 중: 검출 결과 하나로 세 방식의 특징을 모두 계산
        func allModeVectors(detection: VNFaceObservation, current: FaceFeatures?) -> [AnalysisMode: [Double]] {
            var vectors: [AnalysisMode: [Double]] = [.headPose: headPoseFeatures(detection, timestamp: timestamp).vector]
            for other in [AnalysisMode.precise, .light] {
                if other == mode, let current {
                    vectors[other] = current.vector
                } else if let result = landmarks(other == .light ? landmarks65 : landmarks76, in: detection),
                          let computed = features(from: result, face: detection, imageSize: imageSize, timestamp: timestamp) {
                    vectors[other] = computed.features.vector
                }
            }
            return vectors
        }

        if mode == .headPose {
            guard let face = detect() else { return noFace() }
            var features = timing.measure(\.features) { headPoseFeatures(face, timestamp: timestamp) }
            if computeAllModes { features.modeVectors = allModeVectors(detection: face, current: features) }
            return Extraction(features: features, timing: timing)
        }

        let request = mode == .light ? landmarks65 : landmarks76
        var detection: VNFaceObservation?
        var observation: VNFaceObservation?
        if let tracked, framesSinceDetection + 1 < detectionInterval, !computeAllModes {
            framesSinceDetection += 1
            if let result = landmarks(request, in: tracked.current),
               (result.landmarks?.confidence ?? 0) >= minTrackingConfidence {
                observation = result
            }
        }
        if observation == nil {
            // 검출 차례이거나 추적이 놓침
            guard let face = detect() else { return noFace() }
            detection = face
            observation = landmarks(request, in: face)
        }
        guard let observation else { return noFace() }

        // ③ 특징 계산 (CPU)
        let computed = timing.measure(\.features) {
            self.features(from: observation, face: detection ?? tracked?.detection ?? observation,
                          imageSize: imageSize, timestamp: timestamp)
        }
        guard var computed else { return noFace() }
        if detection == nil, let tracked, abs(computed.features.noseOffset - tracked.noseOffset) > redetectNoseChange {
            framesSinceDetection = detectionInterval
        }
        updateTracking(detection: detection, features: computed.features, eyes: computed.eyes, imageSize: imageSize)
        if computeAllModes, let detection {
            computed.features.modeVectors = allModeVectors(detection: detection, current: computed.features)
        }
        return Extraction(features: computed.features, timing: timing)
    }

    /// 머리 방향 방식: 얼굴 상자 위치와 yaw 만 (코·동공 없음)
    private func headPoseFeatures(_ face: VNFaceObservation, timestamp: TimeInterval) -> FaceFeatures {
        FaceFeatures(timestamp: timestamp, faceX: Double(face.boundingBox.midX), faceWidth: Double(face.boundingBox.width),
                     noseOffset: .nan, pupilOffset: nil, yaw: face.yaw?.doubleValue)
    }

    /// 검출한 프레임에서는 상자와 눈의 관계를 기억하고, 추적 프레임에서는 그 관계대로 상자를 눈에 맞춰 옮긴다.
    private func updateTracking(detection: VNFaceObservation?, features: FaceFeatures, eyes: EyeGeometry, imageSize: CGSize) {
        let eyeMid = CGPoint(x: eyes.mid.x / imageSize.width, y: eyes.mid.y / imageSize.height)
        let span = eyes.interocular / imageSize.width
        if let detection {
            let box = detection.boundingBox
            guard box.width > 0, box.height > 0 else { tracked = nil; return }
            tracked = TrackedFace(detection: detection,
                                  eyeAnchor: CGPoint(x: (eyeMid.x - box.minX) / box.width, y: (eyeMid.y - box.minY) / box.height),
                                  eyeSpan: span / box.width, current: detection, noseOffset: features.noseOffset)
            return
        }
        guard var tracked, tracked.eyeSpan > 0 else { return }
        let width = span / tracked.eyeSpan
        let height = width * tracked.detection.boundingBox.height / max(tracked.detection.boundingBox.width, 1e-6)
        let box = CGRect(x: eyeMid.x - tracked.eyeAnchor.x * width, y: eyeMid.y - tracked.eyeAnchor.y * height,
                         width: width, height: height)
        // 상자가 이미지 밖으로 많이 나가면 다음 프레임에서 다시 검출
        guard box.width > 0.02, box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1)).area > box.area * 0.7 else {
            self.tracked = nil
            return
        }
        let d = tracked.detection
        tracked.current = VNFaceObservation(requestRevision: d.requestRevision, boundingBox: box,
                                            roll: d.roll, yaw: d.yaw, pitch: d.pitch)
        self.tracked = tracked
    }

    private struct EyeGeometry {
        /// 두 눈 중점 (이미지 픽셀, 원점 왼쪽 아래)
        var mid: CGPoint
        var interocular: CGFloat
    }

    private func features(from observation: VNFaceObservation, face: VNFaceObservation,
                          imageSize: CGSize, timestamp: TimeInterval) -> (features: FaceFeatures, eyes: EyeGeometry)? {
        guard let landmarks = observation.landmarks else { return nil }

        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint]? {
            guard let region, region.pointCount > 0 else { return nil }
            return region.pointsInImage(imageSize: imageSize)
        }

        guard let leftEye = points(landmarks.leftEye), let rightEye = points(landmarks.rightEye) else { return nil }

        let leftCenter = leftEye.centroid
        let rightCenter = rightEye.centroid
        // Vision 의 left/right 명명 규칙에 의존하지 않도록 x 좌표로 정렬
        let (eyeA, eyeB) = leftCenter.x <= rightCenter.x ? (leftCenter, rightCenter) : (rightCenter, leftCenter)
        let interocular = hypot(eyeB.x - eyeA.x, eyeB.y - eyeA.y)
        guard interocular > 4 else { return nil }

        // 고개 기울임(roll)을 보정해 눈을 잇는 선이 수평이 되는 좌표계로 회전
        let roll = atan2(eyeB.y - eyeA.y, eyeB.x - eyeA.x)
        let eyeMid = CGPoint(x: (eyeA.x + eyeB.x) / 2, y: (eyeA.y + eyeB.y) / 2)
        func level(_ v: CGPoint) -> CGPoint { v.rotated(by: -roll) }

        // 코끝: noseCrest(콧대) 중 가장 아래 점. 없으면 nose 영역 중심.
        let noseTip: CGPoint
        if let crest = points(landmarks.noseCrest), let tip = crest.min(by: { level($0).y < level($1).y }) {
            noseTip = tip
        } else if let nose = points(landmarks.nose) {
            noseTip = nose.centroid
        } else {
            return nil
        }
        let noseOffset = Double(level(noseTip - eyeMid).x / interocular)

        var pupilOffsets: [Double] = []
        for (eye, pupil) in [(leftEye, points(landmarks.leftPupil)), (rightEye, points(landmarks.rightPupil))] {
            guard let pupil = pupil?.first else { continue }
            let leveled = eye.map(level)
            let xs = leveled.map(\.x), ys = leveled.map(\.y)
            guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { continue }
            let width = maxX - minX
            guard width > 2, (maxY - minY) / width >= minEyeOpenness else { continue }
            let center = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
            pupilOffsets.append(Double((level(pupil).x - center.x) / width))
        }

        let features = FaceFeatures(
            timestamp: timestamp,
            faceX: Double(observation.boundingBox.midX),
            faceWidth: Double(observation.boundingBox.width),
            noseOffset: noseOffset,
            pupilOffset: pupilOffsets.isEmpty ? nil : pupilOffsets.reduce(0, +) / Double(pupilOffsets.count),
            // 추적 프레임이면 마지막 검출 때의 값
            yaw: face.yaw?.doubleValue
        )
        return (features, EyeGeometry(mid: eyeMid, interocular: interocular))
    }
}

/// 요청별로 실제 지정된 장치
struct VisionDevices: Equatable, Sendable {
    var preference: ComputePreference = .automatic
    var detection = "기본"
    var landmarks76 = "기본"
    var landmarks65 = "기본"

    func landmarks(for mode: AnalysisMode) -> String? {
        switch mode {
        case .precise: landmarks76
        case .light: landmarks65
        case .headPose: nil
        }
    }
}

struct Extraction {
    var features: FaceFeatures?
    var timing: StageTiming
}

/// 한 프레임의 단계별 소요 시간 (초, 같은 단계를 두 번 돌리면 합계).
/// wall = 실제 경과(ANE 대기 포함), cpu = 그동안 **프로세스 전체**가 쓴 CPU.
/// Vision 은 호출한 스레드가 아니라 자기 작업 스레드에서 계산하므로 스레드 CPU 로 재면 실제보다 훨씬 작게 나온다.
struct StageTiming: Sendable {
    struct Stage: Sendable {
        var count = 0
        var wall: Double = 0
        var cpu: Double = 0
        var ran: Bool { count > 0 }
    }

    var detect = Stage()
    var landmarks = Stage()
    var features = Stage()

    mutating func measure<T>(_ stage: WritableKeyPath<StageTiming, Stage>, _ body: () -> T) -> T {
        let wallStart = CACurrentMediaTime()
        let cpuStart = CPUClock.process()
        let result = body()
        self[keyPath: stage].count += 1
        self[keyPath: stage].wall += CACurrentMediaTime() - wallStart
        self[keyPath: stage].cpu += CPUClock.process() - cpuStart
        return result
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}

private extension Array where Element == CGPoint {
    var centroid: CGPoint {
        guard !isEmpty else { return .zero }
        let sum = reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(count), y: sum.y / CGFloat(count))
    }
}

private extension CGPoint {
    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }

    func rotated(by angle: CGFloat) -> CGPoint {
        CGPoint(x: x * cos(angle) - y * sin(angle), y: x * sin(angle) + y * cos(angle))
    }
}
