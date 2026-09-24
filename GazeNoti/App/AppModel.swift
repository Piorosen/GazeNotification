import AppKit
import AVFoundation
import Observation
import ServiceManagement
import UserNotifications

enum PlacementSource: String, CaseIterable, Identifiable {
    case gaze
    case mouse

    var id: String { rawValue }
    var title: String {
        switch self {
        case .gaze: "시선"
        case .mouse: "마우스"
        }
    }
}

/// 앱 전체 상태. 카메라 → 시선 추정 → 알림 이동을 연결한다.
@MainActor
@Observable
final class AppModel {
    private enum Keys {
        static let enabled = "enabled"
        static let follow = "followWhileVisible"
        static let overlay = "showOverlay"
        static let source = "placementSource"
        static let camera = "cameraID"
        static let calibration = "calibration.v1"
    }

    // MARK: 설정

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Keys.enabled)
            applyRunState()
        }
    }

    var followWhileVisible: Bool {
        didSet {
            defaults.set(followWhileVisible, forKey: Keys.follow)
            mover.followWhileVisible = followWhileVisible
        }
    }

    var showOverlay: Bool {
        didSet {
            defaults.set(showOverlay, forKey: Keys.overlay)
            updateOverlayVisibility()
        }
    }

    var placementSource: PlacementSource {
        didSet {
            defaults.set(placementSource.rawValue, forKey: Keys.source)
            applyRunState()
        }
    }

    /// nil = 자동 선택
    var selectedCameraID: String? {
        didSet {
            guard oldValue != selectedCameraID else { return }
            defaults.set(selectedCameraID, forKey: Keys.camera)
            if cameraShouldRun { camera.start(deviceID: selectedCameraID) }
        }
    }

    // MARK: 실시간 상태

    private(set) var cameras: [CameraInfo] = []
    private(set) var cameraStatus: CameraStatus = .idle
    private(set) var faceDetected = false
    /// 스무딩된 시선 가로 위치 (0...1). **메뉴가 열려 있을 때만 갱신**된다 (UI 표시용).
    private(set) var gazeX: Double?
    /// Vision 처리 fps. 메뉴가 열려 있을 때만 갱신된다.
    private(set) var fps: Double = 0

    /// 메뉴 패널이 보이는지 (MenuView 가 설정). 닫혀 있으면 실시간 값을 SwiftUI 로 흘려보내지 않는다.
    @ObservationIgnored var isMenuVisible = false {
        didSet {
            guard isMenuVisible != oldValue else { return }
            if isMenuVisible {
                gazeX = latestGaze
                fps = measuredFPS
                pipeline = latestPipeline
                startLiveStats()
            } else {
                stopLiveStats()
            }
        }
    }

    /// 카메라 미리보기를 펼쳤는지. 펼쳐져 있는 동안만 10fps (메뉴를 여는 것만으로는 속도를 바꾸지 않는다).
    @ObservationIgnored var isPreviewVisible = false {
        didSet {
            guard isPreviewVisible != oldValue else { return }
            updateAdaptiveStride(faceFound: faceDetected, now: CACurrentMediaTime())
        }
    }

    // MARK: AI 연산 상세 (메뉴가 열려 있을 때만 갱신)

    /// 현재 추적 속도 단계
    private(set) var trackingRate: TrackingRate = .normal
    /// 최근 1초 처리 통계
    private(set) var pipeline = PipelineSnapshot()
    private(set) var cameraFormat: CameraFormatInfo?
    /// 가장 최근 프레임의 시선 계산 과정
    private(set) var gazeBreakdown: GazeBreakdown?
    /// 1초마다 갱신되는 요약
    private(set) var liveStats = LiveStats()

    var visionDevices: (detection: String, landmarks: String) { camera.visionDevices }
    private(set) var accessibilityGranted = Permissions.accessibilityTrusted
    private(set) var calibration: GazeCalibration?
    private(set) var isCalibrating = false
    private(set) var lastEvent: String?
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    var captureSession: AVCaptureSession { camera.session }

    var screenAspectRatio: CGFloat {
        guard let frame = NSScreen.main?.frame, frame.height > 0 else { return 32.0 / 9.0 }
        return frame.width / frame.height
    }

    var menuBarSymbol: String {
        if !isEnabled { return "eye.slash" }
        if !accessibilityGranted { return "exclamationmark.triangle" }
        if placementSource == .gaze && !faceDetected { return "eye.trianglebadge.exclamationmark" }
        return "eye"
    }

    // MARK: 내부

    private let defaults = UserDefaults.standard
    private let camera = CameraService()
    private let mover = NotificationMover()
    private let overlay = GazeOverlay()
    private let calibrator = CalibrationController()
    @ObservationIgnored private var filter = OneEuroFilter()
    @ObservationIgnored private var lastFaceTime: TimeInterval = 0
    @ObservationIgnored private var lastPupilOffset: Double?
    @ObservationIgnored private var lastFeatures: FaceFeatures?
    /// 실제 추적값 (알림 이동·오버레이는 항상 이 값을 사용)
    @ObservationIgnored private var latestGaze: Double?
    @ObservationIgnored private var measuredFPS: Double = 0
    @ObservationIgnored private var latestPipeline = PipelineSnapshot()
    @ObservationIgnored private var liveTimer: Timer?
    @ObservationIgnored private var previousSample: LiveSample?
    @ObservationIgnored private let launchTime = CACurrentMediaTime()
    @ObservationIgnored private var processedFrames = 0
    @ObservationIgnored private var rateDurations: [TrackingRate: TimeInterval] = [:]
    @ObservationIgnored private var rateSince = CACurrentMediaTime()
    @ObservationIgnored private var motionAnchor: Double?
    @ObservationIgnored private var motionAnchorTime: TimeInterval = 0
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var fpsWindowStart: TimeInterval = 0
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var deviceObservers: [NSObjectProtocol] = []

    private var cameraShouldRun: Bool {
        isEnabled && (placementSource == .gaze || isCalibrating)
    }

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Keys.enabled: true,
            Keys.follow: true,
            Keys.overlay: false,
            Keys.source: PlacementSource.gaze.rawValue,
        ])
        isEnabled = defaults.bool(forKey: Keys.enabled)
        followWhileVisible = defaults.bool(forKey: Keys.follow)
        showOverlay = defaults.bool(forKey: Keys.overlay)
        placementSource = PlacementSource(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .gaze
        selectedCameraID = defaults.string(forKey: Keys.camera)
        if let data = defaults.data(forKey: Keys.calibration) {
            calibration = try? JSONDecoder().decode(GazeCalibration.self, from: data)
        }
    }

    func start() {
        Log.info("GazeNoti 시작 (AX 권한: \(accessibilityGranted), 보정: \(calibration != nil))")
        camera.onFeatures = { [weak self] features in self?.handle(features) }
        camera.onStatus = { [weak self] status in self?.cameraStatus = status }
        camera.onFormat = { [weak self] info in self?.cameraFormat = info }
        camera.onStats = { [weak self] snapshot in
            guard let self else { return }
            self.latestPipeline = snapshot
            if self.isMenuVisible { self.pipeline = snapshot }
        }
        mover.targetProvider = { [weak self] in self?.placementTarget() }
        mover.followWhileVisible = followWhileVisible
        mover.onMove = { [weak self] message in
            self?.lastEvent = "\(Date().formatted(date: .omitted, time: .standard)) · \(message)"
        }

        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        refreshCameras()
        observeCameraDevices()
        if !accessibilityGranted { Permissions.requestAccessibility() }
        startPermissionPolling()
        applyRunState()
    }

    // MARK: - 동작

    func startCalibration() {
        guard !isCalibrating, isEnabled else { return }
        isCalibrating = true
        applyRunState()
        updateAdaptiveStride(faceFound: faceDetected, now: CACurrentMediaTime())
        overlay.setVisible(false)

        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        calibrator.begin(on: screen) { [weak self] result in
            guard let self else { return }
            self.isCalibrating = false
            self.updateAdaptiveStride(faceFound: self.faceDetected, now: CACurrentMediaTime())
            if let result {
                self.calibration = result
                if let data = try? JSONEncoder().encode(result) { self.defaults.set(data, forKey: Keys.calibration) }
                self.filter.reset()
                self.lastEvent = String(format: "보정 완료 · 평균 오차 %.1f%%", result.rmse * 100)
            }
            self.applyRunState()
        }
    }

    func resetCalibration() {
        calibration = nil
        defaults.removeObject(forKey: Keys.calibration)
        filter.reset()
        lastEvent = "보정 초기화 — 기본 추정식 사용"
    }

    /// `delay` 초 뒤 GazeNoti 이름으로 테스트 알림. 그 사이 원하는 곳을 바라보면 된다.
    /// (osascript 알림은 Script Editor 알림이 꺼져 있으면 조용히 버려져서 직접 보낸다)
    func sendTestNotification(after delay: TimeInterval = 3) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    self.lastEvent = "알림 권한이 없습니다 — 시스템 설정 → 알림 → GazeNoti 허용"
                    Log.error("알림 권한 거부: \(error?.localizedDescription ?? "-")")
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "GazeNoti 테스트"
                content.body = "보고 있던 곳에 알림이 떴나요?"
                content.sound = .default
                let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
                let request = UNNotificationRequest(identifier: "gazenoti.test.\(UUID().uuidString)",
                                                    content: content, trigger: trigger)
                Task {
                    do { try await center.add(request) } catch {
                        Log.error("테스트 알림 실패: \(error.localizedDescription)")
                    }
                }
                self.lastEvent = delay > 0
                    ? "\(Int(delay))초 뒤 테스트 알림 — 원하는 곳을 바라보세요"
                    : "테스트 알림 전송"
            }
        }
    }

    func requestAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastEvent = "로그인 항목 변경 실패: \(error.localizedDescription)"
            Log.error("SMAppService: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func dumpAccessibilityTree(reveal: Bool = true) {
        if let url = mover.dumpAllWindows() {
            Log.info("AX 트리 저장: \(url.path)")
            if reveal { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } else {
            lastEvent = "AX 트리를 읽지 못했습니다 (손쉬운 사용 권한 확인)"
        }
    }

    func logStatus() {
        let gaze = latestGaze.map { String(format: "%.3f", $0) } ?? "nil"
        let features = lastFeatures.map { f in
            String(format: "nose=%.3f pupil=%@ faceX=%.3f faceW=%.3f yaw=%@", f.noseOffset,
                   f.pupilOffset.map { String(format: "%.3f", $0) } ?? "nil", f.faceX, f.faceWidth,
                   f.yaw.map { String(format: "%.3f", $0) } ?? "nil")
        } ?? "none"
        let p = latestPipeline
        Log.info(String(format: "STATUS pipeline 수신 %.1f/s 처리 %.1f/s 랜드마크 %.1f/s | 검출 %.1fms(CPU %.1f) 랜드마크 %.1fms(CPU %.1f) 특징 %.2fms | 파이프라인 CPU %.1f%%",
                        p.receivedFPS, p.processedFPS, p.landmarksFPS, p.detectWallMs, p.detectCPUms,
                        p.landmarksWallMs, p.landmarksCPUms, p.featuresCPUms, p.cpuPercent))
        Log.info("STATUS enabled=\(isEnabled) source=\(placementSource.rawValue) camera=\(cameraStatus) "
            + "face=\(faceDetected) gazeX=\(gaze) fps=\(String(format: "%.1f", measuredFPS)) rate=\(trackingRate) menu=\(isMenuVisible) ax=\(accessibilityGranted) "
            + "calibrated=\(calibration != nil) mover=\(mover.isRunning) features[\(features)]")
    }

    func openLogFolder() {
        try? FileManager.default.createDirectory(at: Log.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Log.directory)
    }

    // MARK: - 내부 처리

    private func applyRunState() {
        if cameraShouldRun {
            startCameraIfAuthorized()
        } else {
            camera.stop()
            faceDetected = false
        }

        if isEnabled && accessibilityGranted {
            mover.start()
        } else {
            mover.stop()
        }
        updateOverlayVisibility()
    }

    private func startCameraIfAuthorized() {
        switch Permissions.cameraStatus {
        case .authorized:
            camera.start(deviceID: selectedCameraID)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                Task { @MainActor in self?.applyRunState() }
            }
        default:
            cameraStatus = .unauthorized
        }
    }

    private func updateOverlayVisibility() {
        overlay.setVisible(isEnabled && showOverlay && placementSource == .gaze && !isCalibrating)
        overlay.update(normalizedX: latestGaze, faceDetected: faceDetected)
        updateAdaptiveStride(faceFound: faceDetected, now: CACurrentMediaTime())
    }

    private func placementTarget() -> Double? {
        switch placementSource {
        case .gaze: latestGaze
        case .mouse: NSScreen.normalizedMouseX()
        }
    }

    private func handle(_ features: FaceFeatures?) {
        countFrame()
        processedFrames += 1
        calibrator.ingest(features)

        guard var features else {
            let now = CACurrentMediaTime()
            if faceDetected, now - lastFaceTime > 0.6 {
                faceDetected = false
                overlay.update(normalizedX: latestGaze, faceDetected: false)
            }
            updateAdaptiveStride(faceFound: false, now: now)
            return
        }

        lastFaceTime = features.timestamp
        lastFeatures = features
        if !faceDetected { faceDetected = true }
        // 눈 깜빡임 등으로 동공이 빠진 프레임은 직전 값으로 채운다
        if let pupil = features.pupilOffset { lastPupilOffset = pupil } else { features.pupilOffset = lastPupilOffset }

        let raw = calibration?.predict(features.vector) ?? DefaultGazeModel.predict(features)
        let smoothed = filter.filter(raw.clamped(to: -0.1...1.1), timestamp: features.timestamp)
        latestGaze = smoothed.clamped(to: 0...1)
        if isMenuVisible {
            gazeX = latestGaze
            var breakdown = calibration?.breakdown(features) ?? DefaultGazeModel.breakdown(features)
            breakdown.filtered = latestGaze ?? smoothed
            gazeBreakdown = breakdown
        }
        overlay.update(normalizedX: latestGaze, faceDetected: true)
        updateAdaptiveStride(faceFound: true, now: features.timestamp)
    }

    /// 상황별 추적 속도. 장치 fps 를 낮추면 캡처 비용까지 줄어든다.
    ///
    /// | 상태 | 장치 | 처리 |
    /// | 보정 중·카메라 미리보기 | 10fps | 10fps |
    /// | 얼굴 있음 | 5fps | 5fps |
    /// | 시선이 3초 이상 멈춤 | 5fps | 2.5fps |
    /// | 얼굴 없음 3초 이상 | 5fps | 1.7fps |
    private func updateAdaptiveStride(faceFound: Bool, now: TimeInterval) {
        let rate: TrackingRate
        if isCalibrating || isPreviewVisible {
            rate = .live
        } else if !faceFound {
            rate = now - lastFaceTime > 3 ? .away : trackingRate
        } else if let gaze = latestGaze, let anchor = motionAnchor, abs(gaze - anchor) < 0.06 {
            rate = now - motionAnchorTime > 3 ? .still : .normal
        } else {
            motionAnchor = latestGaze
            motionAnchorTime = now
            rate = .normal
        }
        guard rate != trackingRate else { return }
        let changedAt = CACurrentMediaTime()
        rateDurations[trackingRate, default: 0] += changedAt - rateSince
        rateSince = changedAt
        trackingRate = rate
        camera.setCaptureRate(fps: rate.deviceFPS, stride: rate.stride)
    }

    // MARK: - 1초마다 요약 (메뉴가 열려 있을 때만)

    private func startLiveStats() {
        previousSample = LiveSample.now(mover: mover.status())
        updateLiveStats()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateLiveStats() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        liveTimer = timer
    }

    private func stopLiveStats() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    private func updateLiveStats() {
        let now = CACurrentMediaTime()
        let moverStatus = mover.status()
        let sample = LiveSample.now(mover: moverStatus)
        var stats = LiveStats()
        if let previous = previousSample, sample.time > previous.time {
            let dt = sample.time - previous.time
            stats.processCPUPercent = (sample.cpuSeconds - previous.cpuSeconds) / dt * 100
            stats.windowChecksPerSecond = Double(sample.mover.windowChecks - previous.mover.windowChecks) / dt
            stats.axCallsPerSecond = Double(sample.mover.axCalls - previous.mover.axCalls) / dt
            stats.movesPerSecond = Double(sample.mover.moves - previous.mover.moves) / dt
            stats.ticksPerSecond = Double(sample.mover.ticks - previous.mover.ticks) / dt
        }
        previousSample = sample
        stats.mover = moverStatus

        let uptime = now - launchTime
        stats.uptime = uptime
        stats.averageProcessedFPS = uptime > 0 ? Double(processedFrames) / uptime : 0
        var durations = rateDurations
        durations[trackingRate, default: 0] += now - rateSince
        let total = durations.values.reduce(0, +)
        stats.rateShare = total > 0 ? durations.mapValues { $0 / total } : [:]
        liveStats = stats
    }

    /// 앱 종료 시 알림 창을 원래 위치로 되돌리고 카메라를 끈다.
    func shutdown() {
        mover.stop()
        camera.stop()
    }

    private func countFrame() {
        let now = CACurrentMediaTime()
        frameCount += 1
        if fpsWindowStart == 0 { fpsWindowStart = now }
        let elapsed = now - fpsWindowStart
        if elapsed >= 1 {
            measuredFPS = Double(frameCount) / elapsed
            if isMenuVisible { fps = measuredFPS }
            frameCount = 0
            fpsWindowStart = now
        }
    }

    private func refreshCameras() {
        cameras = CameraService.availableCameras()
    }

    private func observeCameraDevices() {
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshCameras()
                    if self.cameraShouldRun { self.camera.start(deviceID: self.selectedCameraID) }
                }
            }
            deviceObservers.append(token)
        }
    }

    /// 손쉬운 사용 권한은 변경 알림이 없어서 주기적으로 확인한다.
    private func startPermissionPolling() {
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trusted = Permissions.accessibilityTrusted
                if trusted != self.accessibilityGranted {
                    self.accessibilityGranted = trusted
                    Log.info("손쉬운 사용 권한 변경: \(trusted)")
                    self.applyRunState()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }
}

