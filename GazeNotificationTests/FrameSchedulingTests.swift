import CoreMedia
import Foundation
import Testing
@testable import GazeNotification

/// 카메라 프레임 처리 간격·프레임레이트 감시·장치 fps 선택
@Suite("카메라 프레임 스케줄링")
struct FrameSchedulingTests {
    /// 장치 fps 로 프레임을 흘려보내고(±10% 흔들림) 처리한 횟수/s 를 센다
    private func processedRate(targetHz: Double, deviceFPS: Double, seconds: Double = 120) -> Double {
        var throttle = FrameThrottle()
        throttle.setDeviceFPS(deviceFPS)
        throttle.setRate(targetHz)
        let start = 1000.0
        var time = start
        var processed = 0
        var i = 0
        while time < start + seconds {
            if throttle.shouldProcess(at: time) { processed += 1 }
            i += 1
            time += (1 / deviceFPS) * (1 + 0.1 * sin(Double(i) * 1.7))
        }
        return Double(processed) / seconds
    }

    struct RateCase: CustomTestStringConvertible, Sendable {
        var target: Double
        var device: Double
        var testDescription: String { "목표 \(target)회/s · 장치 \(device)fps" }
    }

    static let rateCases: [RateCase] = [
        .init(target: 5, device: 5), .init(target: 2.5, device: 5), .init(target: 1, device: 5),
        .init(target: 0.5, device: 5), .init(target: 3, device: 5), .init(target: 10, device: 10),
        .init(target: 5, device: 30), .init(target: 2.5, device: 30), .init(target: 12, device: 15),
    ]

    @Test("처리 횟수는 목표값 (장치 fps 와 무관, ±5%)", arguments: rateCases)
    func throttleMatchesTarget(_ c: RateCase) {
        let rate = processedRate(targetHz: c.target, deviceFPS: c.device)
        #expect(abs(rate - c.target) <= c.target * 0.05, "\(rate)")
    }

    @Test("목표가 장치 fps 보다 높으면 모든 프레임을 처리")
    func throttleCappedByDevice() {
        let rate = processedRate(targetHz: 10, deviceFPS: 5)
        #expect(abs(rate - 5) < 0.1)
    }

    @Test("30fps 로 풀려도(미리보기 버그) 처리 횟수는 늘지 않는다")
    func throttleIgnoresFrameRateBurst() {
        var throttle = FrameThrottle()
        throttle.setDeviceFPS(5)
        throttle.setRate(2.5)
        var processed = 0
        var time = 0.0
        for _ in 0..<(30 * 60) { // 60초 동안 30fps
            if throttle.shouldProcess(at: time) { processed += 1 }
            time += 1.0 / 30
        }
        #expect(abs(Double(processed) / 60 - 2.5) < 0.15)
    }

