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
///   16:9, 폭 ~800 으로, 장치 프레임레이트 자체를 낮춘다(기본 10fps).
/// - `frameStride` 로 N 프레임마다 한 번만 Vision 을 돌린다 (AppModel 이 상황에 맞게 조절).
final class CameraService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    /// 메인 스레드에서 호출. 얼굴이 없으면 nil.
    var onFeatures: (@MainActor (FaceFeatures?) -> Void)?
    var onStatus: (@MainActor (CameraStatus) -> Void)?
    /// 약 1초마다 처리 통계 (메인 스레드)
    var onStats: (@MainActor (PipelineSnapshot) -> Void)?
    /// 카메라 포맷이 적용될 때 (메인 스레드)
    var onFormat: (@MainActor (CameraFormatInfo) -> Void)?

    /// Vision 요청이 실행되는 장치
    var visionDevices: (detection: String, landmarks: String) {
        (extractor.detectionDevice, extractor.landmarksDevice)
    }

    private let sessionQueue = DispatchQueue(label: "gazenoti.camera.session")
    private let videoQueue = DispatchQueue(label: "gazenoti.camera.video", qos: .utility)
    private let output = AVCaptureVideoDataOutput()
    private let extractor = FaceFeatureExtractor()
    private var currentInput: AVCaptureDeviceInput?

    /// 목표 캡처 폭. 800 이면 C922 기준 800x448 비압축(yuvs) 포맷이 선택된다.
    private let targetWidth: Int32 = 800
    private let outputPixelFormat: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    /// 장치가 내보내는 프레임레이트 (sessionQueue 전용). `setCaptureRate` 로 바꾼다.
    private var deviceFPS: Double = 5

    // videoQueue 전용
    private var statsWindow = StatsWindow()
    private var frameStride = 1
    private var frameCounter = 0

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

    /// 폭이 target 에 가깝고, 16:9 이고, 비압축(yuvs/2vuy)인 포맷을 우선한다.
    private static func bestFormat(for device: AVCaptureDevice, targetWidth: Int32, fps: Double) -> AVCaptureDevice.Format? {
        let uncompressed: Set<FourCharCode> = [kCVPixelFormatType_422YpCbCr8_yuvs, kCVPixelFormatType_422YpCbCr8]
        func score(_ format: AVCaptureDevice.Format) -> (Int32, Int, Int) {
            let d = format.formatDescription.dimensions
            let widthBucket = abs(d.width - targetWidth) / 100
            let aspect = abs(Double(d.width) / Double(max(d.height, 1)) - 16.0 / 9.0) < 0.06 ? 0 : 1
            let compressed = uncompressed.contains(format.formatDescription.mediaSubType.rawValue) ? 0 : 1
            return (widthBucket, aspect, compressed)
        }
        return device.formats
            .filter { format in
                format.formatDescription.dimensions.width >= 480
                    && format.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }
            }
            .min { score($0) < score($1) }
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
            report(.idle)
        }
    }

    /// 장치 프레임레이트와 처리 간격(N 프레임마다 1번)을 함께 바꾼다.
    /// 장치 fps 자체를 낮추면 USB 전송·드라이버·프레임 전달 비용까지 줄어든다.
    func setCaptureRate(fps: Double, stride: Int) {
        videoQueue.async { self.frameStride = max(1, stride) }
        sessionQueue.async { [self] in
            guard fps != deviceFPS else { return }
            deviceFPS = fps
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

    /// 장치가 직접 내보내는 포맷을 고정하고(스케일링·MJPEG 디코딩 회피) 장치 프레임레이트를 낮춘다.
    private func applyFormat(to device: AVCaptureDevice) {
        guard let format = Self.bestFormat(for: device, targetWidth: targetWidth, fps: deviceFPS) else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(deviceFPS))
        do {
            try device.lockForConfiguration()
            if device.activeFormat != format { device.activeFormat = format }
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
        } catch {
            Log.error("카메라 포맷 설정 실패: \(error.localizedDescription)")
            return
        }
        let d = format.formatDescription.dimensions
        var settings = output.videoSettings ?? [:]
        // 출력도 원본 크기로 고정 → 추가 스케일링 없음
        settings[kCVPixelBufferWidthKey as String] = Int(d.width)
        settings[kCVPixelBufferHeightKey as String] = Int(d.height)
        output.videoSettings = settings

        let active = device.activeFormat.formatDescription
        let fps = device.activeVideoMinFrameDuration.seconds > 0 ? 1 / device.activeVideoMinFrameDuration.seconds : 0
        let outFormat = (output.videoSettings?[kCVPixelBufferPixelFormatTypeKey as String] as? OSType).map(fourCC) ?? "?"
        let info = CameraFormatInfo(deviceName: device.localizedName,
                                    width: Int(active.dimensions.width), height: Int(active.dimensions.height),
                                    sourceFormat: fourCC(active.mediaSubType.rawValue),
                                    outputFormat: outFormat, deviceFPS: fps)
        Log.info("카메라 포맷: \(info.width)x\(info.height) \(info.sourceFormat) @\(Int(fps.rounded()))fps → 출력 \(outFormat)")
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onFormat?(info) }
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
        frameCounter += 1
        statsWindow.received += 1
        defer { flushStatsIfNeeded(now: now) }

        guard frameCounter % frameStride == 0,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

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
        let snapshot = statsWindow.snapshot(elapsed: elapsed, stride: frameStride)
        statsWindow = StatsWindow(start: now)
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.onStats?(snapshot) }
        }
    }
}

