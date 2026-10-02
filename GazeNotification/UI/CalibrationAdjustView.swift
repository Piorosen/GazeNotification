import SwiftUI

/// 설정 창 "보정 조정": 학습한 보정 위에 사람이 손으로 위치·범위·특징 가중치·스무딩을 맞춘다.
/// 이 탭이 보이는 동안은 실시간 속도로 추적하고, 화면 상단에 위치 막대를 띄워 바로 확인할 수 있다.
struct CalibrationAdjustView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                AdjustPreview(raw: model.rawGazeX, final: model.gazeX, faceDetected: model.faceDetected,
                              zones: model.adjustment.zones, aspectRatio: model.screenAspectRatio)
                Toggle("조정하는 동안 화면 상단에 위치 막대 표시", isOn: $model.showOverlayWhileAdjusting)
                    .accessibilityIdentifier("adjust.overlay")
            } header: {
                Text("미리보기")
            } footer: {
                FormNote("화면의 여러 곳을 바라보며 막대가 시선을 따라오는지 확인하세요. 이 탭이 열려 있는 동안 초당 \(Int(TrackingRate.liveHz))회 추적합니다.")
            }

            calibrationSection
            positionSection
            featureSection
            motionSection

            Section {
                Button("모든 수동 조정 초기화", role: .destructive) { model.resetAdjustment() }
                    .accessibilityIdentifier("adjust.resetAll")
                    .disabled(model.adjustment == GazeAdjustment())
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 학습한 보정

    private var calibrationSection: some View {
        Section {
            if let calibration = model.calibration, let estimator = model.activeEstimator {
                let date = calibration.createdAt.formatted(date: .abbreviated, time: .shortened)
                let training = percentText(estimator.trainingRMSE)
                let samples = estimator.regression.sampleCount
                Text(estimator.crossValidationRMSE.map {
                    String(localized: "\(model.analysisMode.shortTitle) 방식, \(estimator.kind.title)\n학습 오차 \(training), 교차 검증 오차 \(percentText($0)), 샘플 \(samples)개\n보정 일시: \(date)")
                } ?? String(localized: "\(model.analysisMode.shortTitle) 방식, \(estimator.kind.title)\n학습 오차 \(training), 샘플 \(samples)개\n보정 일시: \(date)"))
                    .accessibilityIdentifier("adjust.summary")
                let results = estimator.targetResults
                if !results.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                        GridRow {
                            Text("보정 점").foregroundStyle(.secondary)
                            ForEach(results, id: \.target) { Text(percent($0.target)).monospacedDigit() }
                        }
                        GridRow {
                            Text("모델 예측").foregroundStyle(.secondary)
                            ForEach(results, id: \.target) { Text(percent($0.predicted)).monospacedDigit() }
                        }
                    }
                    .font(.caption)
                }
            } else if model.calibration != nil {
                Text("현재 AI 모드(\(model.analysisMode.shortTitle) 방식, \(model.activeEstimatorKind.title))로 학습된 보정이 없어 기본 추정식을 사용합니다. 다시 보정하면 모든 방식과 모델이 학습됩니다.")
                    .accessibilityIdentifier("adjust.summary")
            } else {
                Text("보정하지 않아 기본 추정식을 사용합니다. 먼저 시선 보정을 실행하세요.")
                    .accessibilityIdentifier("adjust.summary")
            }
            HStack {
                Button("다시 보정") { model.startCalibration() }
                    .accessibilityIdentifier("adjust.recalibrate")
                Button("빠른 위치 맞춤") { model.startQuickAdjust() }
                    .accessibilityIdentifier("adjust.quick")
                Spacer()
            }
            .disabled(!model.isEnabled || model.isCalibrating || model.placementSource != .gaze)
            Picker("보정 점 개수", selection: $model.calibrationPointCount) {
                ForEach([3, 5, 7, 9], id: \.self) { Text("\($0)개").tag($0) }
            }
            .accessibilityIdentifier("adjust.points")
            LimitSlider(id: "adjust.seconds", title: "점당 응시 시간", value: $model.calibrationSeconds, range: 0.8...4, step: 0.2,
                        text: String(localized: "\(fixed(model.calibrationSeconds))초"))
        } header: {
            Text("보정")
        } footer: {
            FormNote("빠른 위치 맞춤은 기존 보정을 유지한 채 왼쪽 끝, 가운데, 오른쪽 끝을 볼 때의 값으로 아래 위치 설정만 다시 계산합니다. 다시 보정하면 위치 설정이 초기화됩니다.")
        }
    }

    // MARK: - 위치

    private var positionSection: some View {
        Section {
            LimitSlider(id: "adjust.offset", title: "좌우 이동", value: $model.adjustment.offset, range: GazeAdjustment.offsetRange, step: 0.005,
                        text: offsetText)
            LimitSlider(id: "adjust.leftGain", title: "왼쪽 범위", value: $model.adjustment.leftGain, range: GazeAdjustment.gainRange, step: 0.05,
                        text: "×" + fixed(model.adjustment.leftGain, 2))
            LimitSlider(id: "adjust.rightGain", title: "오른쪽 범위", value: $model.adjustment.rightGain, range: GazeAdjustment.gainRange, step: 0.05,
                        text: "×" + fixed(model.adjustment.rightGain, 2))
            HStack {
                Spacer()
                Button("위치 초기화") { model.adjustment = model.adjustment.resettingPosition() }
                    .accessibilityIdentifier("adjust.resetPosition")
                    .disabled(model.adjustment.isPositionDefault)
            }
        } header: {
            Text("위치")
        } footer: {
            FormNote("추정 위치가 한쪽으로 치우치면 좌우 이동을 조정하세요. 화면 끝까지 닿지 않으면 해당 방향의 범위를 늘리세요. 범위는 화면 가운데를 기준으로 조정됩니다.")
        }
    }

    // MARK: - 특징 가중치

    private var featureSection: some View {
        Section {
            ForEach(GazeFeature.allCases) { feature in
                let term = model.gazeBreakdown?.terms.first { $0.feature == feature }
                VStack(alignment: .leading, spacing: 2) {
                    LimitSlider(id: "adjust.feature.\(feature.rawValue)", title: feature.title, value: $model.adjustment.featureGains[feature.rawValue],
                                range: GazeAdjustment.featureGainRange, step: 0.05,
                                text: featureText(model.adjustment.featureGains[feature.rawValue], term: term))
                    Text(feature.detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("특징 가중치")
        } footer: {
            FormNote("각 특징이 위치 계산에 반영되는 비율을 조정합니다. 100%는 학습된 값 그대로, 0%는 사용하지 않음을 뜻합니다. 오른쪽 숫자는 현재 프레임의 기여도입니다.")
        }
    }

    private func featureText(_ gain: Double, term: GazeBreakdown.Term?) -> String {
        let base = fixed(gain * 100, 0) + "%"
        guard let term else { return base }
        guard term.slope != nil else { return String(localized: "\(base) (모델에서 사용 안 함)") }
        return model.faceDetected ? "\(base) (\(signed(term.contribution * 100))%)" : base
    }

    // MARK: - 움직임

    private var motionSection: some View {
        Section {
            LimitSlider(id: "adjust.smoothing", title: "반응 속도", value: $model.adjustment.smoothing,
                        range: GazeAdjustment.smoothingRange, step: 0.05,
                        text: smoothingText)
            LimitSlider(id: "adjust.responsiveness", title: "빠른 움직임 반응", value: $model.adjustment.responsiveness,
                        range: GazeAdjustment.responsivenessRange, step: 0.1,
                        text: fixed(model.adjustment.responsiveness))
            Picker("화면 구역", selection: $model.adjustment.zones) {
                ForEach(GazeAdjustment.zoneChoices, id: \.self) { zones in
                    Text(zones == 0 ? String(localized: "사용 안 함") : String(localized: "\(zones)구역")).tag(zones)
                }
            }
            .accessibilityIdentifier("adjust.zones")
            LimitSlider(id: "adjust.follow", title: "표시 중인 알림 이동 기준", value: $model.adjustment.followThreshold,
                        range: GazeAdjustment.followRange, step: 0.01,
                        text: String(localized: "화면 폭의 \(fixed(model.adjustment.followThreshold * 100, 0))%"))
        } header: {
            Text("움직임")
        } footer: {
            FormNote("반응 속도를 낮추면 위치가 안정되지만 시선을 늦게 따라갑니다. 화면 구역을 설정하면 화면을 같은 폭으로 나누고 각 구역의 가운데에 알림을 표시합니다.")
        }
    }

    private func percent(_ value: Double) -> String { fixed(value * 100, 0) + "%" }

    private var offsetText: String {
        let offset = model.adjustment.offset
        let value = signed(offset * 100) + "%"
        if offset == 0 { return value }
        return offset > 0 ? String(localized: "\(value) (오른쪽)") : String(localized: "\(value) (왼쪽)")
    }

    private var smoothingText: String {
        let hz = fixed(model.adjustment.smoothing, 2) + "Hz"
        let smoothing = model.adjustment.smoothing
        if smoothing < 0.6 { return String(localized: "\(hz) (부드럽게)") }
        return smoothing > 1.5 ? String(localized: "\(hz) (빠르게)") : String(localized: "\(hz) (보통)")
    }
}

/// 화면 비율 그대로의 막대: 모델 출력(조정 전)과 최종 위치(조정·스무딩 후), 알림이 뜰 자리를 보여 준다.
private struct AdjustPreview: View {
    let raw: Double?
    let final: Double?
    let faceDetected: Bool
    let zones: Int
    let aspectRatio: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let size = geometry.size
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05))
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.2))
                    ForEach([0.25, 0.5, 0.75], id: \.self) { tick in
                        Rectangle().fill(Color.primary.opacity(0.08))
                            .frame(width: 1, height: size.height)
                            .offset(x: tick * size.width)
                    }
                    if zones > 1 {
                        ForEach(1..<zones, id: \.self) { i in
                            Rectangle().fill(Color.accentColor.opacity(0.35))
                                .frame(width: 1.5, height: size.height)
                                .offset(x: CGFloat(i) / CGFloat(zones) * size.width)
                        }
                    }
                    if let final {
                        let x = CGFloat(final) * size.width
                        let barWidth = max(size.width * 0.06, 18)
                        RoundedRectangle(cornerRadius: 2).fill(Color.accentColor)
                            .frame(width: barWidth, height: 7)
                            .offset(x: (x - barWidth / 2).clamped(to: 3...max(3, size.width - barWidth - 3)), y: 5)
                    }
                    if let raw, faceDetected {
                        Circle().strokeBorder(Color.secondary, lineWidth: 2)
                            .frame(width: 14, height: 14)
                            .offset(x: CGFloat(raw) * size.width - 7, y: size.height / 2 - 7)
                    }
                    if let final {
                        Circle().fill(faceDetected ? Color.accentColor : Color.gray)
                            .frame(width: 10, height: 10)
                            .offset(x: CGFloat(final) * size.width - 5, y: size.height / 2 - 5)
                    }
                    if !faceDetected {
                        Text("얼굴이 감지되지 않음").font(.caption).foregroundStyle(.secondary)
                            .frame(width: size.width, height: size.height)
                    }
                }
                .animation(.linear(duration: 0.1), value: final)
            }
            .aspectRatio(max(aspectRatio, 1.5), contentMode: .fit)
            .frame(maxHeight: 150)

            HStack(spacing: 16) {
                HStack(spacing: 5) {
                    Circle().strokeBorder(Color.secondary, lineWidth: 2).frame(width: 10, height: 10)
                    Text("조정 전").foregroundStyle(.secondary)
                    Text(raw.map { fixed($0 * 100, 0) + "%" } ?? "—").monospacedDigit()
                        .accessibilityIdentifier("adjust.raw")
                }
                HStack(spacing: 5) {
                    Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                    Text("조정 후").foregroundStyle(.secondary)
                    Text(final.map { fixed($0 * 100, 0) + "%" } ?? "—").monospacedDigit()
                        .accessibilityIdentifier("adjust.final")
                }
            }
            .font(.caption)
        }
    }
}