    @Test("목표가 빨라지면 다음 프레임을 바로 처리")
    func throttleSpeedUpImmediately() {
        var throttle = FrameThrottle()
        throttle.setDeviceFPS(5)
        throttle.setRate(0.2)                       // 5초에 1번
        do { let result = throttle.shouldProcess(at: 100); #expect(result) }
        do { let result = throttle.shouldProcess(at: 100.2); #expect(!result) }
        throttle.setRate(5)
        do { let result = throttle.shouldProcess(at: 100.4); #expect(result) }  // 원래라면 105초까지 기다림
        #expect(throttle.interval == 0.2)
    }

    @Test("처리 간격 최소값: 0 이나 음수 목표도 안전")
    func throttleExtremeRates() {
        var throttle = FrameThrottle()
        throttle.setRate(0)
        #expect(throttle.interval == 20)
        throttle.setRate(-3)
        #expect(throttle.interval == 20)
    }

    // MARK: - 프레임레이트 감시

    @Test("설정대로 오면 아무것도 하지 않는다")
    func watchdogQuietWhenNormal() {
        var watchdog = FrameRateWatchdog()
        watchdog.expectedFPS = 5
        for t in 0..<120 { do { let result = watchdog.check(received: Double.random(in: 4.5...5.5), at: Double(t)); #expect(!result) } }
        #expect(watchdog.fixes == 0)
    }

    @Test("두 번 연속(2초) 넘치면 다시 적용, 그 뒤 10초는 기다린다")
    func watchdogTriggersAfterTwoWindows() {
        var watchdog = FrameRateWatchdog()
        watchdog.expectedFPS = 5
        do { let result = watchdog.check(received: 30, at: 100); #expect(!result) }
        do { let result = watchdog.check(received: 30, at: 101); #expect(result) }
        #expect(watchdog.fixes == 1)
        do { let result = watchdog.check(received: 30, at: 102); #expect(!result) }
        do { let result = watchdog.check(received: 30, at: 105); #expect(!result) }
        do { let result = watchdog.check(received: 30, at: 112); #expect(result) }
        #expect(watchdog.fixes == 2)
    }

    @Test("세 번 고친 뒤에는 1분에 한 번만 (다른 앱이 카메라를 쓰는 경우)")
    func watchdogBacksOff() {
        var watchdog = FrameRateWatchdog()
        watchdog.expectedFPS = 5
        var fixes: [Double] = []
        for t in stride(from: 0.0, through: 300, by: 1) where watchdog.check(received: 30, at: t) { fixes.append(t) }
        #expect(fixes.count >= 4)
        #expect(fixes[1] - fixes[0] > 10 && fixes[1] - fixes[0] <= 12)
        #expect(fixes[3] - fixes[2] > 60)
    }

    @Test("살짝 넘치는 정도(1.4배+0.5 이하)나 감시 꺼짐은 무시, 설정을 바꾸면 처음부터")
    func watchdogThresholds() {
        var watchdog = FrameRateWatchdog()
        do { let result = watchdog.check(received: 30, at: 0); #expect(!result) }       // expectedFPS 0 = 감시 안 함
        do { let result = watchdog.check(received: 30, at: 1); #expect(!result) }
        watchdog.expectedFPS = 5
        do { let result = watchdog.check(received: 7.4, at: 2); #expect(!result) }
        do { let result = watchdog.check(received: 7.4, at: 3); #expect(!result) }
        do { let result = watchdog.check(received: 30, at: 4); #expect(!result) }
        watchdog.expectedFPS = 10                           // 넘친 횟수 초기화
        do { let result = watchdog.check(received: 30, at: 5); #expect(!result) }
        do { let result = watchdog.check(received: 30, at: 6); #expect(result) }
        watchdog.reset()
        #expect(watchdog.fixes == 0)
    }

    // MARK: - 장치 fps 선택

    /// C922 800x448 yuvs 가 실제로 알려 주는 범위 (각각 min == max)
    static let c922 = [30.00003000003, 24.00003840006144, 20, 15.000015000015, 10, 7.500001875000469, 5]
        .map { FrameRateRange(minRate: $0, maxRate: $0) }

    @Test("C922: 목표 이상에서 지원하는 가장 낮은 fps", arguments: [
        (0.1, 5.0), (2.5, 5.0), (5, 5), (6, 7.500001875000469), (12, 15.000015000015), (24, 24.00003840006144),
        (30, 30.00003000003), (40, 30.00003000003),
    ])
    func c922Rates(hz: Double, expected: Double) throws {
        let rate = try #require(FrameRateRange.deviceRate(for: hz, in: Self.c922))
        #expect(rate.fps == expected)
        // 고른 간격은 반드시 그 범위 안 (밖이면 AVFoundation 이 예외를 던져 앱이 죽는다)
        let range = try #require(Self.c922.first { $0.maxRate == expected })
        #expect(range.contains(rate.duration))
    }

    @Test("연속 범위(iPhone 1~30fps): 목표 그대로, 범위 밖이면 끝값")
    func continuousRange() throws {
        let iphone = [FrameRateRange(minRate: 1, maxRate: 30)]
        let mid = try #require(FrameRateRange.deviceRate(for: 2.5, in: iphone))
        #expect(mid.fps == 2.5)
        #expect(abs(mid.duration.seconds - 0.4) < 1e-6)
        #expect(iphone[0].contains(mid.duration))
        #expect(FrameRateRange.deviceRate(for: 0.5, in: iphone)?.fps == 1)
        #expect(FrameRateRange.deviceRate(for: 60, in: iphone)?.fps == 30)
    }

    @Test("지원 범위가 없으면 nil")
    func emptyRanges() {
        #expect(FrameRateRange.deviceRate(for: 5, in: []) == nil)
    }

    @Test("가상 카메라의 지원 fps 는 C922 와 같다")
    func simulatedCameraRates() {
        #expect(SimulatedFaceSource.supportedFPS.map { formatFPS($0) } == ["5", "7.5", "10", "15", "20", "24", "30"])
    }
}
