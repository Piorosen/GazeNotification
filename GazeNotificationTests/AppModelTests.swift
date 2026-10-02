import Foundation
import Testing
@testable import GazeNotification

/// 앱 상태: 설정 전환·저장·불러오기·보정 적용 (테스트마다 새 설정 저장소, 카메라는 시작하지 않음)
@Suite("앱 상태와 설정 저장", .serialized)
@MainActor
struct AppModelTests {
    /// 테스트 하나가 쓰는 빈 설정 저장소
    final class Store {
        let name = "party.udon.GazeNotification.unittest.\(UUID().uuidString)"
        lazy var defaults = UserDefaults(suiteName: name)!
        deinit { UserDefaults().removePersistentDomain(forName: name) }
    }

    private func makeModel(_ store: Store) -> AppModel {
        AppModel(defaults: store.defaults, simulation: nil)
    }

    private func simulatedSet() -> CalibrationSet {
        CalibrationSet.fit(samples: GazeEstimatorTests.simulatedSamples(), targets: CalibrationPlan.evenTargets(5))
    }

    @Test("처음 실행: 자동 프로필 · 기본 보정값 · 정밀 76점 · 자동 모델 · 보정 없음")
    func defaults() {
        let store = Store()
        let model = makeModel(store)
        #expect(model.profile == .automatic)
        #expect(model.adjustment == GazeAdjustment())
        #expect(model.analysisMode == .precise)
        #expect(model.estimatorChoice == .automatic)
        #expect(model.computePreference == .automatic)
        #expect(model.calibration == nil)
        #expect(model.activeEstimatorKind == .formula)
        #expect(model.activeEstimator == nil)
        #expect(model.calibrationPointCount == 5)
        #expect(model.calibrationSeconds == 1.6)
        #expect(model.isEnabled)
        #expect(model.placementSource == .gaze)
    }

    @Test("제한값을 바꾸면 지금 값에서 시작하는 사용자 지정으로 바뀌고 저장된다")
    func editLimitsSwitchesToCustom() {
        let store = Store()
        let model = makeModel(store)
        model.profile = .saver
        let before = model.limits
        model.editLimits { $0.activeHz = 7 }
        #expect(model.profile == .custom)
        #expect(model.limits.activeHz == 7)
        var expected = before
        expected.activeHz = 7
        #expect(model.limits == expected)          // 나머지 값은 절전 프로필 그대로

        let reloaded = makeModel(store)
        #expect(reloaded.profile == .custom)
        #expect(reloaded.limits == expected)
    }

    @Test("범위 밖 제한값은 바로잡아 저장")
    func editLimitsClamps() {
        let store = Store()
        let model = makeModel(store)
        model.editLimits { $0.activeHz = 100; $0.detectionInterval = 0 }
        #expect(model.limits.activeHz == PerformanceLimits.activeRange.upperBound)
        #expect(model.limits.detectionInterval == 1)
    }

    @Test("프로필을 바꾸면 그 프로필 값이 적용된다", arguments: [PerformanceProfile.performance, .balanced, .saver])
    func profileApplies(profile: PerformanceProfile) {
        let store = Store()
        let model = makeModel(store)
        model.profile = profile
        #expect(model.policy.applied == profile)
        #expect(model.limits == profile.presetLimits)
        #expect(makeModel(store).profile == profile)
    }

    @Test("수동 보정값·AI 모드·보정 방식은 저장되고 다시 불러온다")
    func persistence() {
        let store = Store()
        let model = makeModel(store)
        var adjustment = GazeAdjustment()
        adjustment.offset = -0.12
        adjustment.rightGain = 1.4
        adjustment.featureGains = [1, 0.25, 1, 1.5]
        adjustment.zones = 4
        model.adjustment = adjustment
        model.analysisMode = .headPose
        model.estimatorChoice = .curve
        model.computePreference = .gpu
        model.calibrationPointCount = 7
        model.calibrationSeconds = 2.2
        model.showOverlayWhileAdjusting = false

        let reloaded = makeModel(store)
        #expect(reloaded.adjustment == adjustment)
        #expect(reloaded.analysisMode == .headPose)
        #expect(reloaded.estimatorChoice == .curve)
        #expect(reloaded.computePreference == .gpu)
        #expect(reloaded.calibrationPointCount == 7)
        #expect(reloaded.calibrationSeconds == 2.2)
        #expect(reloaded.showOverlayWhileAdjusting == false)
    }

    @Test("새 보정을 적용하면 저장되고, 이전 위치 조정은 초기화(가중치는 유지)")
    func applyCalibration() throws {
        let store = Store()
        let model = makeModel(store)
        var adjustment = GazeAdjustment()
        adjustment.offset = 0.1
        adjustment.leftGain = 1.6
        adjustment.featureGains = [1, 0.5, 1, 1]
        model.adjustment = adjustment

        let set = simulatedSet()
        model.applyCalibration(set)
        #expect(model.calibration == set)
        #expect(model.adjustment.isPositionDefault)
        #expect(model.adjustment.featureGains == [1, 0.5, 1, 1])
        #expect(model.activeEstimatorKind == set.bestKind(for: .precise))
        #expect(model.activeEstimator != nil)

        let reloaded = makeModel(store)
        #expect(reloaded.calibration?.models == set.models)
        #expect(reloaded.calibration?.samples.count == set.samples.count)
    }

