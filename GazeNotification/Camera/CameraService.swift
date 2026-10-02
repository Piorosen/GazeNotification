import AVFoundation
import QuartzCore

struct CameraInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

enum CameraStatus: Equatable {
    case idle
    case unauthorized
    case noDevice
    case running(String)
    case failed(String)
}

/// AVCaptureSession 을 관리하고 프레임마다 `FaceFeatureExtractor` 를 돌린다.
/// 세션 조작은 sessionQueue, 프레임 처리는 videoQueue, 콜백은 메인 스레드.
///
/// 자원 절약:
/// - 세션 preset(내부 스케일링) 대신 카메라가 직접 내보내는 포맷을 고른다. 가능하면 **비압축**(MJPEG 디코딩 없음)
///   16:9, 폭 ~800 으로, 장치 프레임레이트 자체를 목표 처리 횟수에 맞춰 낮춘다 (장치가 지원하는 값 중 그 이상인 가장 낮은 값).
/// - 처리 여부는 **시간 기준**으로 정한다 (`setProcessing(hz:)`). 장치가 5fps 밑으로 못 내려가거나,
///   다른 앱·미리보기 때문에 장치 fps 가 바뀌어도 Vision 처리 횟수는 목표값을 넘지 않는다.
/// - macOS 의 세션은 연결이 바뀔 때(미리보기를 붙이거나 뗄 때 등) 장치 포맷·fps 를 preset 기본값(30fps)으로 되돌린다.
///   그래서 받은 프레임 수를 감시해 설정과 다르면 다시 적용한다 (`checkFrameRate`, `reapplyFormat`).
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    /// 메인 스레드에서 호출. 얼굴이 없으면 nil.
    var onFeatures: (@MainActor (FaceFeatures?) -> Void)?
    var onStatus: (@MainActor (CameraStatus) -> Void)?
    /// 약 1초마다 처리 통계 (메인 스레드)
    var onStats: (@MainActor (PipelineSnapshot) -> Void)?
    /// 카메라 포맷이 적용될 때 (메인 스레드)
    var onFormat: (@MainActor (CameraFormatInfo) -> Void)?

    /// Vision 요청에 실제로 지정된 장치가 바뀔 때 (메인 스레드)
    var onVisionDevices: (@MainActor (VisionDevices) -> Void)?

    private let sessionQueue = DispatchQueue(label: "gazenotification.camera.session")
    private let videoQueue = DispatchQueue(label: "gazenotification.camera.video", qos: .utility)
    private let output = AVCaptureVideoDataOutput()
    private let extractor = FaceFeatureExtractor()
    private var currentInput: AVCaptureDeviceInput?

    /// 목표 캡처 폭. 800 이면 C922 기준 800x448 비압축(yuvs) 포맷이 선택된다.
    private let targetWidth: Int32 = 800
    private let outputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    // sessionQueue 전용
    /// 목표 처리 횟수/s (장치 fps 를 고르는 기준)
    private var requestedHz: Double = 5
    /// 실제로 적용한 장치 fps
    private var appliedDeviceFPS: Double = 0
    private var watchdogFixes = 0

    // videoQueue 전용
    private var statsWindow = StatsWindow()
    private var processingInterval: Double = 0.2
    private var targetHz: Double = 5
    private var nextDue: CFTimeInterval = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var frameInterval: Double = 0.2
    /// 장치가 보내야 하는 fps (감시용)
    private var expectedFPS: Double = 0
    private var overrunWindows = 0
    private var lastWatchdogFix: CFTimeInterval = 0
    private var watchdogFixesSnapshot = 0

    // MARK: - 장치 목록

    private static func discoverDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// 실제 웹캠 > 내장 카메라 > iPhone > 가상 카메라(OBS 등) 순서.
    private static func rank(_ device: AVCaptureDevice) -> Int {
        let name = device.localizedName.lowercased()
        if name.contains("virtual") || device.modelID.lowercased().contains("obs") { return 3 }
        switch device.deviceType {
        case .external: return 0
        case .builtInWideAngleCamera: return 1
        default: return 2
        }
    }

    static func availableCameras() -> [CameraInfo] {
        discoverDevices()
            .sorted { rank($0) < rank($1) }
            .map { CameraInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// 폭이 target 에 가깝고, 16:9 이고, 비압축(yuvs/2vuy)이고, 원하는 처리 횟수 이상의 fps 를 낼 수 있는 포맷을 우선한다.
    private static func bestFormat(for device: AVCaptureDevice, targetWidth: Int32, hz: Double) -> AVCaptureDevice.Format? {
        let uncompressed: Set<FourCharCode> = [kCVPixelFormatType_422YpCbCr8_yuvs, kCVPixelFormatType_422YpCbCr8]
        func score(_ format: AVCaptureDevice.Format) -> (Int, Int32, Int, Int) {
            let d = format.formatDescription.dimensions
            let widthBucket = abs(d.width - targetWidth) / 100
            let aspect = abs(Double(d.width) / Double(max(d.height, 1)) - 16.0 / 9.0) < 0.06 ? 0 : 1
            let compressed = uncompressed.contains(format.formatDescription.mediaSubType.rawValue) ? 0 : 1
            let tooSlow = format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= hz - 0.01 } ? 0 : 1
            return (tooSlow, widthBucket, aspect, compressed)
        }
        return device.formats
            .filter { $0.formatDescription.dimensions.width >= 480 && !$0.videoSupportedFrameRateRanges.isEmpty }
            .min { score($0) < score($1) }
    }

    /// 지원 범위 중 hz 이상인 가장 낮은 fps 와 그 프레임 간격. 없으면 가장 높은 fps.
    /// UVC 웹캠은 5/7.5/10/15/… 처럼 띄엄띄엄 지원하므로, 범위 끝값은 장치가 알려 준 간격을 그대로 쓴다
    /// (지원하지 않는 간격을 넣으면 예외로 앱이 죽는다).
    static func deviceRate(for hz: Double, in ranges: [AVFrameRateRange]) -> (fps: Double, duration: CMTime)? {
        var best: (fps: Double, duration: CMTime)?
        for range in ranges {
            let candidate: (Double, CMTime)
            if hz <= range.minFrameRate {
                candidate = (range.minFrameRate, range.maxFrameDuration)
            } else if hz < range.maxFrameRate {
                candidate = (hz, CMTime(seconds: 1 / hz, preferredTimescale: 1_000_000))
            } else if abs(hz - range.maxFrameRate) < 0.01 {
                candidate = (range.maxFrameRate, range.minFrameDuration)
            } else {
                continue
            }
            if best == nil || candidate.0 < best!.fps { best = candidate }
        }
        if let best { return best }
        guard let fastest = ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return nil }
        return (fastest.maxFrameRate, fastest.minFrameDuration)
    }

    // MARK: - 제어

    /// deviceID 가 nil 이거나 연결되어 있지 않으면 우선순위가 가장 높은 카메라를 쓴다.
    func start(deviceID: String?) {
        sessionQueue.async { [self] in
            configure(deviceID: deviceID)
            guard let device = currentInput?.device else { return }
            if !session.isRunning { session.startRunning() }
            // 세션이 시작되면서 장치 포맷/프레임레이트를 기본값으로 되돌리므로 시작 후 다시 적용한다.
            applyFormat(to: device)
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning { session.stopRunning() }
            appliedDeviceFPS = 0
            watchdogFixes = 0
            videoQueue.async { self.expectedFPS = 0; self.watchdogFixesSnapshot = 0 }
            report(.idle)
        }
    }

    /// 얼굴 분석 방식과, 보정 중이면 모든 방식의 특징을 함께 계산할지
    func setAnalysis(mode: AnalysisMode, computeAllModes: Bool) {
        videoQueue.async { [self] in
            extractor.mode = mode
            extractor.computeAllModes = computeAllModes
        }
    }

    /// Vision 신경망을 돌릴 장치
    func setComputePreference(_ preference: ComputePreference) {
        videoQueue.async { [self] in
            extractor.setComputePreference(preference)
            let devices = extractor.devices
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.onVisionDevices?(devices) }
            }
        }
    }

    /// 세션 연결이 바뀐 직후(미리보기 열고 닫기) 장치 포맷·fps 를 다시 적용한다.
    func reapplyFormat(after delay: TimeInterval = 0.5) {
        sessionQueue.asyncAfter(deadline: .now() + delay) { [self] in
            guard let device = currentInput?.device, session.isRunning else { return }
            applyFormat(to: device)
        }
    }

    /// 목표 Vision 처리 횟수/s 와 얼굴 검출 간격을 바꾼다.
    /// 장치 fps 도 지원 범위 안에서 그 이상인 가장 낮은 값으로 맞춘다 (USB 전송·드라이버·프레임 전달 비용까지 줄어듦).
    func setProcessing(hz: Double, detectionInterval: Int) {
        let hz = max(hz, 0.05)
        videoQueue.async { [self] in
            let interval = 1 / hz
            // 빨라질 때는 다음 프레임을 바로 처리
            if interval < processingInterval { nextDue = 0 }
            processingInterval = interval
            targetHz = hz
            extractor.detectionInterval = max(1, detectionInterval)
        }
        sessionQueue.async { [self] in
            guard abs(hz - requestedHz) > 0.001 else { return }
            requestedHz = hz
            if let device = currentInput?.device, session.isRunning { applyFormat(to: device) }
        }
    }

    private func configure(deviceID: String?) {
        let requested = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) }.flatMap { $0.isConnected ? $0 : nil }
        guard let device = requested ?? Self.discoverDevices().min(by: { Self.rank($0) < Self.rank($1) }) else {
            if let currentInput {
                session.beginConfiguration()
                session.removeInput(currentInput)
                session.commitConfiguration()
                self.currentInput = nil
            }
            report(.noDevice)
            return
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let deviceChanged = currentInput?.device.uniqueID != device.uniqueID || currentInput?.device.isConnected == false
        if deviceChanged {
            if let currentInput { session.removeInput(currentInput) }
            currentInput = nil
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    report(.failed("입력을 추가할 수 없음: \(device.localizedName)"))
                    return
                }
                session.addInput(input)
                currentInput = input
            } catch {
                report(.failed(error.localizedDescription))
                return
            }
        }

        if !session.outputs.contains(output) {
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(output) { session.addOutput(output) }
        }
        let pixelFormat = output.availableVideoPixelFormatTypes.contains(outputPixelFormat)
            ? outputPixelFormat : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        applyFormat(to: device)

        // 특징값의 부호가 일정하도록 항상 미러링하지 않은 원본을 받는다.
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }

        Log.info("카메라 사용: \(device.localizedName)")
        report(.running(device.localizedName))
    }

    /// 장치가 직접 내보내는 포맷을 고정하고(스케일링·MJPEG 디코딩 회피) 장치 프레임레이트를 목표 처리 횟수에 맞춘다.
    /// - Parameter force: 값이 같아 보여도 다시 설정 (장치 fps 가 몰래 바뀐 경우)
    private func applyFormat(to device: AVCaptureDevice, force: Bool = false) {
        guard let format = Self.bestFormat(for: device, targetWidth: targetWidth, hz: requestedHz),
              let rate = Self.deviceRate(for: requestedHz, in: format.videoSupportedFrameRateRanges) else { return }
        let formatChanged = device.activeFormat != format
        let rateChanged = device.activeVideoMinFrameDuration != rate.duration || device.activeVideoMaxFrameDuration != rate.duration
        guard force || formatChanged || rateChanged || appliedDeviceFPS == 0 else { return }
        do {
            try device.lockForConfiguration()
            if formatChanged { device.activeFormat = format }
            device.activeVideoMinFrameDuration = rate.duration
            device.activeVideoMaxFrameDuration = rate.duration
            device.unlockForConfiguration()
        } catch {
            Log.error("카메라 포맷 설정 실패: \(error.localizedDescription)")
            return
        }
        let d = format.formatDescription.dimensions
        var settings = output.videoSettings ?? [:]
        // 출력도 원본 크기로 고정 → 추가 스케일링 없음
        if settings[kCVPixelBufferWidthKey as String] as? Int != Int(d.width)
            || settings[kCVPixelBufferHeightKey as String] as? Int != Int(d.height) {
            settings[kCVPixelBufferWidthKey as String] = Int(d.width)
            settings[kCVPixelBufferHeightKey as String] = Int(d.height)
            output.videoSettings = settings
        }

        let fps = rate.fps
        appliedDeviceFPS = fps
        videoQueue.async { [self] in
            expectedFPS = fps
            frameInterval = 1 / fps
            overrunWindows = 0
        }
        let active = device.activeFormat.formatDescription
        let outFormat = (output.videoSettings?[kCVPixelBufferPixelFormatTypeKey as String] as? OSType).map(fourCC) ?? "?"
        let info = CameraFormatInfo(deviceName: device.localizedName,
                                    width: Int(active.dimensions.width), height: Int(active.dimensions.height),
                                    sourceFormat: fourCC(active.mediaSubType.rawValue),
                                    outputFormat: outFormat, deviceFPS: fps,
                                    supportedFPS: format.videoSupportedFrameRateRanges.map(\.maxFrameRate).sorted())
        if formatChanged || force {
            Log.info("카메라 포맷: \(info.width)x\(info.height) \(info.sourceFormat) @\(info.fpsText)fps → 출력 \(outFormat)")
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onFormat?(info) }
        }
    }

    /// 받은 프레임이 설정보다 훨씬 많으면 장치 fps 가 바뀐 것 → 다시 적용. 다른 앱이 같은 카메라를 쓰면
    /// 계속 되돌아가므로 세 번 실패하면 1분에 한 번만 시도한다 (그동안도 처리 횟수는 시간 기준으로 제한됨).
    private func checkFrameRate(received: Double, now: CFTimeInterval) {
        guard expectedFPS > 0, received > expectedFPS * 1.4 + 0.5 else {
            overrunWindows = 0
            return
        }
        overrunWindows += 1
        let backoff: CFTimeInterval = watchdogFixesSnapshot >= 3 ? 60 : 10
        guard overrunWindows >= 2, now - lastWatchdogFix > backoff else { return }
        overrunWindows = 0
        lastWatchdogFix = now
        let expected = expectedFPS
        sessionQueue.async { [self] in
            guard let device = currentInput?.device, session.isRunning else { return }
            watchdogFixes += 1
            let fixes = watchdogFixes
            videoQueue.async { self.watchdogFixesSnapshot = fixes }
            if fixes <= 3 {
                Log.info(String(format: "카메라가 %.0ffps 로 보내는 중 (설정 %.1ffps) — 다시 적용", received, expected)
                    + (fixes == 3 ? " · 다른 앱이 카메라를 쓰는 중일 수 있어 이후엔 1분마다 시도" : ""))
            }
            applyFormat(to: device, force: true)
        }
    }

    private func report(_ status: CameraStatus) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onStatus?(status) }
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        statsWindow.received += 1
        if lastFrameTime > 0 { frameInterval = frameInterval * 0.8 + min(now - lastFrameTime, 1) * 0.2 }
        lastFrameTime = now
        defer { flushStatsIfNeeded(now: now) }

        // 시간 기준 처리: 다음 처리 시각(반 프레임 여유)이 되기 전 프레임은 버린다
        guard now + frameInterval * 0.5 >= nextDue else { return }
        nextDue = now - nextDue > processingInterval ? now + processingInterval : nextDue + processingInterval

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let extraction = extractor.extract(from: pixelBuffer, timestamp: now)
        statsWindow.add(extraction)
        let features = extraction.features
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onFeatures?(features) }
        }
    }

    private func flushStatsIfNeeded(now: CFTimeInterval) {
        if statsWindow.start == 0 { statsWindow.start = now }
        let elapsed = now - statsWindow.start
        guard elapsed >= 1 else { return }
        var snapshot = statsWindow.snapshot(elapsed: elapsed)
        snapshot.targetHz = targetHz
        snapshot.deviceFPS = expectedFPS
        snapshot.detectionInterval = extractor.mode == .headPose ? 1 : extractor.detectionInterval
        snapshot.mode = extractor.mode
        snapshot.devices = extractor.devices
        statsWindow = StatsWindow(start: now)
        checkFrameRate(received: snapshot.receivedFPS, now: now)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onStats?(snapshot) }
        }
    }
}