/// 앱이 활성 상태여도 테스트 알림을 배너로 표시
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }
}

/// 추적 속도 단계 (장치 fps, 처리 간격)
enum TrackingRate: CaseIterable {
    case live, normal, still, away

    var title: String {
        switch self {
        case .live: "실시간"
        case .normal: "평소"
        case .still: "절전"
        case .away: "자리 비움"
        }
    }

    var reason: String {
        switch self {
        case .live: "보정 중이거나 카메라 미리보기를 펼침"
        case .normal: "얼굴이 보이고 시선이 움직이는 중"
        case .still: "시선이 3초 넘게 한곳에 머묾"
        case .away: "얼굴이 3초 넘게 보이지 않음"
        }
    }

    /// 실제 Vision 처리 횟수/s
    var processingFPS: Double { deviceFPS / Double(stride) }

    var deviceFPS: Double { self == .live ? 10 : 5 }
    var stride: Int {
        switch self {
        case .live, .normal: 1
        case .still: 2
        case .away: 3
        }
    }
}

/// 메뉴에 1초마다 보여 주는 요약
struct LiveStats: Equatable {
    /// GazeNoti 프로세스 전체 CPU (코어 1개 = 100%)
    var processCPUPercent: Double = 0
    var ticksPerSecond: Double = 0
    var windowChecksPerSecond: Double = 0
    var axCallsPerSecond: Double = 0
    var movesPerSecond: Double = 0
    var mover: MoverStatus?
    var uptime: TimeInterval = 0
    /// 실행 후 평균 Vision 처리 횟수/s (메뉴가 닫혀 있던 시간 포함)
    var averageProcessedFPS: Double = 0
    /// 실행 후 각 속도 단계에 머문 시간 비율
    var rateShare: [TrackingRate: Double] = [:]
}

/// 초당 값 계산용 누적 샘플
private struct LiveSample {
    var time: CFTimeInterval
    var cpuSeconds: Double
    var mover: MoverStatus

    static func now(mover: MoverStatus) -> LiveSample {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return LiveSample(time: CACurrentMediaTime(), cpuSeconds: cpu, mover: mover)
    }
}
