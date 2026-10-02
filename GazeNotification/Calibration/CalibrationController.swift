import AppKit
import Observation
import SwiftUI

/// 보정 화면의 진행 상태 (SwiftUI 뷰가 관찰)
@MainActor
@Observable
final class CalibrationState {
    enum Phase: Equatable {
        case intro
        case moving
        case collecting
        case done(String)
        case failed(String)
    }

    var phase: Phase = .intro
    var targetIndex = 0
    var targetX = 0.5
    var progress = 0.0
    var faceDetected = false
    let plan: CalibrationPlan
    var targets: [Double] { plan.targets }

    init(plan: CalibrationPlan) { self.plan = plan }
}

/// 보정 화면에서 할 일: 어떤 점을 얼마나 보게 하고, 모은 샘플로 무엇을 할지
struct CalibrationPlan {
    var title: String
    var intro: String
    /// 점의 가로 위치 (화면 폭 비율, 보여 주는 순서대로)
    var targets: [Double]
    var collectDuration: Duration
    var minSamplesPerTarget = 6
    /// 모은 샘플을 평가한다. 성공하면 보여 줄 메시지와 적용할 동작, 실패하면 이유
    var evaluate: @MainActor ([CalibrationSample]) -> Result<CalibrationOutcome, CalibrationFailure>

    /// 화면 양 끝(4%, 96%) 사이에 점 n 개를 고르게
    static func evenTargets(_ count: Int) -> [Double] {
        let n = max(2, count)
        return (0..<n).map { 0.04 + 0.92 * Double($0) / Double(n - 1) }
    }
}

struct CalibrationOutcome {
    var message: String
    var apply: @MainActor () -> Void
}

struct CalibrationFailure: Error {
    var message: String
}

/// 전체 화면 창에 점을 순서대로 띄우고, 각 점을 보는 동안의 얼굴 특징을 모아 `CalibrationPlan.evaluate` 에 넘긴다.
@MainActor
final class CalibrationController {
    /// 목표점 세로 위치 (화면 높이 비율, 위=0). 알림이 뜨는 상단 근처를 보게 한다.
    static let targetY: Double = 0.15

    private let settleDuration: Duration = .milliseconds(900)

    private var window: NSWindow?
    private var state: CalibrationState?
    private var task: Task<Void, Never>?
    private var keyMonitor: Any?
    private var samples: [CalibrationSample] = []
    private var collectingTarget: Double?
    private var completion: ((CalibrationOutcome?) -> Void)?

    var isActive: Bool { window != nil }

    /// 지금 바라봐야 하는 점의 가로 위치 (점이 보이는 동안만)
    var currentTarget: Double? {
        guard let state, state.phase == .moving || state.phase == .collecting else { return nil }
        return state.targetX
    }