private func fourCC(_ value: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
}

struct CameraFormatInfo: Equatable, Sendable {
    var deviceName: String
    var width: Int
    var height: Int
    /// 카메라가 보내는 포맷 (yuvs = 비압축 YUV 4:2:2, 420v = MJPEG 디코딩 결과)
    var sourceFormat: String
    /// 앱이 받는 픽셀 포맷
    var outputFormat: String
    var deviceFPS: Double
    /// 이 포맷에서 장치가 낼 수 있는 fps
    var supportedFPS: [Double] = []

    var fpsText: String { formatFPS(deviceFPS) }
}

/// 30.00003 → "30", 7.5 → "7.5"
func formatFPS(_ value: Double) -> String {
    abs(value - value.rounded()) < 0.05 ? String(format: "%.0f", value) : String(format: "%.1f", value)
}

/// 약 1초 동안의 처리 통계. 시간은 단계 1회당 평균(ms), CPU 는 그동안 프로세스 전체가 쓴 시간.
struct PipelineSnapshot: Equatable, Sendable {
    /// 카메라에서 받은 프레임/s
    var receivedFPS: Double = 0
    /// Vision 을 돌린 프레임/s
    var processedFPS: Double = 0
    /// 그중 전체 얼굴 검출을 한 횟수/s (나머지는 직전 얼굴 위치로 추적)
    var detectFPS: Double = 0
    /// 랜드마크 요청/s
    var landmarksFPS: Double = 0
    /// 특징 계산까지 성공한 프레임/s
    var featuresFPS: Double = 0
    /// 목표 처리 횟수/s
    var targetHz: Double = 0
    /// 장치에 설정한 fps
    var deviceFPS: Double = 0
    var detectionInterval = 1
    var mode: AnalysisMode = .precise
    var devices = VisionDevices()
    var detectWallMs: Double = 0
    var detectCPUms: Double = 0
    var landmarksWallMs: Double = 0
    var landmarksCPUms: Double = 0
    var featuresCPUms: Double = 0

