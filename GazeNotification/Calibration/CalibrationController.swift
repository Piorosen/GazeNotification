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
    let targets: [Double]

    init(targets: [Double]) { self.targets = targets }
}

/// 전체 화면 창에 점을 순서대로 띄우고, 각 점을 보는 동안의 얼굴 특징을 모아 `GazeCalibration` 을 학습한다.
@MainActor
final class CalibrationController {
    static let targets: [Double] = [0.04, 0.27, 0.5, 0.73, 0.96]
    /// 목표점 세로 위치 (화면 높이 비율, 위=0). 알림이 뜨는 상단 근처를 보게 한다.
    static let targetY: Double = 0.15

    private let settleDuration: Duration = .milliseconds(900)
    private let collectDuration: Duration = .milliseconds(1600)
    private let minSamplesPerTarget = 6

    private var window: NSWindow?
    private var state: CalibrationState?
    private var task: Task<Void, Never>?
    private var keyMonitor: Any?
    private var samples: [CalibrationSample] = []
    private var collectingTarget: Double?
    private var completion: ((GazeCalibration?) -> Void)?

    var isActive: Bool { window != nil }

    func begin(on screen: NSScreen, completion: @escaping (GazeCalibration?) -> Void) {
        guard !isActive else { return }
        self.completion = completion
        samples = []

        let state = CalibrationState(targets: Self.targets)
        self.state = state

        let window = KeyableWindow(contentRect: screen.frame, styleMask: [.borderless],
                                   backing: .buffered, defer: false)
        window.level = .screenSaver
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
    func ingest(_ features: FaceFeatures?) {
        state?.faceDetected = features != nil
        guard let features, let target = collectingTarget else { return }
        samples.append(CalibrationSample(features: features.vector, target: target))
    }

    func cancel() { finish(with: nil) }

    private func run() async {
        guard let state else { return }
        do {
            state.phase = .intro
            try await Task.sleep(for: .milliseconds(2500))

            for (index, x) in Self.targets.enumerated() {
                state.targetIndex = index
                state.targetX = x
                state.progress = 0
                state.phase = .moving
                try await Task.sleep(for: settleDuration)

                state.phase = .collecting
                collectingTarget = x
                let steps = 16
                for step in 1...steps {
                    try await Task.sleep(for: collectDuration / steps)
                    state.progress = Double(step) / Double(steps)
                }
                collectingTarget = nil
            }

            let perTarget = Dictionary(grouping: samples, by: \.target).mapValues(\.count)
            let missing = Self.targets.filter { (perTarget[$0] ?? 0) < minSamplesPerTarget }
            let model = missing.isEmpty ? GazeCalibration.fit(samples) : nil
            Log.info("보정 샘플 \(samples.count)개, 목표별 \(perTarget.sorted { $0.key < $1.key }.map(\.value))")

            if let model {
                state.phase = .done(String(format: "평균 오차 약 %.1f%% (화면 폭 기준)", model.rmse * 100))
                Log.info("보정 완료 rmse=\(model.rmse) weights=\(model.weights) used=\(model.used)")
                try await Task.sleep(for: .milliseconds(1800))
                finish(with: model)
            } else {
                state.phase = .failed("얼굴이 충분히 감지되지 않았습니다. 카메라 위치와 조명을 확인한 뒤 다시 시도하세요.")
                try await Task.sleep(for: .milliseconds(2600))
                finish(with: nil)
            }
        } catch {
            // 취소됨
        }
    }

    private func finish(with model: GazeCalibration?) {
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
        completion?(model)
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
                    Text(subtitle)
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
        case .intro: "시선 보정"
        case .moving, .collecting: "점을 바라보세요 (\(state.targetIndex + 1)/\(state.targets.count))"
        case .done: "보정 완료"
        case .failed: "보정 실패"
        }
    }

    private var subtitle: String {
        switch state.phase {
        case .intro:
            "화면 위쪽에 점이 왼쪽부터 차례로 나타납니다.\n평소 작업할 때처럼 자연스럽게 바라보세요. 고개를 돌려도 괜찮습니다."
        case .moving: "점으로 시선을 옮기세요"
        case .collecting: "그대로 바라보세요…"
        case .done(let message), .failed(let message): message
        }
    }
}