    @Test("고른 모델이 학습되지 않았으면 기본 추정식으로")
    func estimatorFallback() throws {
        let store = Store()
        let model = makeModel(store)
        let legacy = try #require(GazeCalibration.fit(GazeEstimatorTests.rows(GazeEstimatorTests.simulatedSamples(), .precise)))
        model.applyCalibration(.migrated(from: legacy))     // 정밀·선형만 있음

        model.estimatorChoice = .linear
        #expect(model.activeEstimatorKind == .linear)
        model.estimatorChoice = .curve
        #expect(model.activeEstimatorKind == .formula)
        model.estimatorChoice = .automatic
        #expect(model.activeEstimatorKind == .linear)
        model.analysisMode = .headPose
        #expect(model.activeEstimatorKind == .formula)
        model.estimatorChoice = .formula
        #expect(model.activeEstimator == nil)
    }

    @Test("모든 방식으로 학습한 보정이면 어느 방식이든 학습 모델을 쓴다", arguments: AnalysisMode.allCases)
    func everyModeHasModel(mode: AnalysisMode) {
        let store = Store()
        let model = makeModel(store)
        model.applyCalibration(simulatedSet())
        model.analysisMode = mode
        #expect(model.activeEstimator != nil)
        #expect(model.activeEstimatorKind != .formula)
    }

    @Test("예전 버전 보정(calibration.v1)을 불러와 옮긴다")
    func legacyCalibrationLoads() throws {
        let store = Store()
        let legacy = try #require(GazeCalibration.fit(GazeEstimatorTests.rows(GazeEstimatorTests.simulatedSamples(), .precise)))
        store.defaults.set(try JSONEncoder().encode(legacy), forKey: "calibration.v1")
        let model = makeModel(store)
        #expect(model.calibration?.estimator(.precise, .linear)?.regression == legacy)
        #expect(model.activeEstimatorKind == .linear)
    }

    @Test("손상된 저장값은 무시하고 기본값으로")
    func corruptDataIgnored() {
        let store = Store()
        store.defaults.set(Data("not json".utf8), forKey: "calibration.v2")
        store.defaults.set(Data([0xFF, 0x00]), forKey: "gaze.adjustment")
        store.defaults.set(Data("{}".utf8), forKey: "performance.customLimits")
        store.defaults.set("nonsense", forKey: "ai.analysisMode")
        store.defaults.set("nonsense", forKey: "performance.profile")
        store.defaults.set(99, forKey: "calibration.points")
        let model = makeModel(store)
        #expect(model.calibration == nil)
        #expect(model.adjustment == GazeAdjustment())
        #expect(model.customLimits == PerformanceLimits.balanced)
        #expect(model.analysisMode == .precise)
        #expect(model.profile == .automatic)
        #expect(model.calibrationPointCount == 9)
    }

    @Test("보정 초기화는 저장된 보정(새·예전 형식)을 모두 지운다")
    func resetCalibration() {
        let store = Store()
        let model = makeModel(store)
        model.applyCalibration(simulatedSet())
        store.defaults.set(Data("x".utf8), forKey: "calibration.v1")
        model.resetCalibration()
        #expect(model.calibration == nil)
        #expect(store.defaults.data(forKey: "calibration.v2") == nil)
        #expect(store.defaults.data(forKey: "calibration.v1") == nil)
        #expect(makeModel(store).calibration == nil)
    }

    @Test("수동 보정값 모두 초기화")
    func resetAdjustment() {
        let store = Store()
        let model = makeModel(store)
        model.adjustment.offset = 0.2
        model.adjustment.zones = 3
        model.resetAdjustment()
        #expect(model.adjustment == GazeAdjustment())
        #expect(makeModel(store).adjustment == GazeAdjustment())
    }

    @Test("설정 창 탭: 보정 조정 탭이 보일 때만 '조정 중'")
    func adjustingState() {
        let store = Store()
        let model = makeModel(store)
        model.settingsTab = .calibration
        #expect(!model.isAdjusting)
        model.isSettingsVisible = true
        #expect(model.isAdjusting)
        model.settingsTab = .performance
        #expect(!model.isAdjusting)
        model.isSettingsVisible = false
    }

    @Test("메뉴 막대 아이콘: 꺼짐 → eye.slash")
    func menuBarSymbol() {
        let store = Store()
        let model = makeModel(store)
        model.isEnabled = false
        #expect(model.menuBarSymbol == "eye.slash")
    }
}
