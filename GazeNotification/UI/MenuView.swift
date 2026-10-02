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
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
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
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
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
                    Label("성능 및 제한", systemImage: "chart.xyaxis.line")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("menu.openPerformance")
                Button {
                    dismiss()
                    model.openSettings(.calibration)
                } label: {
                    Label("보정 조정", systemImage: "slider.horizontal.3")
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
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
                    Text("처리 상세 정보").font(.callout.weight(.semibold))
                    Spacer()
                    if model.placementSource == .gaze {
                        Text("초당 \(fixed(model.pipeline.processedFPS))회, CPU \(fixed(model.liveStats.processCPUPercent))%")
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
            Text("GazeNotification").font(.headline)
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
            Text("알림 위치를 변경하려면 시스템 설정 > 개인정보 보호 및 보안 > 손쉬운 사용에서 GazeNotification을 켜세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("시스템 설정 열기") { model.requestAccessibility() }
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
                          value: model.faceDetected ? String(localized: "감지됨 (\(fixed(model.fps, 0))fps)") : String(localized: "감지 안 됨"),
                          color: model.faceDetected ? .green : .orange)
                StatusRow(id: "calibration", title: "보정", value: calibrationText, color: model.calibration == nil ? .orange : .green)
            }
            StatusRow(id: "accessibility", title: "손쉬운 사용",
                      value: model.accessibilityGranted ? String(localized: "허용됨") : String(localized: "허용 안 됨"),
                      color: model.accessibilityGranted ? .green : .red)
            StatusRow(id: "policy", title: "프로필", value: policyText, color: model.cameraPause == nil ? .green : .secondary)
            if model.placementSource == .gaze {
                StatusRow(id: "aiMode", title: "AI 모드",
                          value: listText([model.analysisMode.shortTitle, model.activeEstimatorKind.title, model.visionDevices.detection]),
                          color: .green)
            }

            if model.placementSource == .gaze {
                DisclosureGroup(isExpanded: $showPreview) {
                    CameraPreview(session: model.captureSession)
                        .frame(height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 4)
                } label: {
                    // 화살표뿐 아니라 글자를 눌러도 펼치고 접는다
                    Button("카메라 미리보기") { showPreview.toggle() }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("menu.preview")
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

            Toggle("표시 중인 알림을 시선에 따라 이동", isOn: $model.followWhileVisible)
            if model.placementSource == .gaze {
                Toggle("화면 상단에 알림 위치 표시", isOn: $model.showOverlay)
            }
            Picker("언어", selection: $model.language) {
                ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0) }
            }
            .accessibilityIdentifier("menu.language")
            if model.languageNeedsRestart {
                HStack {
                    Text("앱을 다시 시작하면 적용됩니다.").foregroundStyle(.secondary)
                    Spacer()
                    Button("지금 다시 시작") { AppLanguage.relaunch() }
                        .accessibilityIdentifier("menu.relaunch")
                }
                .font(.caption)
            }
            Toggle("로그인 시 열기", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
        }
        .font(.callout)
    }

    private var footer: some View {
        HStack {
            Menu("진단") {
                Button("알림 창 구조 저장") { model.dumpAccessibilityTree() }
                Button("로그 폴더 열기") { model.openLogFolder() }
                if model.calibration != nil {
                    Divider()
                    Button("보정 초기화") { model.resetCalibration() }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button("홈페이지") { NSWorkspace.shared.open(AppLinks.homepage) }
                .buttonStyle(.link)
                .accessibilityIdentifier("menu.homepage")

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
        if let reason = policy.reason { text = String(localized: "\(policy.applied.title) (자동, \(reason))") }
        if model.governorScale < 0.999 {
            text = String(localized: "\(text), 처리 횟수 \(fixed(model.governorScale * 100, 0))%로 제한")
        }
        return text
    }

    private var cameraText: String {
        if model.placementSource == .gaze, model.isEnabled, let pause = model.cameraPause {
            return pause == .screen ? String(localized: "일시 정지됨 (화면 꺼짐)") : String(localized: "일시 정지됨 (자리 비움)")
        }
        switch model.cameraStatus {
        case .idle: return model.placementSource == .gaze && model.isEnabled ? String(localized: "시작 중…") : String(localized: "꺼짐")
        case .unauthorized: return String(localized: "권한 없음 (시스템 설정에서 허용)")
        case .noDevice: return String(localized: "카메라 없음")
        case .running(let name): return name
        case .failed(let message): return String(localized: "오류: \(message)")
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
        guard let calibration = model.calibration else { return String(localized: "안 됨 (기본 추정식 사용)") }
        guard let estimator = model.activeEstimator else {
            return String(localized: "다시 보정 필요 (\(model.analysisMode.shortTitle) 방식)")
        }
        let date = calibration.createdAt.formatted(date: .abbreviated, time: .omitted)
        let error = percentText(estimator.crossValidationRMSE ?? estimator.trainingRMSE)
        return String(localized: "완료 (오차 \(error), \(date))")
    }
}

private struct StatusRow: View {
    /// 값 글자의 접근성 식별자 "status.<id>" (UI 테스트)
    let id: String
    let title: LocalizedStringKey
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 104, alignment: .leading)
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
