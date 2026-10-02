import CoreGraphics
import CoreML
import Foundation
import Testing
import Vision
@testable import GazeNotification

/// 얼굴 추적 상자·알림 위치 계산·AI 모드 정의·가상 카메라
@Suite("기하 계산과 AI 모드")
struct GeometryAndModeTests {
    // MARK: - 얼굴 추적 상자

    @Test("눈이 그대로면 검출 상자 그대로, 눈이 움직이면 같은 만큼 옮긴다")
    func trackedBoxFollowsEyes() throws {
        let detection = CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.25)
        let eyeMid = CGPoint(x: 0.5, y: 0.45)
        let anchor = CGPoint(x: (eyeMid.x - detection.minX) / detection.width, y: (eyeMid.y - detection.minY) / detection.height)
        let span: CGFloat = 0.08
        let same = try #require(FaceFeatureExtractor.trackedBox(eyeMid: eyeMid, eyeSpan: span, anchor: anchor,
                                                               spanRatio: span / detection.width, aspect: 1.25))
        #expect(abs(same.minX - detection.minX) < 1e-9 && abs(same.minY - detection.minY) < 1e-9)
        #expect(abs(same.width - detection.width) < 1e-9 && abs(same.height - detection.height) < 1e-9)

        let moved = try #require(FaceFeatureExtractor.trackedBox(eyeMid: CGPoint(x: 0.55, y: 0.43), eyeSpan: span, anchor: anchor,
                                                                spanRatio: span / detection.width, aspect: 1.25))
        #expect(abs(moved.minX - (detection.minX + 0.05)) < 1e-9)
        #expect(abs(moved.minY - (detection.minY - 0.02)) < 1e-9)
    }

    @Test("가까이 오면(눈 사이가 넓어지면) 상자도 커진다")
    func trackedBoxScales() throws {
        let box = try #require(FaceFeatureExtractor.trackedBox(eyeMid: CGPoint(x: 0.5, y: 0.5), eyeSpan: 0.16,
                                                              anchor: CGPoint(x: 0.5, y: 0.6), spanRatio: 0.4, aspect: 1.2))
        #expect(abs(box.width - 0.4) < 1e-9)
        #expect(abs(box.height - 0.48) < 1e-9)
    }

    @Test("이미지 밖으로 30% 넘게 나가거나 너무 작으면 nil (다음 프레임에 다시 검출)")
    func trackedBoxRejects() {
        #expect(FaceFeatureExtractor.trackedBox(eyeMid: CGPoint(x: 0.98, y: 0.5), eyeSpan: 0.08,
                                                anchor: CGPoint(x: 0.5, y: 0.6), spanRatio: 0.4, aspect: 1.2) == nil)
        #expect(FaceFeatureExtractor.trackedBox(eyeMid: CGPoint(x: 0.5, y: 0.5), eyeSpan: 0.004,
                                                anchor: CGPoint(x: 0.5, y: 0.6), spanRatio: 0.4, aspect: 1.2) == nil)
        #expect(FaceFeatureExtractor.trackedBox(eyeMid: CGPoint(x: 0.5, y: 0.5), eyeSpan: 0.08,
                                                anchor: CGPoint(x: 0.5, y: 0.6), spanRatio: 0, aspect: 1.2) == nil)
    }

    // MARK: - 알림 위치

    static let screen = CGRect(x: 0, y: 0, width: 7680, height: 2160)

    @Test("배너 가운데가 시선 위치에, 양 끝은 여백 안으로")
    func slotPositions() {
        let width: CGFloat = 344, margin: CGFloat = 16
        func slot(_ x: Double, screen: CGRect = Self.screen) -> CGFloat {
            NotificationMover.slotX(normalized: x, screen: screen, bannerWidth: width, edgeMargin: margin)
        }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 1e-9 }
        #expect(near(slot(0.5), 3840 - 172))
        #expect(near(slot(0), 16))
        #expect(near(slot(1), 7680 - 344 - 16))
        #expect(slot(-0.5) == slot(0))                       // 범위 밖 입력도 안전
        #expect(slot(1.7) == slot(1))
        let second = CGRect(x: 7680, y: 0, width: 2560, height: 1440)   // 오른쪽 두 번째 모니터
        #expect(near(slot(0, screen: second), 7680 + 16))
        #expect(near(slot(0.5, screen: second), 7680 + 1280 - 172))
    }

    @Test("배너가 슬롯에 멈추도록 창을 옮기는 x")
    func windowPosition() {
        // 창 오른쪽 끝 − 여백 − 배너 폭 = 슬롯
        let windowX = NotificationMover.windowX(slotX: 1000, rightMargin: 16, bannerWidth: 344, windowWidth: 7680)
        #expect(windowX + 7680 - 16 - 344 == 1000)
        // 원위치(창 x = 화면 왼쪽)일 때의 슬롯은 오른쪽 끝
        #expect(NotificationMover.windowX(slotX: 7680 - 16 - 344, rightMargin: 16, bannerWidth: 344, windowWidth: 7680) == 0)
    }

    @Test("화면이 배너보다 좁아도 뒤집히지 않는다")
    func tinyScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 300, height: 200)
        let x = NotificationMover.slotX(normalized: 0.5, screen: tiny, bannerWidth: 344, edgeMargin: 16)
        #expect(x == 16)
    }

    // MARK: - AI 모드 정의

    @Test("분석 방식별 특징과 랜드마크 종류")
    func analysisModes() {
        #expect(AnalysisMode.precise.features == GazeFeature.allCases)
        #expect(AnalysisMode.light.features == GazeFeature.allCases)
        #expect(AnalysisMode.headPose.features == [.faceX, .yaw])
        #expect(AnalysisMode.precise.constellation == .constellation76Points)
        #expect(AnalysisMode.light.constellation == .constellation65Points)
        #expect(AnalysisMode.headPose.constellation == nil)
        #expect(Set(AnalysisMode.allCases.map(\.title)).count == AnalysisMode.allCases.count)
    }

    @Test("모델 선택 ↔ 모델 종류")
    func estimatorChoices() {
        #expect(EstimatorChoice.automatic.kind == nil)
        for kind in EstimatorKind.allCases {
            #expect(EstimatorChoice(rawValue: kind.rawValue)?.kind == kind)
        }
        #expect(EstimatorChoice.allCases.count == EstimatorKind.allCases.count + 1)
    }

    @Test("연산 장치 선호 → 이 Mac 의 실제 장치")
    func computeDevicePick() throws {
        let devices = MLComputeDevice.allComputeDevices
        let cpu = try #require(ComputePreference.cpu.pick(from: devices))
        guard case .cpu = cpu else { Issue.record("CPU 를 골라야 함: \(cpu)"); return }
        let hasANE = devices.contains { if case .neuralEngine = $0 { true } else { false } }
        let hasGPU = devices.contains { if case .gpu = $0 { true } else { false } }
        let auto = try #require(ComputePreference.automatic.pick(from: devices))
        switch auto {
        case .neuralEngine: #expect(hasANE)
        case .gpu: #expect(!hasANE && hasGPU)
        default: #expect(!hasANE && !hasGPU)
        }
        if hasGPU, let gpu = ComputePreference.gpu.pick(from: devices) {
            guard case .gpu = gpu else { Issue.record("GPU 를 골라야 함"); return }
        }
        #expect(ComputePreference.neuralEngine.pick(from: []) == nil)
    }

    @Test("보정 점은 4%~96% 를 고르게")
    func evenTargets() {
        let five = CalibrationPlan.evenTargets(5)
        #expect(five.count == 5)
        for (a, b) in zip(five, [0.04, 0.27, 0.5, 0.73, 0.96]) { #expect(abs(a - b) < 1e-12) }
        let two = CalibrationPlan.evenTargets(1)
        #expect(two.count == 2 && abs(two[0] - 0.04) < 1e-12 && abs(two[1] - 0.96) < 1e-12)
        #expect(CalibrationPlan.evenTargets(9).count == 9)
    }

    @Test("표시 글자")
    func formatting() {
        #expect(formatFPS(30.00003) == "30")
        #expect(formatFPS(7.500001875) == "7.5")
        #expect(formatFPS(2.5) == "2.5")
        #expect(GazeFeature.nose.format(.nan) == "—")
        #expect(GazeFeature.yaw.format(.pi / 18) == "+10.0°")
        #expect(GazeFeature.pupil.format(-0.1234) == "-0.123")
    }

    // MARK: - 가상 카메라

    @Test("가상 사용자: 오른쪽을 볼수록 기본식 출력도 오른쪽", arguments: AnalysisMode.allCases)
    func simulatedFeaturesMonotonic(mode: AnalysisMode) {
        let outputs = stride(from: 0.0, through: 1.0, by: 0.1).map {
            DefaultGazeModel.predict(SimulatedFaceSource.features(gaze: $0, time: 0, mode: mode).vector, mode: mode)
        }
        #expect(zip(outputs, outputs.dropFirst()).allSatisfy { $1 > $0 })
    }

    @Test("가상 카메라: 머리 방향 방식은 코·동공 없음, 보정 중엔 세 방식 모두")
    func simulatedExtraction() throws {
        let source = SimulatedFaceSource()
        source.lookTarget = 0.27
        #expect(source.gaze(at: 123) == 0.27)
        let head = try #require(source.extraction(at: 1, mode: .headPose, computeAllModes: false, detected: true).features)
        #expect(head.noseOffset.isNaN && head.pupilOffset == nil && head.yaw != nil)
        let all = source.extraction(at: 1, mode: .precise, computeAllModes: true, detected: true)
        #expect(Set(all.features?.modeVectors.map { Array($0.keys) } ?? []) == Set(AnalysisMode.allCases))
        #expect(all.timing.landmarks.count == 2)
        let tracked = source.extraction(at: 1, mode: .precise, computeAllModes: false, detected: false)
        #expect(!tracked.timing.detect.ran && tracked.timing.landmarks.ran)
        source.lookTarget = nil
        #expect((0.1...0.9).contains(source.gaze(at: 0)))
    }

    @Test("가상 카메라: 얼굴이 안 보이면 특징 없음")
    func simulatedAbsence() {
        let source = SimulatedFaceSource()
        source.isFaceVisible = false
        let extraction = source.extraction(at: 0, mode: .precise, computeAllModes: false, detected: true)
        #expect(extraction.features == nil)
        #expect(extraction.timing.detect.ran)
    }
}
