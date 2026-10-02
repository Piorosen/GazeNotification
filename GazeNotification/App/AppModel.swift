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

/// 설정 창의 탭
enum SettingsTab: String, CaseIterable, Identifiable {
    case performance, limits, ai, calibration

    var id: String { rawValue }
    var title: String {
        switch self {
        case .performance: "성능 그래프"
        case .limits: "연산 제한"
        case .ai: "AI 모드"
        case .calibration: "보정 조정"
        }
    }
    var symbol: String {
        switch self {
        case .performance: "chart.xyaxis.line"
        case .limits: "gauge.with.dots.needle.33percent"
        case .ai: "brain"
        case .calibration: "scope"
        }
    }
}

/// 카메라를 잠시 끈 이유
enum CameraPause: Equatable {
    /// 화면이 꺼졌거나 잠김
    case screen
    /// 자리 비움이 오래 이어짐 — 키보드·마우스 입력이 생기면 다시 켠다
    case absence

    var title: String {
        switch self {
        case .screen: "화면이 꺼져 있거나 잠겨 있어 카메라를 끔"
        case .absence: "오래 자리를 비워 카메라를 끔 — 키보드·마우스를 쓰면 다시 켬"
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
        /// 예전 버전의 보정 (분석 방식 하나·선형 모델 하나). 읽기만 해서 옮긴다
        static let legacyCalibration = "calibration.v1"
        static let calibration = "calibration.v2"
        static let analysisMode = "ai.analysisMode"
        static let estimator = "ai.estimator"
        static let computeDevice = "ai.computeDevice"
        static let modeCosts = "ai.modeCosts"
        static let profile = "performance.profile"
        static let customLimits = "performance.customLimits"
        static let adjustment = "gaze.adjustment"
        static let calibrationPoints = "calibration.points"
        static let calibrationSeconds = "calibration.seconds"
        static let adjustOverlay = "adjust.showOverlay"
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

    /// 사용자가 고른 성능 프로필
    var profile: PerformanceProfile {
        didSet {
            defaults.set(profile.rawValue, forKey: Keys.profile)
            applyPolicy()
        }
    }

    /// 사용자 지정 프로필의 값
    var customLimits: PerformanceLimits {
        didSet {
            save(customLimits, Keys.customLimits)
            applyPolicy()
        }
    }

    /// 손으로 맞춘 시선 보정값
    var adjustment: GazeAdjustment {
        didSet {
            save(adjustment, Keys.adjustment)
            adjustmentChanged(from: oldValue)
        }
    }

    /// 전체 시선 보정의 점 개수
    var calibrationPointCount: Int {
        didSet { defaults.set(calibrationPointCount, forKey: Keys.calibrationPoints) }
    }

    /// 전체 시선 보정에서 점 하나를 보는 시간(초)
    var calibrationSeconds: Double {
        didSet { defaults.set(calibrationSeconds, forKey: Keys.calibrationSeconds) }
    }

    /// 얼굴 분석 방식 (AI 모드)
    var analysisMode: AnalysisMode {
        didSet {
            guard analysisMode != oldValue else { return }
            defaults.set(analysisMode.rawValue, forKey: Keys.analysisMode)
            Log.info("얼굴 분석 방식: \(analysisMode.title)")
            camera.setAnalysis(mode: analysisMode, computeAllModes: isCalibrating)
            resetTracking()
        }
    }

    /// 시선 추정 모델 (AI 모드)
    var estimatorChoice: EstimatorChoice {
        didSet {
            guard estimatorChoice != oldValue else { return }
            defaults.set(estimatorChoice.rawValue, forKey: Keys.estimator)
            Log.info("시선 추정 모델: \(estimatorChoice.title) → \(activeEstimatorKind.title)")
            resetTracking()
        }
    }

    /// Vision 신경망을 돌릴 장치 (AI 모드)
    var computePreference: ComputePreference {
        didSet {
            guard computePreference != oldValue else { return }
            defaults.set(computePreference.rawValue, forKey: Keys.computeDevice)
            camera.setComputePreference(computePreference)
        }
    }

    /// 보정 조정 탭을 보는 동안 화면 상단에 위치 막대를 띄울지
    var showOverlayWhileAdjusting: Bool {
        didSet {
            defaults.set(showOverlayWhileAdjusting, forKey: Keys.adjustOverlay)
            updateOverlayVisibility()
        }
    }

    var settingsTab: SettingsTab = .performance {
        didSet {
            guard oldValue != settingsTab else { return }
            updateOverlayVisibility()
        }
    }

    // MARK: 실시간 상태

    private(set) var cameras: [CameraInfo] = []
    private(set) var cameraStatus: CameraStatus = .idle
    private(set) var faceDetected = false
    /// 스무딩된 시선 가로 위치 (0...1). **메뉴·설정 창이 보일 때만 갱신**된다 (UI 표시용).
    private(set) var gazeX: Double?
    /// 수동 조정 전 모델 출력 (0...1, 보정 조정 미리보기용). 메뉴·설정 창이 보일 때만 갱신된다.
    private(set) var rawGazeX: Double?
    /// Vision 처리 fps. 메뉴가 열려 있을 때만 갱신된다.
    private(set) var fps: Double = 0

    /// 메뉴 패널이 보이는지 (MenuView 가 설정). 닫혀 있으면 실시간 값을 SwiftUI 로 흘려보내지 않는다.
    @ObservationIgnored var isMenuVisible = false {
        didSet {
            guard isMenuVisible != oldValue else { return }
            if isMenuVisible {
                fps = measuredFPS
                liveStats = latestLiveStats
                publishLiveValues()
            }
        }
    }

    /// 카메라 미리보기를 펼쳤는지. 펼쳐져 있는 동안만 실시간 속도 (메뉴를 여는 것만으로는 속도를 바꾸지 않는다).
    @ObservationIgnored var isPreviewVisible = false {
        didSet {
            guard isPreviewVisible != oldValue else { return }
            updateTrackingRate(faceFound: faceDetected, now: CACurrentMediaTime())
            // 미리보기 레이어를 붙이거나 떼면 세션이 장치 fps 를 기본값(30fps)으로 되돌린다
            camera.reapplyFormat()
        }
    }

    /// 설정 창이 화면에 보이는지 (`SettingsWindowController` 가 설정)
    @ObservationIgnored var isSettingsVisible = false {
        didSet {
            guard isSettingsVisible != oldValue else { return }
            if isSettingsVisible { publishLiveValues() }
            updateOverlayVisibility()
        }
    }

    // MARK: AI 연산 상세 (메뉴·설정 창이 보일 때만 갱신)

    /// 현재 추적 속도 단계
    private(set) var trackingRate: TrackingRate = .normal
    /// 최근 1초 처리 통계
    private(set) var pipeline = PipelineSnapshot()
    private(set) var cameraFormat: CameraFormatInfo?
    /// 가장 최근 프레임의 시선 계산 과정
    private(set) var gazeBreakdown: GazeBreakdown?
    /// 1초마다 갱신되는 요약 (메뉴용)
    private(set) var liveStats = LiveStats()
    /// 1초 간격 성능 기록 (최근 10분)
    private(set) var history: [PerformanceSample] = []
    /// 지금 카메라에 요청한 처리 횟수/s
    private(set) var targetHz: Double = 0

    // MARK: 전원·정책

    private(set) var power = PowerState()
    private(set) var policy: EffectivePolicy
    var limits: PerformanceLimits { policy.limits }
    /// CPU 상한 때문에 처리 횟수를 줄인 비율 (1 = 줄이지 않음)
    private(set) var governorScale = 1.0
    @ObservationIgnored private var governor = CPUGovernor()
    /// nil = 카메라 켜짐
    private(set) var cameraPause: CameraPause?
    /// 알림 창이 화면에 떠 있는지
    private(set) var notificationVisible = false

    /// Vision 요청에 실제로 지정된 장치
    private(set) var visionDevices = VisionDevices()
    /// 분석 방식·장치별로 최근에 측정한 처리 1회당 비용 (AI 모드 비교용)
    private(set) var modeCosts: [ModeCostKey: ModeCost] = [:]
    private(set) var accessibilityGranted = Permissions.accessibilityTrusted
    /// 마지막 보정으로 학습한 모든 모델
    private(set) var calibration: CalibrationSet?
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
        if placementSource == .gaze && cameraPause != nil { return "zzz" }
        if placementSource == .gaze && !faceDetected { return "eye.trianglebadge.exclamationmark" }
        return "eye"
    }

    /// 보정 조정 탭이 화면에 보이는지 (실시간 속도·위치 막대)
    var isAdjusting: Bool { isSettingsVisible && settingsTab == .calibration }

    /// 지금 실제로 쓰는 추정 모델 종류 (자동이면 교차검증 오차가 가장 작은 것, 고른 모델이 없으면 기본 추정식)
    var activeEstimatorKind: EstimatorKind {
        if let kind = estimatorChoice.kind {
            return kind == .formula || calibration?.estimator(analysisMode, kind) != nil ? kind : .formula
        }
        return calibration?.bestKind(for: analysisMode) ?? .formula
    }

    /// 지금 쓰는 학습 모델 (기본 추정식이면 nil)
    var activeEstimator: GazeEstimator? {
        calibration?.estimator(analysisMode, activeEstimatorKind)
    }

    // MARK: 내부

    private let defaults: UserDefaults
    /// UI 테스트의 가상 사용자 (일반 실행에서는 nil)
    private let simulation: SimulatedFaceSource?
    private let camera: CameraService
    private let mover = NotificationMover()
    private let overlay = GazeOverlay()
    private let calibrator = CalibrationController()
    private let powerMonitor = PowerMonitor()
    @ObservationIgnored private lazy var settingsWindow = SettingsWindowController(model: self)
    @ObservationIgnored private var filter = OneEuroFilter()
    @ObservationIgnored private var zoneSnapper = ZoneSnapper()
    @ObservationIgnored private var lastFaceTime: TimeInterval = 0
    @ObservationIgnored private var lastPupilOffset: Double?
    @ObservationIgnored private var lastFeatures: FaceFeatures?
    /// 실제 추적값 (알림 이동·오버레이는 항상 이 값을 사용)
    @ObservationIgnored private var latestGaze: Double?
    @ObservationIgnored private var latestRawGaze: Double?
    @ObservationIgnored private var measuredFPS: Double = 0
    @ObservationIgnored private var latestPipeline = PipelineSnapshot()
    @ObservationIgnored private var latestPipelineTime: TimeInterval = 0
    @ObservationIgnored private var latestLiveStats = LiveStats()
    @ObservationIgnored private var historyBuffer = PerformanceHistory()
    @ObservationIgnored private var sampler: Timer?
    @ObservationIgnored private var previousSample: CPUSample?
    @ObservationIgnored private let mainThreadPort = CPUClock.currentThreadPort()
    @ObservationIgnored private var latestModeCosts: [ModeCostKey: ModeCost] = [:]
    @ObservationIgnored private var appliedHz: Double = 0
    @ObservationIgnored private var appliedDetectionInterval = 0
    @ObservationIgnored private let launchTime = CACurrentMediaTime()
    @ObservationIgnored private var processedFrames = 0
    @ObservationIgnored private var rateDurations: [TrackingRate: TimeInterval] = [:]
    @ObservationIgnored private var rateSince = CACurrentMediaTime()
    @ObservationIgnored private var motionAnchor: Double?
    @ObservationIgnored private var motionAnchorTime: TimeInterval = 0
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var fpsWindowStart: TimeInterval = 0
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var inputWatchTimer: Timer?
    @ObservationIgnored private var deviceObservers: [NSObjectProtocol] = []

    private var cameraShouldRun: Bool {
        isEnabled && (placementSource == .gaze || isCalibrating) && (cameraPause == nil || isCalibrating)
    }

    private var cameraRunning: Bool {
        if case .running = cameraStatus { return cameraShouldRun }
        return false
    }

    /// 실시간 값을 SwiftUI 로 흘려보낼지
    private var publishesLiveValues: Bool { isMenuVisible || isSettingsVisible }

    /// - Parameters:
    ///   - defaults: 설정 저장소 (테스트는 따로 만든 저장소를 넘긴다)
    ///   - simulation: 카메라 대신 쓸 가상 사용자 (UI 테스트)
    init(defaults: UserDefaults = AppEnvironment.defaults,
         simulation: SimulatedFaceSource? = AppEnvironment.isUITesting ? SimulatedFaceSource() : nil) {
        self.defaults = defaults
        self.simulation = simulation
        camera = CameraService(simulation: simulation)
        defaults.register(defaults: [
            Keys.enabled: true,
            Keys.follow: true,
            Keys.overlay: false,
            Keys.source: PlacementSource.gaze.rawValue,
            Keys.profile: PerformanceProfile.automatic.rawValue,
            Keys.calibrationPoints: 5,
            Keys.calibrationSeconds: 1.6,
            Keys.adjustOverlay: true,
        ])
        isEnabled = defaults.bool(forKey: Keys.enabled)
        followWhileVisible = defaults.bool(forKey: Keys.follow)
        showOverlay = defaults.bool(forKey: Keys.overlay)
        placementSource = PlacementSource(rawValue: defaults.string(forKey: Keys.source) ?? "") ?? .gaze
        selectedCameraID = defaults.string(forKey: Keys.camera)
        calibration = Self.load(CalibrationSet.self, Keys.calibration, from: defaults)
            ?? Self.load(GazeCalibration.self, Keys.legacyCalibration, from: defaults).map(CalibrationSet.migrated)
        analysisMode = AnalysisMode(rawValue: defaults.string(forKey: Keys.analysisMode) ?? "") ?? .precise
        estimatorChoice = EstimatorChoice(rawValue: defaults.string(forKey: Keys.estimator) ?? "") ?? .automatic
        computePreference = ComputePreference(rawValue: defaults.string(forKey: Keys.computeDevice) ?? "") ?? .automatic
        let savedCosts = Self.load([ModeCostKey: ModeCost].self, Keys.modeCosts, from: defaults) ?? [:]
        modeCosts = savedCosts
        latestModeCosts = savedCosts
        let profile = PerformanceProfile(rawValue: defaults.string(forKey: Keys.profile) ?? "") ?? .automatic
        let custom = (Self.load(PerformanceLimits.self, Keys.customLimits, from: defaults) ?? .balanced).sanitized
        self.profile = profile
        customLimits = custom
        policy = EffectivePolicy.resolve(selected: profile, custom: custom, power: PowerState())
        adjustment = (Self.load(GazeAdjustment.self, Keys.adjustment, from: defaults) ?? GazeAdjustment()).sanitized
        calibrationPointCount = defaults.integer(forKey: Keys.calibrationPoints).clamped(to: 3...9)
        calibrationSeconds = defaults.double(forKey: Keys.calibrationSeconds).clamped(to: 0.8...4)
        showOverlayWhileAdjusting = defaults.bool(forKey: Keys.adjustOverlay)
    }

    func start() {
        Log.info("GazeNotification 시작 (AX 권한: \(accessibilityGranted), 보정: \(calibration != nil))")
        camera.onFeatures = { [weak self] features in self?.handle(features) }
        camera.onStatus = { [weak self] status in self?.cameraStatus = status }
        camera.onFormat = { [weak self] info in self?.cameraFormat = info }
        camera.onVisionDevices = { [weak self] devices in self?.visionDevices = devices }
        camera.onStats = { [weak self] snapshot in
            guard let self else { return }
            self.latestPipeline = snapshot
            self.latestPipelineTime = CACurrentMediaTime()
            self.recordModeCost(snapshot)
            if self.publishesLiveValues { self.pipeline = snapshot }
        }
        camera.setAnalysis(mode: analysisMode, computeAllModes: false)
        camera.setComputePreference(computePreference)
        mover.targetProvider = { [weak self] in self?.placementTarget() }
        mover.followWhileVisible = followWhileVisible
        mover.onMove = { [weak self] message in
            self?.lastEvent = "\(Date().formatted(date: .omitted, time: .standard)) · \(message)"
        }
        mover.onVisibilityChange = { [weak self] visible in
            guard let self else { return }
            self.notificationVisible = visible
            self.applyCaptureRate()
        }
        powerMonitor.onChange = { [weak self] state in self?.powerChanged(state) }
        powerMonitor.start()
        power = powerMonitor.state
        adjustmentChanged(from: adjustment)

        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
        refreshCameras()
        observeCameraDevices()
        if AppEnvironment.usesRealDevices {
            if !accessibilityGranted { Permissions.requestAccessibility() }
            startPermissionPolling()
        }
        startSampler()
        powerChanged(power)
    }

    // MARK: - 동작

    func startCalibration() {
        let count = calibrationPointCount
        let plan = CalibrationPlan(
            title: "시선 보정",
            intro: "화면 위쪽에 점 \(count)개가 왼쪽부터 차례로 나타납니다.\n평소 작업할 때처럼 자연스럽게 바라보세요. 고개를 돌려도 괜찮습니다.",
            targets: CalibrationPlan.evenTargets(count),
            collectDuration: .milliseconds(Int(calibrationSeconds * 1000))
        ) { [weak self] samples in
            guard let self else { return .failure(CalibrationFailure(message: "취소됨")) }
            let targets = CalibrationPlan.evenTargets(count)
            let set = CalibrationSet.fit(samples: samples, targets: targets)
            for mode in AnalysisMode.allCases {
                let summary = EstimatorKind.allCases.compactMap { kind -> String? in
                    guard let model = set.estimator(mode, kind) else { return nil }
                    return String(format: "%@ 학습 %.1f%% 교차 %@", kind.rawValue, model.trainingRMSE * 100,
                                  model.crossValidationRMSE.map { String(format: "%.1f%%", $0 * 100) } ?? "-")
                }
                Log.info("보정 \(mode.rawValue): " + (summary.isEmpty ? "학습 불가" : summary.joined(separator: " · "))
                    + (set.formulaRMSE[mode].map { String(format: " · 기본식 %.1f%%", $0 * 100) } ?? ""))
            }
            let mode = self.analysisMode
            let kind = self.estimatorChoice.kind.flatMap { set.estimator(mode, $0) != nil ? $0 : nil } ?? set.bestKind(for: mode)
            guard let kind, let model = set.estimator(mode, kind) else {
                return .failure(CalibrationFailure(message: "학습에 실패했습니다. 고개와 눈을 조금 더 움직여 점을 바라보세요."))
            }
            let message = String(format: "%@ · %@ · 평균 오차 약 %.1f%%", mode.shortTitle, kind.title,
                                 (model.crossValidationRMSE ?? model.trainingRMSE) * 100)
            return .success(CalibrationOutcome(message: message) { [weak self] in
                self?.applyCalibration(set)
            })
        }
        runCalibration(plan, computeAllModes: true)
    }

    /// 학습한 보정은 그대로 두고, 왼쪽 끝·가운데·오른쪽 끝 세 점으로 좌우 이동과 범위만 맞춘다
    func startQuickAdjust() {
        let targets = [0.04, 0.5, 0.96]
        let gains = adjustment.featureGains
        let model = activeEstimator
        let mode = analysisMode
        let plan = CalibrationPlan(
            title: "빠른 위치 맞춤",
            intro: "점 3개(왼쪽 끝 · 가운데 · 오른쪽 끝)를 차례로 바라보세요.\n학습한 보정은 그대로 두고 좌우 이동과 범위만 다시 맞춥니다.",
            targets: targets,
            collectDuration: .milliseconds(1400)
        ) { [weak self] samples in
            func meanRaw(_ target: Double) -> Double? {
                let raws = samples.filter { $0.target == target }
                    .compactMap { $0.vectors[mode] }
                    .map { model?.predict($0, gains: gains) ?? DefaultGazeModel.predict($0, mode: mode, gains: gains) }
                return raws.isEmpty ? nil : raws.reduce(0, +) / Double(raws.count)
            }
            guard let left = meanRaw(targets[0]), let center = meanRaw(targets[1]), let right = meanRaw(targets[2]) else {
                return .failure(CalibrationFailure(message: "얼굴이 충분히 감지되지 않았습니다."))
            }
            Log.info(String(format: "빠른 위치 맞춤: 모델 출력 왼쪽 %.3f 가운데 %.3f 오른쪽 %.3f", left, center, right))
            switch GazeAdjustment.fit(left: (targets[0], left), center: (targets[1], center), right: (targets[2], right)) {
            case .success(let fit):
                let message = String(format: "좌우 이동 %+.1f%% · 왼쪽 범위 ×%.2f · 오른쪽 범위 ×%.2f",
                                     fit.offset * 100, fit.leftGain, fit.rightGain)
                return .success(CalibrationOutcome(message: message) {
                    guard let self else { return }
                    var adjusted = self.adjustment
                    adjusted.offset = fit.offset
                    adjusted.leftGain = fit.leftGain
                    adjusted.rightGain = fit.rightGain
                    self.adjustment = adjusted
                })
            case .failure(let error):
                return .failure(CalibrationFailure(message: error.message))
            }
        }
        runCalibration(plan)
    }

    /// - Parameter computeAllModes: 모든 분석 방식의 특징을 함께 모은다 (전체 보정)
    private func runCalibration(_ plan: CalibrationPlan, computeAllModes: Bool = false) {
        guard !isCalibrating, isEnabled, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        isCalibrating = true
        camera.setAnalysis(mode: analysisMode, computeAllModes: computeAllModes)
        applyRunState()
        updateTrackingRate(faceFound: faceDetected, now: CACurrentMediaTime())
        overlay.setVisible(false)

        calibrator.begin(on: screen, plan: plan) { [weak self] outcome in
            guard let self else { return }
            self.isCalibrating = false
            self.camera.setAnalysis(mode: self.analysisMode, computeAllModes: false)
            if let outcome {
                outcome.apply()
                self.lastEvent = "\(plan.title) 완료 · \(outcome.message)"
            }
            self.filter.reset()
            self.zoneSnapper.reset()
            self.applyRunState()
            self.updateTrackingRate(faceFound: self.faceDetected, now: CACurrentMediaTime())
        }
    }

    /// 새 보정을 적용·저장한다 (보정 화면이 끝날 때, 테스트에서 직접)
    func applyCalibration(_ set: CalibrationSet) {
        calibration = set
        save(set, Keys.calibration)
        // 이전 보정에 맞춰 손본 좌우 이동·범위는 새 보정에는 맞지 않는다
        if !adjustment.isPositionDefault { adjustment = adjustment.resettingPosition() }
    }

    func resetCalibration() {
        calibration = nil
        defaults.removeObject(forKey: Keys.calibration)
        defaults.removeObject(forKey: Keys.legacyCalibration)
        filter.reset()
        lastEvent = "보정 초기화 — 기본 추정식 사용"
    }

    func resetAdjustment() {
        adjustment = GazeAdjustment()
        lastEvent = "수동 보정값 초기화"
    }

    /// UI 에서 제한값을 바꾸면 지금 적용 중인 값에서 시작해 사용자 지정 프로필로 전환한다
    func editLimits(_ edit: (inout PerformanceLimits) -> Void) {
        var limits = policy.limits
        edit(&limits)
        customLimits = limits.sanitized
        if profile != .custom { profile = .custom }
    }

    func openSettings(_ tab: SettingsTab) {
        settingsTab = tab
        settingsWindow.show()
    }

    /// `delay` 초 뒤 GazeNotification 이름으로 테스트 알림. 그 사이 원하는 곳을 바라보면 된다.
    /// (osascript 알림은 Script Editor 알림이 꺼져 있으면 조용히 버려져서 직접 보낸다)
    func sendTestNotification(after delay: TimeInterval = 3) {
        guard AppEnvironment.usesRealDevices else {
            lastEvent = "테스트 알림 — 테스트 모드에서는 보내지 않음"
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard granted else {
                    self.lastEvent = "알림 권한이 없습니다 — 시스템 설정 → 알림 → GazeNotification 허용"
                    Log.error("알림 권한 거부: \(error?.localizedDescription ?? "-")")
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = "GazeNotification 테스트"
                content.body = "보고 있던 곳에 알림이 떴나요?"
                content.sound = .default
                let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false) : nil
                let request = UNNotificationRequest(identifier: "gazenotification.test.\(UUID().uuidString)",
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
        let cpu = historyBuffer.samples.last
        Log.info(String(format: "STATUS pipeline 수신 %.1f/s 처리 %.1f/s (목표 %.1f) 검출 %.1f/s 랜드마크 %.1f/s | 검출 %.1fms(CPU %.1f) 랜드마크 %.1fms(CPU %.1f) 특징 %.2fms | CPU 전체 %.1f%% 추적 %.1f%% 메인 %.1f%%",
                        p.receivedFPS, p.processedFPS, appliedHz, p.detectFPS, p.landmarksFPS, p.detectWallMs, p.detectCPUms,
                        p.landmarksWallMs, p.landmarksCPUms, p.featuresCPUms,
                        cpu?.processCPU ?? 0, cpu?.trackingCPU ?? 0, cpu?.mainCPU ?? 0))
        Log.info("STATUS enabled=\(isEnabled) source=\(placementSource.rawValue) camera=\(cameraStatus) pause=\(cameraPause.map { "\($0)" } ?? "none") "
            + "profile=\(policy.applied.rawValue)(\(policy.reason ?? "-")) governor=\(String(format: "%.2f", governorScale)) "
            + "face=\(faceDetected) gazeX=\(gaze) fps=\(String(format: "%.1f", measuredFPS)) rate=\(trackingRate) menu=\(isMenuVisible) settings=\(isSettingsVisible) ax=\(accessibilityGranted) "
            + "ai=\(analysisMode.rawValue)/\(activeEstimatorKind.rawValue)/\(visionDevices.detection) "
            + "calibrated=\(calibration != nil) mover=\(mover.isRunning) features[\(features)]")
    }

    func openLogFolder() {
        try? FileManager.default.createDirectory(at: Log.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Log.directory)
    }

    // MARK: - 내부 처리

    private func applyRunState() {
        if cameraShouldRun {
            if !cameraRunning { lastFaceTime = CACurrentMediaTime() }
            startCameraIfAuthorized()
        } else {
            camera.stop()
            faceDetected = false
            latestPipeline = PipelineSnapshot()
            if publishesLiveValues { pipeline = latestPipeline }
        }

        // UI 테스트에서는 실제 NotificationCenter 창을 건드리지 않는다
        if isEnabled && accessibilityGranted && simulation == nil {
            mover.start()
        } else {
            mover.stop()
        }
        mover.isPaused = power.screenUnavailable
        updateOverlayVisibility()
    }

    private func startCameraIfAuthorized() {
        if simulation != nil { return camera.start(deviceID: nil) }
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
        let wanted = isEnabled && placementSource == .gaze && !isCalibrating && cameraPause == nil
            && (showOverlay || (isAdjusting && showOverlayWhileAdjusting))
        overlay.setVisible(wanted)
        overlay.update(normalizedX: latestGaze, faceDetected: faceDetected)
        updateTrackingRate(faceFound: faceDetected, now: CACurrentMediaTime())
    }

    private func placementTarget() -> Double? {
        switch placementSource {
        case .gaze: latestGaze
        case .mouse: NSScreen.normalizedMouseX()
        }
    }

    private func handle(_ features: FaceFeatures?) {
        // 가상 사용자는 보정 중이면 화면의 점을 본다
        simulation?.lookTarget = calibrator.currentTarget
        countFrame()
        processedFrames += 1
        calibrator.ingest(features, mode: analysisMode)

        guard var features else {
            let now = CACurrentMediaTime()
            if faceDetected, now - lastFaceTime > 0.6 {
                faceDetected = false
                overlay.update(normalizedX: latestGaze, faceDetected: false)
            }
            updateTrackingRate(faceFound: false, now: now)
            return
        }

        lastFaceTime = features.timestamp
        lastFeatures = features
        if !faceDetected { faceDetected = true }
        // 눈 깜빡임 등으로 동공이 빠진 프레임은 직전 값으로 채운다
        if let pupil = features.pupilOffset { lastPupilOffset = pupil } else { features.pupilOffset = lastPupilOffset }

        // 모델 출력 → 손으로 맞춘 이동·범위 → 스무딩 → 구역 맞춤
        let gains = adjustment.featureGains
        let estimator = activeEstimator
        let raw = estimator?.predict(features.vector, gains: gains)
            ?? DefaultGazeModel.predict(features.vector, mode: analysisMode, gains: gains)
        let adjusted = adjustment.mapPosition(raw)
        let smoothed = filter.filter(adjusted.clamped(to: -0.1...1.1), timestamp: features.timestamp)
        var gaze = smoothed.clamped(to: 0...1)
        if adjustment.zones > 1 { gaze = zoneSnapper.snap(gaze, zones: adjustment.zones) }
        latestGaze = gaze
        latestRawGaze = raw.clamped(to: 0...1)
        if publishesLiveValues {
            gazeX = latestGaze
            rawGazeX = latestRawGaze
            var breakdown = estimator?.breakdown(features, gains: gains)
                ?? DefaultGazeModel.breakdown(features, mode: analysisMode, gains: gains)
            breakdown.adjusted = adjusted
            breakdown.filtered = gaze
            gazeBreakdown = breakdown
        }
        overlay.update(normalizedX: latestGaze, faceDetected: true)
        updateTrackingRate(faceFound: true, now: features.timestamp)
    }

    /// 모델·방식이 바뀌면 이전 값으로 스무딩하지 않도록
    private func resetTracking() {
        filter.reset()
        zoneSnapper.reset()
        lastPupilOffset = nil
    }

    /// 처리 1회당 비용을 방식·장치별로 지수 평균해 둔다 (AI 모드 비교표)
    private func recordModeCost(_ snapshot: PipelineSnapshot) {
        guard snapshot.processedFPS > 0, !isCalibrating else { return }
        let key = ModeCostKey(mode: snapshot.mode, device: snapshot.devices.preference)
        var cost = latestModeCosts[key] ?? ModeCost(cpuMs: snapshot.cpuPerFrameMs, wallMs: snapshot.wallPerFrameMs, samples: 0)
        cost.cpuMs = cost.cpuMs * 0.8 + snapshot.cpuPerFrameMs * 0.2
        cost.wallMs = cost.wallMs * 0.8 + snapshot.wallPerFrameMs * 0.2
        cost.samples += 1
        cost.detectionShare = snapshot.processedFPS > 0 ? snapshot.detectFPS / snapshot.processedFPS : 0
        latestModeCosts[key] = cost
        if publishesLiveValues { modeCosts = latestModeCosts }
    }

    private func adjustmentChanged(from old: GazeAdjustment) {
        filter.minCutoff = adjustment.smoothing
        filter.beta = adjustment.responsiveness
        mover.followThreshold = adjustment.followThreshold
        if old.zones != adjustment.zones { zoneSnapper.reset() }
    }

    /// 상황별 추적 속도 단계. 단계별 처리 횟수는 `PerformanceLimits` 가 정한다.
    private func updateTrackingRate(faceFound: Bool, now: TimeInterval) {
        let l = limits
        let rate: TrackingRate
        if cameraPause != nil && !isCalibrating {
            rate = .paused
        } else if isCalibrating || isPreviewVisible || isAdjusting {
            rate = .live
        } else if !faceFound {
            let keep = trackingRate == .live || trackingRate == .paused ? .normal : trackingRate
            rate = now - lastFaceTime > l.awayAfter ? .away : keep
        } else if let gaze = latestGaze, let anchor = motionAnchor, abs(gaze - anchor) < 0.06 {
            rate = now - motionAnchorTime > l.stillAfter ? .still : .normal
        } else {
            motionAnchor = latestGaze
            motionAnchorTime = now
            rate = .normal
        }
        if rate != trackingRate {
            let changedAt = CACurrentMediaTime()
            rateDurations[trackingRate, default: 0] += changedAt - rateSince
            rateSince = changedAt
            trackingRate = rate
        }
        applyCaptureRate()
    }

    /// 단계별 처리 횟수 × CPU 상한 비율 → 카메라. 같은 값이면 아무것도 하지 않는다 (프레임마다 호출됨).
    private func applyCaptureRate() {
        guard trackingRate != .paused else { return }
        let l = limits
        var hz = trackingRate.baseHz(l)
        if notificationVisible, l.boostWhileNotification, trackingRate == .normal || trackingRate == .still {
            hz = max(hz, l.activeHz)
        }
        if trackingRate != .live { hz = max(0.2, hz * governorScale) }
        let detection = trackingRate == .live ? 1 : l.detectionInterval
        guard abs(hz - appliedHz) > 0.001 || detection != appliedDetectionInterval else { return }
        appliedHz = hz
        appliedDetectionInterval = detection
        camera.setProcessing(hz: hz, detectionInterval: detection)
        if publishesLiveValues { targetHz = hz }
    }

    private func applyPolicy() {
        let next = EffectivePolicy.resolve(selected: profile, custom: customLimits, power: power)
        guard next != policy else { return }
        if next.applied != policy.applied || next.reason != policy.reason {
            Log.info("성능 프로필: \(next.applied.title)" + (next.reason.map { " (\($0))" } ?? ""))
        }
        policy = next
        mover.idleCheckHz = next.limits.notificationCheckHz
        if next.limits.cpuLimit == 0, governor.update(.off, limit: 0) { governorScale = governor.scale }
        if cameraPause == .absence, next.limits.cameraOffAfterAway == 0 { resumeCamera(reason: "자동으로 끄기 해제") }
        updateTrackingRate(faceFound: faceDetected, now: CACurrentMediaTime())
    }

    // MARK: - 전원 상태

    private func powerChanged(_ state: PowerState) {
        power = state
        if state.screenUnavailable {
            if cameraPause != .screen {
                cameraPause = .screen
                stopInputWatch()
                Log.info("화면 꺼짐/잠김 — 카메라 끔")
            }
        } else if cameraPause == .screen {
            // 잠금을 풀었다면 사람이 돌아온 것 → 자리 비움으로 꺼 둔 것도 함께 해제
            cameraPause = nil
            Log.info("화면 켜짐 — 카메라 다시 켬")
        }
        applyPolicy()
        mover.idleCheckHz = limits.notificationCheckHz
        applyRunState()
        updateTrackingRate(faceFound: faceDetected, now: CACurrentMediaTime())
    }

    /// 자리 비움이 `cameraOffAfterAway` 분 넘게 이어지면 카메라를 끄고 입력을 기다린다
    private func checkAbsence(now: TimeInterval) {
        let minutes = limits.cameraOffAfterAway
        guard cameraPause == nil, minutes > 0, cameraRunning, trackingRate == .away,
              now - lastFaceTime > minutes * 60 else { return }
        cameraPause = .absence
        Log.info("자리 비움 \(Int(minutes))분 — 카메라 끔 (입력이 생기면 다시 켬)")
        lastEvent = "오래 자리를 비워 카메라를 껐습니다 — 키보드·마우스를 쓰면 다시 켭니다"
        applyRunState()
        updateTrackingRate(faceFound: false, now: now)
        startInputWatch()
    }

    private func startInputWatch() {
        stopInputWatch()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Self.secondsSinceLastInput() < 1.5 { self.resumeCamera(reason: "입력 감지") }
            }
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        inputWatchTimer = timer
    }

    private func stopInputWatch() {
        inputWatchTimer?.invalidate()
        inputWatchTimer = nil
    }

    private func resumeCamera(reason: String) {
        guard cameraPause == .absence else { return }
        stopInputWatch()
        cameraPause = nil
        Log.info("카메라 다시 켬 (\(reason))")
        applyRunState()
        updateTrackingRate(faceFound: false, now: CACurrentMediaTime())
    }

    private static func secondsSinceLastInput() -> TimeInterval {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .keyDown, .scrollWheel, .leftMouseDragged, .flagsChanged]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
    }

    // MARK: - 1초마다: 성능 기록, CPU 상한, 메뉴 요약

    private struct CPUSample {
        var time: CFTimeInterval
        var process: Double
        var main: Double
        var mover: MoverStatus
    }

    private func startSampler() {
        previousSample = CPUSample(time: CACurrentMediaTime(), process: CPUClock.process(),
                                   main: CPUClock.thread(mainThreadPort), mover: mover.status())
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordSample() }
        }
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        sampler = timer
    }

    private func recordSample() {
        let now = CACurrentMediaTime()
        let current = CPUSample(time: now, process: CPUClock.process(), main: CPUClock.thread(mainThreadPort),
                                mover: mover.status())
        guard let previous = previousSample, now > previous.time else {
            previousSample = current
            return
        }
        previousSample = current
        let dt = now - previous.time
        let processCPU = (current.process - previous.process) / dt * 100
        let mainCPU = (current.main - previous.main) / dt * 100
        let trackingCPU = max(0, processCPU - mainCPU)
        func perSecond(_ value: (MoverStatus) -> Int) -> Double {
            Double(value(current.mover) - value(previous.mover)) / dt
        }

        updateGovernor(trackingCPU: trackingCPU)

        let pipelineFresh = cameraRunning && now - latestPipelineTime < 2.5
        let p = pipelineFresh ? latestPipeline : PipelineSnapshot()
        let sample = { (id: Int) in
            PerformanceSample(
                id: id, time: Date(), processCPU: processCPU, trackingCPU: trackingCPU, mainCPU: mainCPU,
                processedHz: p.processedFPS, detectHz: p.detectFPS, receivedFPS: p.receivedFPS,
                targetHz: self.cameraRunning ? self.appliedHz : 0,
                detectMs: p.detectWallMs, landmarksMs: p.landmarksWallMs,
                notificationChecksPerSecond: perSecond(\.windowChecks), axCallsPerSecond: perSecond(\.axCalls),
                rate: self.trackingRate, profile: self.policy.applied, governorScale: self.governorScale,
                analysisMode: self.analysisMode)
        }
        // 시작 직후 10초는 Vision 모델 로드(일회성)로 CPU 가 튀어 그래프 눈금을 망가뜨리므로 기록하지 않는다
        if now - launchTime > 10 { historyBuffer.append(sample) }

        var stats = LiveStats()
        stats.processCPUPercent = processCPU
        stats.trackingCPUPercent = trackingCPU
        stats.mainCPUPercent = mainCPU
        stats.windowChecksPerSecond = perSecond(\.windowChecks)
        stats.axCallsPerSecond = perSecond(\.axCalls)
        stats.movesPerSecond = perSecond(\.moves)
        stats.ticksPerSecond = perSecond(\.ticks)
        stats.mover = current.mover
        let uptime = now - launchTime
        stats.uptime = uptime
        stats.averageProcessedFPS = uptime > 0 ? Double(processedFrames) / uptime : 0
        var durations = rateDurations
        durations[trackingRate, default: 0] += now - rateSince
        let total = durations.values.reduce(0, +)
        stats.rateShare = total > 0 ? durations.mapValues { $0 / total } : [:]
        latestLiveStats = stats

        if isMenuVisible { liveStats = stats }
        if isSettingsVisible { history = historyBuffer.samples }
        if publishesLiveValues, !pipelineFresh { pipeline = p }
        checkAbsence(now: now)
    }

    /// 카메라·AI CPU(메인 스레드 제외)가 상한을 넘으면 처리 횟수를 비례해 줄인다 (`CPUGovernor`).
    /// 보정·미리보기(실시간) 중에는 적용하지 않는다.
    private func updateGovernor(trackingCPU: Double) {
        let limit = limits.cpuLimit
        let input: CPUGovernor.Input
        if limit == 0 || !cameraRunning {
            input = .off
        } else if trackingRate == .live || trackingRate == .paused {
            input = .hold
        } else {
            input = .measured(trackingCPU)
        }
        guard governor.update(input, limit: limit) else { return }
        governorScale = governor.scale
        applyCaptureRate()
    }

    /// 메뉴·설정 창이 열릴 때 그동안 쌓인 값을 한 번에 넘긴다
    private func publishLiveValues() {
        gazeX = latestGaze
        rawGazeX = latestRawGaze
        pipeline = latestPipeline
        targetHz = appliedHz
        history = historyBuffer.samples
        modeCosts = latestModeCosts
    }

    /// 앱 종료 시 알림 창을 원래 위치로 되돌리고 카메라를 끈다. AI 모드 비교용 측정값은 남겨 둔다.
    func shutdown() {
        mover.stop()
        camera.stop()
        save(latestModeCosts, Keys.modeCosts)
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
        cameras = simulation == nil ? CameraService.availableCameras() : [CameraInfo(id: "simulated", name: SimulatedFaceSource.deviceName)]
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

    /// 손쉬운 사용 권한은 변경 알림이 없어서 주기적으로 확인한다 (허용된 뒤에는 드물게).
    private func startPermissionPolling() {
        permissionTimer?.invalidate()
        let interval: TimeInterval = accessibilityGranted ? 10 : 1.5
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let trusted = Permissions.accessibilityTrusted
                if trusted != self.accessibilityGranted {
                    self.accessibilityGranted = trusted
                    Log.info("손쉬운 사용 권한 변경: \(trusted)")
                    self.applyRunState()
                    self.startPermissionPolling()
                }
            }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    // MARK: - 저장

    /// 보정 샘플에는 빠진 값(NaN)이 있어 JSON 에 문자열로 적는다
    private static func load<T: Decodable>(_ type: T.Type, _ key: String, from defaults: UserDefaults) -> T? {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return defaults.data(forKey: key).flatMap { try? decoder.decode(T.self, from: $0) }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        do {
            defaults.set(try encoder.encode(value), forKey: key)
        } catch {
            Log.error("설정 저장 실패(\(key)): \(error.localizedDescription)")
        }
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

/// 추적 속도 단계. 단계별 처리 횟수는 `PerformanceLimits` 에서 정한다.
enum TrackingRate: CaseIterable {
    case live, normal, still, away, paused

    /// 보정·미리보기·보정 조정 중 처리 횟수/s (CPU 상한·프로필과 무관)
    static let liveHz: Double = 10

    var title: String {
        switch self {
        case .live: "실시간"
        case .normal: "움직임"
        case .still: "머묾"
        case .away: "자리 비움"
        case .paused: "카메라 꺼짐"
        }
    }

    var reason: String {
        switch self {
        case .live: "보정 중이거나 카메라 미리보기·보정 조정 화면을 보는 중"
        case .normal: "얼굴이 보이고 시선이 움직이는 중"
        case .still: "시선이 한곳에 머묾"
        case .away: "얼굴이 보이지 않음"
        case .paused: "화면이 꺼졌거나 오래 자리를 비움"
        }
    }

    func baseHz(_ limits: PerformanceLimits) -> Double {
        switch self {
        case .live: Self.liveHz
        case .normal: limits.activeHz
        case .still: limits.stillHz
        case .away: limits.awayHz
        case .paused: 0
        }
    }
}

/// 메뉴에 1초마다 보여 주는 요약
struct LiveStats: Equatable {
    /// GazeNotification 프로세스 전체 CPU (코어 1개 = 100%)
    var processCPUPercent: Double = 0
    /// 메인 스레드를 뺀 CPU (카메라·Vision·Neural Engine 드라이버)
    var trackingCPUPercent: Double = 0
    /// 메인 스레드 CPU (UI·알림 감시)
    var mainCPUPercent: Double = 0
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

/// AI 모드 비교표의 한 칸 (분석 방식 × 연산 장치)
struct ModeCostKey: Hashable, Codable {
    var mode: AnalysisMode
    var device: ComputePreference
}

/// 처리 1회당 평균 비용 (검출·랜드마크·특징 합, 추적 프레임 포함)
struct ModeCost: Equatable, Codable {
    var cpuMs: Double
    var wallMs: Double
    var samples: Int
    /// 처리 중 전체 얼굴 검출 비율
    var detectionShare: Double = 0
}
