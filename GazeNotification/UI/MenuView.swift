import SwiftUI

struct MenuView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showPreview = false
    @AppStorage("ui.showPipeline") private var showPipeline = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !model.accessibilityGranted {
                accessibilityCard
            }

            ScreenMiniMap(gazeX: model.placementSource == .gaze ? model.gazeX : nil,
                          faceDetected: model.faceDetected,
                          aspectRatio: model.screenAspectRatio)

            statusSection

            HStack(spacing: 8) {
                Button {
                    dismiss()
                    model.startCalibration()
                } label: {
                    Label("시선 보정", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("menu.calibrate")
                .buttonStyle(.borderedProminent)
                .disabled(!model.isEnabled || model.isCalibrating || model.placementSource != .gaze)

                Button {
                    dismiss()
                    model.sendTestNotification()
                } label: {
                    Label("테스트 알림", systemImage: "bell.badge")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("menu.testNotification")
                .disabled(!model.isEnabled)
            }
            .controlSize(.large)

            HStack(spacing: 8) {
                Button {
                    dismiss()
                    model.openSettings(.performance)
                } label: {
                    Label("성능 그래프·연산 제한", systemImage: "chart.xyaxis.line")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("menu.openPerformance")
                Button {
                    dismiss()
                    model.openSettings(.calibration)
                } label: {
                    Label("보정 직접 조정", systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("menu.openAdjust")
            }

            if let event = model.lastEvent {
                Text(event)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .accessibilityIdentifier("menu.lastEvent")
            }

            DisclosureGroup(isExpanded: $showPipeline) {
                PipelineView(model: model)
            } label: {
                HStack {
                    Text("AI 연산 상세").font(.callout.weight(.semibold))
                    Spacer()
                    if model.placementSource == .gaze {
                        Text(String(format: "%.1f회/s · CPU %.1f%%",
                                    model.pipeline.processedFPS, model.liveStats.processCPUPercent))
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()
            settingsSection
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 420)
        .onAppear {
            model.isMenuVisible = true
            model.isPreviewVisible = showPreview
        }
        .onDisappear {
            model.isMenuVisible = false
            model.isPreviewVisible = false
        }
        .onChange(of: showPreview) { _, expanded in model.isPreviewVisible = expanded }
    }

    // MARK: - 섹션

    private var header: some View {
        HStack {
            Image(systemName: "eye.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("GazeNotification").font(.headline)
                Text("알림을 보고 있는 곳으로").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $model.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityIdentifier("menu.enabled")
        }
    }

    private var accessibilityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("손쉬운 사용 권한이 필요합니다", systemImage: "hand.raised.fill")
                .font(.subheadline.weight(.semibold))
            Text("알림 창을 옮기려면 시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용에서 GazeNotification 을 켜세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("권한 설정 열기") { model.requestAccessibility() }
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            StatusRow(id: "camera", title: "카메라", value: cameraText, color: cameraColor)
            if model.placementSource == .gaze {
                StatusRow(id: "face", title: "얼굴",
                          value: model.faceDetected ? String(format: "감지됨 · %.0f fps", model.fps) : "감지 안 됨",
                          color: model.faceDetected ? .green : .orange)
                StatusRow(id: "calibration", title: "보정", value: calibrationText, color: model.calibration == nil ? .orange : .green)
            }
            StatusRow(id: "accessibility", title: "손쉬운 사용",
                      value: model.accessibilityGranted ? "허용됨" : "필요",
                      color: model.accessibilityGranted ? .green : .red)
            StatusRow(id: "policy", title: "연산", value: policyText, color: model.cameraPause == nil ? .green : .secondary)
            if model.placementSource == .gaze {
                StatusRow(id: "aiMode", title: "AI 모드",
                          value: "\(model.analysisMode.shortTitle) · \(model.activeEstimatorKind.title) · \(model.visionDevices.detection)",
                          color: .green)
            }

            if model.placementSource == .gaze {
                DisclosureGroup("카메라 미리보기 (펼치면 \(Int(TrackingRate.liveHz))회/s)", isExpanded: $showPreview) {
                    CameraPreview(session: model.captureSession)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 4)
                }
                .font(.caption)
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("위치 기준", selection: $model.placementSource) {
                ForEach(PlacementSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("menu.placementSource")

            if model.placementSource == .gaze {
                Picker("카메라", selection: $model.selectedCameraID) {
                    Text("자동").tag(String?.none)
                    ForEach(model.cameras) { Text($0.name).tag(Optional($0.id)) }
                }
            }

            Toggle("알림이 떠 있는 동안 계속 따라오기", isOn: $model.followWhileVisible)
            if model.placementSource == .gaze {
                Toggle("화면 상단에 알림 위치 표시", isOn: $model.showOverlay)
            }
            Toggle("로그인 시 자동 실행", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Menu("진단") {
                Button("알림 창 AX 구조 저장") { model.dumpAccessibilityTree() }
                Button("로그 폴더 열기") { model.openLogFolder() }
                if model.calibration != nil {
                    Divider()
                    Button("보정 초기화") { model.resetCalibration() }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            Button("종료") { NSApp.terminate(nil) }
                .accessibilityIdentifier("menu.quit")
                .keyboardShortcut("q")
        }
        .font(.callout)
    }

    // MARK: - 표시 문자열

    private var policyText: String {
        let policy = model.policy
        var text = policy.applied.title
        if let reason = policy.reason { text += " (자동 · \(reason))" }
        if model.governorScale < 0.999 { text += String(format: " · CPU 상한으로 %.0f%%", model.governorScale * 100) }
        return text
    }

    private var cameraText: String {
        if model.placementSource == .gaze, model.isEnabled, let pause = model.cameraPause {
            return pause == .screen ? "꺼짐 (화면 꺼짐·잠김)" : "꺼짐 (오래 자리 비움 — 입력하면 켜짐)"
        }
        switch model.cameraStatus {
        case .idle: return model.placementSource == .gaze && model.isEnabled ? "시작 중…" : "꺼짐"
        case .unauthorized: return "권한 없음 (시스템 설정 → 카메라)"
        case .noDevice: return "카메라 없음"
        case .running(let name): return name
        case .failed(let message): return "오류: \(message)"
        }
    }

    private var cameraColor: Color {
        switch model.cameraStatus {
        case .running: .green
        case .idle: .secondary
        default: .red
        }
    }

    private var calibrationText: String {
        guard let calibration = model.calibration else { return "안 함 (기본 추정식 사용 · 보정 권장)" }
        let date = calibration.createdAt.formatted(date: .abbreviated, time: .shortened)
        guard let estimator = model.activeEstimator else {
            return "\(model.analysisMode.shortTitle) 방식은 학습 안 됨 (다시 보정) · " + date
        }
        return String(format: "완료 · 오차 %.1f%% · ", (estimator.crossValidationRMSE ?? estimator.trainingRMSE) * 100) + date
    }
}

private struct StatusRow: View {
    /// 값 글자의 접근성 식별자 "status.<id>" (UI 테스트)
    let id: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("status.\(id)")
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

/// 모니터 비율 그대로의 미니맵: 현재 시선(점)과 알림이 뜰 영역(상단 막대)을 표시.
private struct ScreenMiniMap: View {
    let gazeX: Double?
    let faceDetected: Bool
    let aspectRatio: CGFloat

    /// 메뉴 패널 폭(420) − 좌우 여백(14×2)
    static let width: CGFloat = 392

    /// 실제 배너 폭(약 360pt) / 화면 폭 을 대략 반영
    private let bannerFraction: CGFloat = 0.06

    var body: some View {
        // 메뉴 패널은 폭이 고정이라 높이를 직접 계산한다 (패널 크기 계산 때 aspectRatio 가 무시되는 문제 회피)
        Color.clear
            .frame(width: Self.width, height: Self.width / max(aspectRatio, 1))
            .overlay { GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.primary.opacity(0.2))

                if let gazeX {
                    let x = CGFloat(gazeX) * size.width
                    let barWidth = max(size.width * bannerFraction, 16)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: barWidth, height: 6)
                        .offset(x: (x - barWidth / 2).clamped(to: 3...max(3, size.width - barWidth - 3)), y: 4)
                    Circle()
                        .fill(faceDetected ? Color.green : Color.gray)
                        .frame(width: 10, height: 10)
                        .offset(x: x - 5, y: size.height / 2 - 5)
                } else {
                    Text("시선 정보 없음")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: size.width, height: size.height)
                }
            }
            .animation(.linear(duration: 0.08), value: gazeX)
        } }
    }
}
