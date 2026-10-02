import Foundation
import Testing
@testable import GazeNotification

/// 프로필·제한값·전원 규칙·CPU 상한·기록
@Suite("성능 프로필과 전원")
struct PerformanceTests {
    static let presets: [PerformanceLimits] = [.performance, .balanced, .saver]

    @Test("프로필 고유값은 모두 허용 범위 안", arguments: presets)
    func presetsWithinRanges(limits: PerformanceLimits) {
        #expect(limits.sanitized == limits)
        #expect(limits.activeHz >= limits.stillHz)
        #expect(limits.stillHz >= limits.awayHz)
    }

    @Test("프로필은 성능 우선 > 균형 > 절전 순으로 가볍다")
    func presetsOrdered() {
        let p = PerformanceLimits.performance, b = PerformanceLimits.balanced, s = PerformanceLimits.saver
        #expect(p.activeInferencesPerSecond > b.activeInferencesPerSecond)
        #expect(b.activeInferencesPerSecond > s.activeInferencesPerSecond)
        #expect(p.notificationCheckHz > b.notificationCheckHz && b.notificationCheckHz > s.notificationCheckHz)
        #expect(p.detectionInterval <= b.detectionInterval && b.detectionInterval <= s.detectionInterval)
    }

    @Test("저장값 바로잡기: 범위 밖 값을 안으로")
    func sanitizedClamps() {
        var limits = PerformanceLimits.balanced
        limits.activeHz = 100
        limits.stillHz = -1
        limits.awayHz = 0
        limits.detectionInterval = 0
        limits.notificationCheckHz = 1000
        limits.cpuLimit = -5
        limits.cameraOffAfterAway = 99
        let fixed = limits.sanitized
        #expect(fixed.activeHz == PerformanceLimits.activeRange.upperBound)
        #expect(fixed.stillHz == PerformanceLimits.stillRange.lowerBound)
        #expect(fixed.awayHz == PerformanceLimits.awayRange.lowerBound)
        #expect(fixed.detectionInterval == 1)
        #expect(fixed.notificationCheckHz == PerformanceLimits.notificationCheckRange.upperBound)
        #expect(fixed.cpuLimit == 0)
        #expect(fixed.cameraOffAfterAway == PerformanceLimits.cameraOffRange.upperBound)
    }

    @Test("예상 추론 횟수 = 처리 × (1 + 1/검출 간격)")
    func inferenceEstimate() {
        var limits = PerformanceLimits.balanced
        limits.activeHz = 6
        limits.detectionInterval = 3
        #expect(abs(limits.activeInferencesPerSecond - 8) < 1e-12)
    }

    // MARK: - 자동 프로필 규칙

    struct AutoCase: CustomTestStringConvertible, Sendable {
        var power: PowerState
        var expected: PerformanceProfile
        var reasonContains: String
        var testDescription: String { "\(power.powerText) LPM=\(power.lowPowerMode) 발열=\(power.thermalText) → \(expected.title)" }
    }

    static let autoCases: [AutoCase] = [
        AutoCase(power: PowerState(), expected: .balanced, reasonContains: "전원 연결"),
        AutoCase(power: PowerState(onBattery: true, batteryLevel: 64), expected: .saver, reasonContains: "64%"),
        AutoCase(power: PowerState(onBattery: true), expected: .saver, reasonContains: "배터리"),
        AutoCase(power: PowerState(lowPowerMode: true), expected: .saver, reasonContains: "저전력"),
        AutoCase(power: PowerState(thermal: .serious), expected: .saver, reasonContains: "발열"),
        AutoCase(power: PowerState(thermal: .critical), expected: .saver, reasonContains: "발열"),
        AutoCase(power: PowerState(thermal: .fair), expected: .balanced, reasonContains: "전원 연결"),
        AutoCase(power: PowerState(onBattery: true, lowPowerMode: true), expected: .saver, reasonContains: "저전력"),
    ]

    @Test("자동: 전원 연결 → 균형, 배터리·저전력 모드·발열 → 절전", arguments: autoCases)
    func automaticChoice(_ testCase: AutoCase) throws {
        let policy = EffectivePolicy.resolve(selected: .automatic, custom: .performance, power: testCase.power)
        #expect(policy.applied == testCase.expected)
        #expect(policy.selected == .automatic)
        #expect(policy.limits == testCase.expected.presetLimits)
        let reason = try #require(policy.reason)
        #expect(reason.contains(testCase.reasonContains))
    }

    @Test("고정 프로필은 전원 상태와 무관", arguments: [PerformanceProfile.performance, .balanced, .saver])
    func fixedProfiles(profile: PerformanceProfile) {
        for power in [PowerState(), PowerState(onBattery: true, lowPowerMode: true, thermal: .critical)] {
            let policy = EffectivePolicy.resolve(selected: profile, custom: .saver, power: power)
            #expect(policy.applied == profile)
            #expect(policy.limits == profile.presetLimits)
            #expect(policy.reason == nil)
        }
    }

    @Test("사용자 지정은 저장값을 바로잡아 쓴다")
    func customProfile() {
        var custom = PerformanceLimits.balanced
        custom.activeHz = 42
        let policy = EffectivePolicy.resolve(selected: .custom, custom: custom, power: PowerState(onBattery: true))
        #expect(policy.applied == .custom)
        #expect(policy.limits.activeHz == PerformanceLimits.activeRange.upperBound)
        #expect(PerformanceProfile.custom.presetLimits == nil && PerformanceProfile.automatic.presetLimits == nil)
    }

