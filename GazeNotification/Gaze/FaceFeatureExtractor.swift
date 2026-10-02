import CoreGraphics
import CoreML
import CoreVideo
import QuartzCore
import Vision

/// Vision 으로 얼굴 → 랜드마크(눈, 동공, 코)를 검출해 `FaceFeatures` 로 변환.
/// 비디오 큐 한 곳에서만 사용한다 (스레드 안전하지 않음).
///
/// 신경망 단계는 Neural Engine(없으면 GPU)에 고정해 CPU 사용을 줄인다.
final class FaceFeatureExtractor {
    /// 단계별 실행 장치 (예: "VNComputeStageMain:ANE")
    let detectionDevice: String
    let landmarksDevice: String

    private let rectanglesRequest = VNDetectFaceRectanglesRequest()
    private let landmarksRequest: VNDetectFaceLandmarksRequest = {
        let request = VNDetectFaceLandmarksRequest()
        request.constellation = .constellation76Points
        return request
    }()

    init() {
        detectionDevice = Self.preferNeuralEngine(rectanglesRequest)
        landmarksDevice = Self.preferNeuralEngine(landmarksRequest)
        Log.info("Vision 연산 장치: 얼굴검출=\(detectionDevice) 랜드마크=\(landmarksDevice)")
    }

    /// 요청의 각 단계(main/postProcessing)를 Neural Engine > GPU 순으로 지정. 설정 결과를 문자열로 반환.
    private static func preferNeuralEngine(_ request: VNRequest) -> String {
        guard let stages = try? request.supportedComputeStageDevices else { return "기본" }
        var chosen: [String] = []
        for (stage, devices) in stages.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let ane = devices.first { if case .neuralEngine(_) = $0 { true } else { false } }
            let gpu = devices.first { if case .gpu(_) = $0 { true } else { false } }
            guard let device = ane ?? gpu else {
                chosen.append("\(stage.rawValue):CPU")
                continue
            }
            request.setComputeDevice(device, for: stage)
            chosen.append("\(stage.rawValue):\(ane != nil ? "ANE" : "GPU")")
        }
        return chosen.joined(separator: ",")
    }

    /// 눈 높이/폭 비율이 이보다 작으면 감은 것으로 보고 동공 값을 버린다.
    private let minEyeOpenness: CGFloat = 0.12

    /// 한 프레임 처리: ① 얼굴 검출 → ② 랜드마크 → ③ 특징 계산. 단계별 소요 시간도 함께 돌려준다.
    func extract(from pixelBuffer: CVPixelBuffer, timestamp: TimeInterval) -> Extraction {
        var timing = StageTiming()
        let imageSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                               height: CVPixelBufferGetHeight(pixelBuffer))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        // ① 얼굴 검출: 이미지 전체에서 얼굴 상자 + 머리 방향(yaw/roll/pitch)
        let detected: Bool = timing.measure(\.detect) { (try? handler.perform([rectanglesRequest])) != nil }
        // 가장 큰(=가장 가까운) 얼굴 하나만 추적
        guard detected,
              let face = rectanglesRequest.results?.max(by: { $0.boundingBox.area < $1.boundingBox.area }) else {
            return Extraction(features: nil, timing: timing)
        }

        // ② 랜드마크: 검출 결과를 넘겨 얼굴 검출을 다시 하지 않고, 얼굴 상자 안에서 76개 점만 찾는다
        landmarksRequest.inputFaceObservations = [face]
        let landmarked: Bool = timing.measure(\.landmarks) { (try? handler.perform([landmarksRequest])) != nil }
        guard landmarked, let observation = landmarksRequest.results?.first else {
            return Extraction(features: nil, timing: timing)
        }

        // ③ 특징 계산 (CPU)
        let features = timing.measure(\.features) {
            self.features(from: observation, face: face, imageSize: imageSize, timestamp: timestamp)
        }
        return Extraction(features: features, timing: timing)
    }

    private func features(from observation: VNFaceObservation, face: VNFaceObservation,
                          imageSize: CGSize, timestamp: TimeInterval) -> FaceFeatures? {
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

        return FaceFeatures(
            timestamp: timestamp,
            faceX: Double(observation.boundingBox.midX),
            faceWidth: Double(observation.boundingBox.width),
            noseOffset: noseOffset,
            pupilOffset: pupilOffsets.isEmpty ? nil : pupilOffsets.reduce(0, +) / Double(pupilOffsets.count),
            yaw: face.yaw?.doubleValue
        )
    }
}

struct Extraction {
    var features: FaceFeatures?
    var timing: StageTiming
}

/// 한 프레임의 단계별 소요 시간 (초). wall = 실제 경과(ANE 대기 포함), cpu = 이 스레드가 쓴 CPU.
struct StageTiming: Sendable {
    struct Stage: Sendable {
        var ran = false
        var wall: Double = 0
        var cpu: Double = 0
    }

    var detect = Stage()
    var landmarks = Stage()
    var features = Stage()

    mutating func measure<T>(_ stage: WritableKeyPath<StageTiming, Stage>, _ body: () -> T) -> T {
        let wallStart = CACurrentMediaTime()
        let cpuStart = threadCPUTime()
        let result = body()
        self[keyPath: stage] = Stage(ran: true, wall: CACurrentMediaTime() - wallStart, cpu: threadCPUTime() - cpuStart)
        return result
    }
}

/// 현재 스레드가 쓴 CPU 시간(초)
func threadCPUTime() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
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