    /// 초당 신경망 추론 횟수 (얼굴 검출 + 랜드마크)
    var inferencesPerSecond: Double { detectFPS + landmarksFPS }
    /// 처리 1회당 평균 CPU (ms, 검출·랜드마크·특징 합)
    var cpuPerFrameMs: Double {
        processedFPS > 0 ? cpuPercent * 10 / processedFPS : 0
    }
    /// 처리 1회당 평균 경과 시간 (ms)
    var wallPerFrameMs: Double {
        processedFPS > 0 ? (detectFPS * detectWallMs + landmarksFPS * landmarksWallMs) / processedFPS : 0
    }
    /// 이 파이프라인이 쓰는 CPU (코어 1개 = 100%)
    var cpuPercent: Double {
        (detectFPS * detectCPUms + landmarksFPS * landmarksCPUms + featuresFPS * featuresCPUms) / 10
    }
}

/// videoQueue 전용 누적기
private struct StatsWindow {
    var start: CFTimeInterval = 0
    var received = 0
    var processed = 0
    var detections = 0
    var landmarks = 0
    var features = 0
    var detectWall: Double = 0, detectCPU: Double = 0
    var landmarksWall: Double = 0, landmarksCPU: Double = 0
    var featuresCPU: Double = 0

    mutating func add(_ extraction: Extraction) {
        let t = extraction.timing
        processed += 1
        detections += t.detect.count
        detectWall += t.detect.wall
        detectCPU += t.detect.cpu
        landmarks += t.landmarks.count
        landmarksWall += t.landmarks.wall
        landmarksCPU += t.landmarks.cpu
        if extraction.features != nil {
            features += 1
            featuresCPU += t.features.cpu
        }
    }

    func snapshot(elapsed: Double) -> PipelineSnapshot {
        func perCallMs(_ total: Double, _ count: Int) -> Double { count > 0 ? total / Double(count) * 1000 : 0 }
        return PipelineSnapshot(
            receivedFPS: Double(received) / elapsed,
            processedFPS: Double(processed) / elapsed,
            detectFPS: Double(detections) / elapsed,
            landmarksFPS: Double(landmarks) / elapsed,
            featuresFPS: Double(features) / elapsed,
            detectWallMs: perCallMs(detectWall, detections),
            detectCPUms: perCallMs(detectCPU, detections),
            landmarksWallMs: perCallMs(landmarksWall, landmarks),
            landmarksCPUms: perCallMs(landmarksCPU, landmarks),
            featuresCPUms: perCallMs(featuresCPU, features)
        )
    }
}