    /// - Parameter completion: 성공하면 결과(적용은 호출한 쪽에서), 취소·실패면 nil
    func begin(on screen: NSScreen, plan: CalibrationPlan, completion: @escaping (CalibrationOutcome?) -> Void) {
        guard !isActive else { return }
        self.completion = completion
        samples = []

        let state = CalibrationState(plan: plan)
        self.state = state

        let window = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        window.level = .screenSaver
        window.identifier = NSUserInterfaceItemIdentifier("calibration")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: CalibrationView(state: state))
        window.setFrame(screen.frame, display: true)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        self.window = window

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // ESC
            self?.finish(with: nil)
            return nil
        }

        task = Task { [weak self] in await self?.run() }
    }

    /// 카메라 프레임마다 호출된다 (얼굴이 없으면 nil).
    /// - Parameter mode: 지금 분석 방식 (모든 방식을 함께 계산하지 않은 프레임은 이 방식 값만 저장)
    func ingest(_ features: FaceFeatures?, mode: AnalysisMode) {
        state?.faceDetected = features != nil
        guard let features, let target = collectingTarget else { return }
        samples.append(CalibrationSample(vectors: features.modeVectors ?? [mode: features.vector], target: target))
    }

    func cancel() { finish(with: nil) }

    private func run() async {
        guard let state else { return }
        let plan = state.plan
        do {
            state.phase = .intro
            try await Task.sleep(for: .milliseconds(2500))

            for (index, x) in plan.targets.enumerated() {
                state.targetIndex = index
                state.targetX = x
                state.progress = 0
                state.phase = .moving
                try await Task.sleep(for: settleDuration)

                state.phase = .collecting
                collectingTarget = x
                let steps = 16
                for step in 1...steps {
                    try await Task.sleep(for: plan.collectDuration / steps)
                    state.progress = Double(step) / Double(steps)
                }
                collectingTarget = nil
            }

            let perTarget = Dictionary(grouping: samples, by: \.target).mapValues(\.count)
            let missing = plan.targets.filter { (perTarget[$0] ?? 0) < plan.minSamplesPerTarget }
            Log.info("\(plan.title) 샘플 \(samples.count)개, 목표별 \(perTarget.sorted { $0.key < $1.key }.map(\.value))")

            let result: Result<CalibrationOutcome, CalibrationFailure> = missing.isEmpty
                ? plan.evaluate(samples)
                : .failure(CalibrationFailure(message: "얼굴이 충분히 감지되지 않았습니다. 카메라 위치와 조명을 확인한 뒤 다시 시도하세요."))
            switch result {
            case .success(let outcome):
                state.phase = .done(outcome.message)
                try await Task.sleep(for: .milliseconds(1800))
                finish(with: outcome)
            case .failure(let failure):
                state.phase = .failed(failure.message)
                try await Task.sleep(for: .milliseconds(3000))
                finish(with: nil)
            }
        } catch {
            // 취소됨
        }
    }

    private func finish(with outcome: CalibrationOutcome?) {
        guard window != nil else { return }
        task?.cancel()
        task = nil
        collectingTarget = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        window?.orderOut(nil)
        window = nil
        state = nil
        let completion = self.completion
        self.completion = nil
        completion?(outcome)
    }
}

/// borderless 창은 기본적으로 key 가 될 수 없어 ESC 를 못 받으므로 허용.
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private struct CalibrationView: View {
    let state: CalibrationState

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.88)

                if showsTarget {
                    target
                        .position(x: state.targetX * geometry.size.width,
                                  y: CalibrationController.targetY * geometry.size.height)
                        .animation(.easeInOut(duration: 0.6), value: state.targetX)
                }

                VStack(spacing: 14) {
                    Text(title)
                        .font(.system(size: 34, weight: .semibold))
                        .accessibilityIdentifier("calibration.title")
                    Text(subtitle)
                        .accessibilityIdentifier("calibration.subtitle")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 8) {
                        Circle()
                            .fill(state.faceDetected ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(state.faceDetected ? "얼굴 감지됨" : "얼굴이 보이지 않음")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    Text("ESC 로 취소")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.white)
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.55)
            }
        }
        .ignoresSafeArea()
    }

    private var showsTarget: Bool {
        state.phase == .moving || state.phase == .collecting
    }

    private var target: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.25), lineWidth: 4)
                .frame(width: 56, height: 56)
            Circle()
                .trim(from: 0, to: state.phase == .collecting ? state.progress : 0)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 56, height: 56)
            Circle()
                .fill(state.phase == .collecting ? Color.green : Color.white)
                .frame(width: 14, height: 14)
        }
    }

    private var title: String {
        switch state.phase {
        case .intro: state.plan.title
        case .moving, .collecting: "점을 바라보세요 (\(state.targetIndex + 1)/\(state.targets.count))"
        case .done: "\(state.plan.title) 완료"
        case .failed: "\(state.plan.title) 실패"
        }
    }

    private var subtitle: String {
        switch state.phase {
        case .intro: state.plan.intro
        case .moving: "점으로 시선을 옮기세요"
        case .collecting: "그대로 바라보세요…"
        case .done(let message), .failed(let message): message
        }
    }
}
