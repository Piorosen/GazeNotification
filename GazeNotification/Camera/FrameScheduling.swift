import AVFoundation
import CoreMedia

/// 시간 기준 처리 간격. "N 프레임마다 1번" 과 달리 장치 fps 가 바뀌어도 처리 횟수가 목표를 넘지 않는다.
/// 다음 처리 시각에서 반 프레임 이내로 도착한 프레임까지 처리하고, 처리 시각을 간격만큼씩 밀어 평균 횟수를 맞춘다
/// (5fps 에서 3회/s 면 처리·건너뜀이 섞여 평균 3회).
struct FrameThrottle {
    /// 목표 처리 간격(초)
    private(set) var interval: Double = 0.2
    /// 받은 프레임 간격의 지수 평균(초)
    private(set) var frameInterval: Double = 0.2
    private var nextDue: CFTimeInterval = 0
    private var lastFrame: CFTimeInterval = 0

    /// 목표 처리 횟수/s. 빨라지면 다음 프레임을 바로 처리한다.
    mutating func setRate(_ hz: Double) {
        let interval = 1 / max(hz, 0.05)
        if interval < self.interval { nextDue = 0 }
        self.interval = interval
    }

    /// 장치 fps 를 바꿨을 때 프레임 간격 추정값을 바로 맞춘다
    mutating func setDeviceFPS(_ fps: Double) {
        guard fps > 0 else { return }
        frameInterval = 1 / fps
    }

    /// 프레임이 도착할 때마다 호출. 이 프레임을 처리해야 하면 true.
    mutating func shouldProcess(at now: CFTimeInterval) -> Bool {
        if lastFrame > 0 { frameInterval = frameInterval * 0.8 + min(now - lastFrame, 1) * 0.2 }
        lastFrame = now
        guard now + frameInterval * 0.5 >= nextDue else { return false }
        nextDue = now - nextDue > interval ? now + interval : nextDue + interval
        return true
    }
}

/// 받은 프레임이 설정보다 훨씬 많으면(세션 재구성으로 장치가 기본 30fps 로 돌아감) 다시 적용하라고 알린다.
/// 다른 앱이 같은 카메라를 쓰면 계속 되돌아가므로 세 번 고친 뒤에는 1분에 한 번만 시도한다.
struct FrameRateWatchdog {
    /// 장치에 설정한 fps (0 = 감시 안 함)
    var expectedFPS: Double = 0 {
        didSet { overrunWindows = 0 }
    }
    /// 지금까지 다시 적용하라고 한 횟수
    private(set) var fixes = 0
    private var overrunWindows = 0
    private var lastFix: CFTimeInterval = -.infinity

    mutating func reset() {
        fixes = 0
        overrunWindows = 0
        lastFix = -.infinity
    }

    /// 약 1초 통계마다 호출. 다시 적용해야 하면 true.
    mutating func check(received: Double, at now: CFTimeInterval) -> Bool {
        guard expectedFPS > 0, received > expectedFPS * 1.4 + 0.5 else {
            overrunWindows = 0
            return false
        }
        overrunWindows += 1
        let backoff: CFTimeInterval = fixes >= 3 ? 60 : 10
        guard overrunWindows >= 2, now - lastFix > backoff else { return false }
        overrunWindows = 0
        lastFix = now
        fixes += 1
        return true
    }
}

/// 장치가 지원하는 fps 범위 (`AVFrameRateRange` 를 테스트할 수 있는 값으로)
struct FrameRateRange: Equatable {
    var minRate: Double
    var maxRate: Double
    /// minRate 에 해당하는 간격 (가장 긴 간격)
    var maxDuration: CMTime
    /// maxRate 에 해당하는 간격
    var minDuration: CMTime

    init(_ range: AVFrameRateRange) {
        minRate = range.minFrameRate
        maxRate = range.maxFrameRate
        maxDuration = range.maxFrameDuration
        minDuration = range.minFrameDuration
    }

    init(minRate: Double, maxRate: Double) {
        self.minRate = minRate
        self.maxRate = maxRate
        maxDuration = CMTime(seconds: 1 / minRate, preferredTimescale: 1_000_000)
        minDuration = CMTime(seconds: 1 / maxRate, preferredTimescale: 1_000_000)
    }

    /// 지원 범위 중 hz 이상인 가장 낮은 fps 와 그 프레임 간격. 없으면 가장 높은 fps.
    /// UVC 웹캠은 5/7.5/10/15/… 처럼 띄엄띄엄 지원하므로, 범위 끝값은 장치가 알려 준 간격을 그대로 쓴다
    /// (지원하지 않는 간격을 넣으면 예외로 앱이 죽는다).
    static func deviceRate(for hz: Double, in ranges: [FrameRateRange]) -> (fps: Double, duration: CMTime)? {
        var best: (fps: Double, duration: CMTime)?
        for range in ranges {
            let candidate: (fps: Double, duration: CMTime)
            if hz <= range.minRate {
                candidate = (range.minRate, range.maxDuration)
            } else if hz < range.maxRate {
                candidate = (hz, CMTime(seconds: 1 / hz, preferredTimescale: 1_000_000))
            } else if abs(hz - range.maxRate) < 0.01 {
                candidate = (range.maxRate, range.minDuration)
            } else {
                continue
            }
            if best.map({ candidate.fps < $0.fps }) ?? true { best = candidate }
        }
        if let best { return best }
        guard let fastest = ranges.max(by: { $0.maxRate < $1.maxRate }) else { return nil }
        return (fastest.maxRate, fastest.minDuration)
    }

    /// 범위 안에 드는 간격인지 (장치에 넣기 전 확인용)
    func contains(_ duration: CMTime) -> Bool {
        duration >= minDuration && duration <= maxDuration
    }
}