private func fourCC(_ value: FourCharCode) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii) ?? "\(value)"
}

private extension BinaryInteger {
    var nonZero: Self? { self == 0 ? nil : self }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
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
}

/// 약 1초 동안의 처리 통계. 시간은 처리한 프레임 1개당 평균(ms).
struct PipelineSnapshot: Equatable, Sendable {
    /// 카메라에서 받은 프레임/s
    var receivedFPS: Double = 0
    /// Vision 을 돌린 프레임/s (= 얼굴 검출 요청/s)
    var processedFPS: Double = 0
    /// 얼굴이 있어 랜드마크까지 돈 프레임/s (= 랜드마크 요청/s)
    var landmarksFPS: Double = 0
    /// 특징 계산까지 성공한 프레임/s
    var featuresFPS: Double = 0
    var stride = 1
    var detectWallMs: Double = 0
    var detectCPUms: Double = 0
    var landmarksWallMs: Double = 0
    var landmarksCPUms: Double = 0
    var featuresCPUms: Double = 0

    /// 초당 신경망 추론 횟수 (얼굴 검출 + 랜드마크)
    var inferencesPerSecond: Double { processedFPS + landmarksFPS }
    /// 이 파이프라인이 쓰는 CPU (코어 1개 = 100%)
    var cpuPercent: Double {
        (processedFPS * detectCPUms + landmarksFPS * landmarksCPUms + featuresFPS * featuresCPUms) / 10
    }
}

/// videoQueue 전용 누적기
private struct StatsWindow {
    var start: CFTimeInterval = 0
    var received = 0
    var processed = 0
    var landmarks = 0
    var features = 0
    var detectWall: Double = 0, detectCPU: Double = 0
    var landmarksWall: Double = 0, landmarksCPU: Double = 0
    var featuresCPU: Double = 0

    mutating func add(_ extraction: Extraction) {
        let t = extraction.timing
        processed += 1
        detectWall += t.detect.wall
        detectCPU += t.detect.cpu
        if t.landmarks.ran {
            landmarks += 1
            landmarksWall += t.landmarks.wall
            landmarksCPU += t.landmarks.cpu
        }
        if t.features.ran {
            features += 1
            featuresCPU += t.features.cpu
        }
    }

    func snapshot(elapsed: Double, stride: Int) -> PipelineSnapshot {
        func perFrameMs(_ total: Double, _ count: Int) -> Double { count > 0 ? total / Double(count) * 1000 : 0 }
        return PipelineSnapshot(
            receivedFPS: Double(received) / elapsed,
            processedFPS: Double(processed) / elapsed,
            landmarksFPS: Double(landmarks) / elapsed,
            featuresFPS: Double(features) / elapsed,
            stride: stride,
            detectWallMs: perFrameMs(detectWall, processed),
            detectCPUms: perFrameMs(detectCPU, processed),
            landmarksWallMs: perFrameMs(landmarksWall, landmarks),
            landmarksCPUms: perFrameMs(landmarksCPU, landmarks),
            featuresCPUms: perFrameMs(featuresCPU, features)
        )
    }
}
