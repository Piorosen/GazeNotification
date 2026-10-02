import Darwin
import Foundation

/// 1초마다 한 번 남기는 성능 기록 (그래프용). 메뉴·설정 창이 닫혀 있어도 계속 쌓는다 (기록 자체는 µs 단위 비용).
struct PerformanceSample: Identifiable, Equatable {
    let id: Int
    let time: Date
    /// 앱 전체 CPU (코어 1개 = 100%)
    var processCPU: Double
    /// 메인 스레드를 뺀 CPU — 카메라 수신, Vision, Neural Engine 드라이버 스레드
    var trackingCPU: Double
    /// 메인 스레드 CPU — 화면(UI), 알림 감시·이동
    var mainCPU: Double
    /// 실제 Vision 처리 횟수/s
    var processedHz: Double
    /// 그중 전체 얼굴 검출 횟수/s (나머지는 추적)
    var detectHz: Double
    /// 카메라에서 받은 프레임/s
    var receivedFPS: Double
    /// 정책상 목표 처리 횟수/s
    var targetHz: Double
    var detectMs: Double
    var landmarksMs: Double
    var notificationChecksPerSecond: Double
    var axCallsPerSecond: Double
    var rate: TrackingRate
    var profile: PerformanceProfile
    /// CPU 상한 때문에 줄인 비율 (1 = 줄이지 않음)
    var governorScale: Double
}

/// CPU 시간 측정
enum CPUClock {
    /// 프로세스 전체 CPU 시간(초)
    static func process() -> Double {
        var ts = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts)
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9
    }

    /// 특정 스레드의 CPU 시간(초). 메인 스레드 몫을 따로 보려고 쓴다.
    static func thread(_ port: mach_port_t) -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }

    /// 지금 이 코드를 실행 중인 스레드의 mach 포트 (메인 스레드에서 한 번 읽어 둔다)
    static func currentThreadPort() -> mach_port_t {
        pthread_mach_thread_np(pthread_self())
    }
}

/// 최근 N 개만 남기는 기록
struct PerformanceHistory {
    static let capacity = 600 // 10분

    private(set) var samples: [PerformanceSample] = []
    private var nextID = 0

    mutating func append(_ make: (Int) -> PerformanceSample) {
        samples.append(make(nextID))
        nextID += 1
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }
}
