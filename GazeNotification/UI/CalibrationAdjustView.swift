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
                FormNote("화면 여기저기를 바라보며 막대가 시선을 따라오는지 확인하세요. 이 탭을 보는 동안은 \(Int(TrackingRate.liveHz))회/s 로 추적합니다.")
            }

            calibrationSection
            positionSection
            featureSection
            motionSection

            Section {
                Button("수동 보정값 모두 초기화", role: .destructive) { model.resetAdjustment() }
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
                Text(String(format: "%@ · %@ · 학습 오차 %.1f%%%@ · 샘플 %d개 · ", model.analysisMode.shortTitle,
                            estimator.kind.title, estimator.trainingRMSE * 100,
                            estimator.crossValidationRMSE.map { String(format: " · 교차검증 %.1f%%", $0 * 100) } ?? "",
                            estimator.regression.sampleCount)
                     + calibration.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .accessibilityIdentifier("adjust.summary")
                let results = estimator.targetResults
                if !results.isEmpty {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                        GridRow {
                            Text("보정 점").foregroundStyle(.secondary)
                            ForEach(results, id: \.target) { Text(percent($0.target)).monospacedDigit() }
                        }
                        GridRow {
                            Text("모델 추정").foregroundStyle(.secondary)
                            ForEach(results, id: \.target) { Text(percent($0.predicted)).monospacedDigit() }
                        }
                    }
                    .font(.caption)
                }
            } else if model.calibration != nil {
                Text("지금 AI 모드(\(model.analysisMode.shortTitle) · \(model.activeEstimatorKind.title))로 학습한 보정이 없어 기본 추정식을 씁니다. 시선 보정을 다시 하면 모든 방식·모델을 학습합니다.")
                    .accessibilityIdentifier("adjust.summary")
            } else {
                Text("아직 보정하지 않아 기본 추정식을 씁니다. 먼저 시선 보정을 하세요.")
                    .accessibilityIdentifier("adjust.summary")
            }
            HStack {
                Button("시선 보정 다시 하기") { model.startCalibration() }
                    .accessibilityIdentifier("adjust.recalibrate")
                Button("빠른 위치 맞춤 (3점, 약 10초)") { model.startQuickAdjust() }
                    .accessibilityIdentifier("adjust.quick")
                Spacer()
            }
            .disabled(!model.isEnabled || model.isCalibrating || model.placementSource != .gaze)
            Picker("보정 점 개수", selection: $model.calibrationPointCount) {
                ForEach([3, 5, 7, 9], id: \.self) { Text("\($0)개").tag($0) }
            }
            .accessibilityIdentifier("adjust.points")
            LimitSlider(id: "adjust.seconds", title: "점 하나를 보는 시간", value: $model.calibrationSeconds, range: 0.8...4, step: 0.2,
                        text: String(format: "%.1f초", model.calibrationSeconds))
        } header: {
            Text("학습한 보정")
        } footer: {
            FormNote("빠른 위치 맞춤은 학습한 보정은 그대로 두고 왼쪽 끝·가운데·오른쪽 끝을 볼 때의 값으로 아래 \"위치\"만 다시 계산합니다. "
                 + "전체 보정을 새로 하면 위치 조정은 초기화됩니다.")
        }
    }

    // MARK: - 위치

    private var positionSection: some View {
        Section {
            LimitSlider(id: "adjust.offset", title: "좌우 이동", value: $model.adjustment.offset, range: GazeAdjustment.offsetRange, step: 0.005,
                        text: String(format: "%+.1f%% (%@)", model.adjustment.offset * 100,
                                     model.adjustment.offset == 0 ? "그대로" : (model.adjustment.offset > 0 ? "오른쪽으로" : "왼쪽으로")))
            LimitSlider(id: "adjust.leftGain", title: "왼쪽 범위", value: $model.adjustment.leftGain, range: GazeAdjustment.gainRange, step: 0.05,
                        text: String(format: "×%.2f", model.adjustment.leftGain))
            LimitSlider(id: "adjust.rightGain", title: "오른쪽 범위", value: $model.adjustment.rightGain, range: GazeAdjustment.gainRange, step: 0.05,
                        text: String(format: "×%.2f", model.adjustment.rightGain))
            HStack {
                Spacer()
                Button("위치 초기화") { model.adjustment = model.adjustment.resettingPosition() }
                    .accessibilityIdentifier("adjust.resetPosition")
                    .disabled(model.adjustment.isPositionDefault)
            }
        } header: {
            Text("위치")
        } footer: {
            FormNote("추정이 한쪽으로 치우치면 좌우 이동, 화면 끝까지 닿지 않으면 그쪽 범위를 키우세요 (범위는 화면 가운데를 기준으로 늘어남).")
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
            FormNote("각 특징이 위치에 기여하는 정도를 배율로 조절합니다 (100% = 학습한 그대로, 0% = 사용 안 함). "
                 + "예: 눈동자 검출이 불안정하면 \"동공 위치\"를 낮추세요. 오른쪽 숫자는 지금 프레임의 기여량.")
        }
    }

    private func featureText(_ gain: Double, term: GazeBreakdown.Term?) -> String {
        let base = String(format: "%.0f%%", gain * 100)
        guard let term else { return base }
        guard term.slope != nil else { return base + " · 모델 미사용" }
        return model.faceDetected ? base + String(format: " · %+.1f%%", term.contribution * 100) : base
    }

    // MARK: - 움직임

    private var motionSection: some View {
        Section {
            LimitSlider(id: "adjust.smoothing", title: "떨림 억제 (기본 반응 속도)", value: $model.adjustment.smoothing,
                        range: GazeAdjustment.smoothingRange, step: 0.05,
                        text: String(format: "%.2fHz · %@", model.adjustment.smoothing,
                                     model.adjustment.smoothing < 0.6 ? "부드럽게" : (model.adjustment.smoothing > 1.5 ? "빠르게" : "보통")))
            LimitSlider(id: "adjust.responsiveness", title: "큰 시선 이동에 반응", value: $model.adjustment.responsiveness,
                        range: GazeAdjustment.responsivenessRange, step: 0.1,
                        text: String(format: "%.1f", model.adjustment.responsiveness))
            Picker("구역 나누기", selection: $model.adjustment.zones) {
                ForEach(GazeAdjustment.zoneChoices, id: \.self) { zones in
                    Text(zones == 0 ? "끔" : "\(zones)구역").tag(zones)
                }
            }
            .accessibilityIdentifier("adjust.zones")
            LimitSlider(id: "adjust.follow", title: "떠 있는 알림이 따라오는 최소 이동", value: $model.adjustment.followThreshold,
                        range: GazeAdjustment.followRange, step: 0.01,
                        text: String(format: "화면 폭의 %.0f%%", model.adjustment.followThreshold * 100))
        } header: {
            Text("움직임")
        } footer: {
            FormNote("떨림 억제를 낮추면 위치가 안정되지만 늦게 따라옵니다. 구역 나누기를 켜면 화면을 N칸으로 나눠 알림을 칸 가운데에 띄웁니다 "
                 + "(경계 근처에서 왔다 갔다 하지 않도록 칸 폭의 20%를 더 넘어야 옮김).")
        }
    }

    private func percent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
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
                        Text("얼굴이 보이지 않음").font(.caption).foregroundStyle(.secondary)
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
                    Text("모델 출력 (조정 전)").foregroundStyle(.secondary)
                    Text(raw.map { String(format: "%.0f%%", $0 * 100) } ?? "—").monospacedDigit()
                        .accessibilityIdentifier("adjust.raw")
                }
                HStack(spacing: 5) {
                    Circle().fill(Color.accentColor).frame(width: 10, height: 10)
                    Text("최종 위치 · 알림 자리(막대)").foregroundStyle(.secondary)
                    Text(final.map { String(format: "%.0f%%", $0 * 100) } ?? "—").monospacedDigit()
                        .accessibilityIdentifier("adjust.final")
                }
            }
            .font(.caption)
        }
    }
}