    @Test("전원 상태 글자")
    func powerTexts() {
        #expect(PowerState().powerText == "전원 연결")
        #expect(PowerState(batteryLevel: 80).powerText == "전원 연결 (80%)")
        #expect(PowerState(onBattery: true, batteryLevel: 31).powerText == "배터리 31%")
        #expect(PowerState(thermal: .serious).thermalText == "높음")
    }

    // MARK: - 추적 단계

    @Test("단계별 처리 횟수")
    func trackingRates() {
        let limits = PerformanceLimits.balanced
        #expect(TrackingRate.live.baseHz(limits) == TrackingRate.liveHz)
        #expect(TrackingRate.normal.baseHz(limits) == limits.activeHz)
        #expect(TrackingRate.still.baseHz(limits) == limits.stillHz)
        #expect(TrackingRate.away.baseHz(limits) == limits.awayHz)
        #expect(TrackingRate.paused.baseHz(limits) == 0)
        // 보정은 점당 6개 이상 샘플이 필요 → 실시간 속도는 1.6초에 6개 넘게
        #expect(TrackingRate.liveHz * 1.6 >= 6 * 1.5)
    }

    // MARK: - CPU 상한

    /// 처리 횟수에 비례하는 가짜 CPU: 바닥 비용 + 처리 1회당 비용
    private func simulate(limit: Double, floor: Double, perHz: Double, hz: Double = 5, seconds: Int = 90) -> (scale: Double, cpu: Double) {
        var governor = CPUGovernor()
        var cpu = 0.0
        for _ in 0..<seconds {
            cpu = floor + perHz * hz * governor.scale
            _ = governor.update(.measured(cpu), limit: limit)
        }
        return (governor.scale, cpu)
    }

    @Test("CPU 상한: 상한 근처(70~105%)로 수렴")
    func governorConverges() {
        let result = simulate(limit: 4, floor: 1.5, perHz: 1.2)
        #expect(result.cpu <= 4 * 1.05)
        #expect(result.cpu >= 4 * 0.6)
        #expect(result.scale < 1)
    }

    @Test("CPU 상한: 이미 상한 아래면 줄이지 않는다")
    func governorIdleWhenUnderLimit() {
        let result = simulate(limit: 50, floor: 1, perHz: 1)
        #expect(result.scale == 1)
    }

    @Test("CPU 상한: 바닥 비용보다 낮으면 최소 비율까지만")
    func governorFloor() {
        let result = simulate(limit: 1, floor: 1.5, perHz: 1.2)
        #expect(result.scale == CPUGovernor.minScale)
    }

    @Test("CPU 상한: 끄면 1 로, 실시간 중에는 유지, 바뀌었을 때만 true")
    func governorInputs() {
        var governor = CPUGovernor()
        do { let result = governor.update(.measured(20), limit: 5); #expect(result == true) }
        let reduced = governor.scale
        #expect(reduced < 1)
        do { let result = governor.update(.hold, limit: 5); #expect(result == false) }
        #expect(governor.scale == reduced)
        do { let result = governor.update(.off, limit: 5); #expect(result == true) }
        #expect(governor.scale == 1)
        do { let result = governor.update(.off, limit: 5); #expect(result == false) }
        do { let result = governor.update(.measured(20), limit: 0); #expect(result == false) }   // 상한 0 = 제한 없음
        #expect(governor.scale == 1)
    }

    @Test("CPU 상한: 여유가 생기면 천천히(15%씩) 되돌린다")
    func governorRecovers() {
        var governor = CPUGovernor()
        for _ in 0..<10 { _ = governor.update(.measured(40), limit: 5) }
        // 지수 평균이 상한의 70% 아래로 내려올 때까지
        for _ in 0..<8 { _ = governor.update(.measured(0.1), limit: 5) }
        let before = governor.scale
        #expect(before < 1)
        _ = governor.update(.measured(0.1), limit: 5)
        #expect(abs(governor.scale - min(1, before * 1.15)) < 1e-12)
        for _ in 0..<100 { _ = governor.update(.measured(0.1), limit: 5) }
        #expect(governor.scale == 1)
    }

    // MARK: - 기록

    @Test("기록은 최근 600개만, 번호는 계속 늘어난다")
    func historyCapacity() {
        var history = PerformanceHistory()
        for _ in 0..<700 {
            history.append { id in
                PerformanceSample(id: id, time: Date(), processCPU: 1, trackingCPU: 1, mainCPU: 0, processedHz: 5, detectHz: 1,
                                  receivedFPS: 5, targetHz: 5, detectMs: 10, landmarksMs: 5, notificationChecksPerSecond: 10,
                                  axCallsPerSecond: 0, rate: .normal, profile: .balanced, governorScale: 1, analysisMode: .precise)
            }
        }
        #expect(history.samples.count == PerformanceHistory.capacity)
        #expect(history.samples.first?.id == 100)
        #expect(history.samples.last?.id == 699)
        #expect(zip(history.samples, history.samples.dropFirst()).allSatisfy { $1.id == $0.id + 1 })
    }

    @Test("CPU 시간: 일을 하면 늘어나고, 스레드 시간은 프로세스 시간 이하")
    func cpuClock() {
        let process0 = CPUClock.process()
        let port = CPUClock.currentThreadPort()
        let thread0 = CPUClock.thread(port)
        var x = 0.0
        for i in 0..<2_000_000 { x += sin(Double(i)) }
        #expect(x.isFinite)
        let process1 = CPUClock.process(), thread1 = CPUClock.thread(port)
        #expect(process1 > process0)
        #expect(thread1 > thread0)
        #expect(thread1 - thread0 <= process1 - process0 + 0.01)
    }
}
