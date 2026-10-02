import SwiftUI

/// 설정 창 "AI 모드": 얼굴 분석 방식 · 연산 장치 · 시선 추정 모델을 고른다.
/// 방식마다 실제로 측정한 처리 비용과, 마지막 보정으로 학습한 모델들의 오차를 나란히 보여 준다.
struct AIModeView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            analysisSection
            deviceSection
            estimatorSection
            Section {
                HStack {
                    Button("다시 보정") { model.startCalibration() }
                        .accessibilityIdentifier("ai.recalibrate")
                        .disabled(!model.isEnabled || model.isCalibrating || model.placementSource != .gaze)
                    Spacer()
                }
            } footer: {
                FormNote("한 번 보정하면 모든 분석 방식과 모델이 함께 학습되므로, 다시 보정하지 않고 바꿔 가며 비교할 수 있습니다. 교차 검증 오차는 보정 점을 하나씩 제외하고 예측한 오차로, 실제 사용 시 정확도에 더 가깝습니다.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 얼굴 분석 방식

    private var analysisSection: some View {
        Section {
            ForEach(AnalysisMode.allCases) { mode in
                ModeRow(selected: model.analysisMode == mode, title: mode.title, detail: mode.detail,
                        trailing: modeSummary(mode)) {
                    model.analysisMode = mode
                }
                .accessibilityIdentifier("ai.mode.\(mode.rawValue)")
                .accessibilityAddTraits(model.analysisMode == mode ? .isSelected : [])
            }
        } header: {
            Text("얼굴 분석 방식")
        } footer: {
            FormNote("오른쪽 값은 이 Mac에서 측정한 1회 처리당 CPU 시간과, 마지막 보정에서 가장 정확했던 모델의 오차입니다. CPU 시간은 해당 방식을 사용한 후에 표시됩니다.")
        }
    }

    private func modeSummary(_ mode: AnalysisMode) -> [String] {
        var lines: [String] = []
        if let cost = model.modeCosts[ModeCostKey(mode: mode, device: model.computePreference)] {
            lines.append(String(localized: "1회 처리 CPU \(fixed(cost.cpuMs))ms"))
        } else {
            lines.append(String(localized: "CPU 측정 안 됨"))
        }
        if let calibration = model.calibration, let kind = calibration.bestKind(for: mode),
           let estimator = calibration.estimator(mode, kind) {
            let error = estimator.crossValidationRMSE ?? estimator.trainingRMSE
            lines.append(String(localized: "오차 \(percentText(error)) (\(kind.title))"))
        } else {
            lines.append(String(localized: "보정 안 됨"))
        }
        return lines
    }

    // MARK: - 연산 장치

    private var deviceSection: some View {
        Section {
            Picker("Vision 처리 장치", selection: $model.computePreference) {
                ForEach(ComputePreference.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("ai.device")
            Text(model.computePreference.detail).font(.callout).foregroundStyle(.secondary)
            let devices = model.visionDevices
            Text("현재 할당: 얼굴 검출 \(devices.detection), 랜드마크(76개) \(devices.landmarks76), 랜드마크(65개) \(devices.landmarks65)")
                .font(.callout)
                .accessibilityIdentifier("ai.devices")
            let costs = ComputePreference.allCases.compactMap { device -> String? in
                model.modeCosts[ModeCostKey(mode: model.analysisMode, device: device)]
                    .map { "\(device == .automatic ? String(localized: "자동") : device.title) \(fixed($0.cpuMs))ms" }
            }
            if !costs.isEmpty {
                Text("\(model.analysisMode.shortTitle) 방식 1회 처리 CPU: \(listText(costs))")
                    .font(.callout).monospacedDigit()
            }
        } header: {
            Text("연산 장치")
        } footer: {
            FormNote("장치를 변경하면 모델을 다시 불러오는 동안 잠시 느려질 수 있습니다. CPU 변화는 성능 탭에서 확인할 수 있습니다.")
        }
    }

    // MARK: - 시선 추정 모델

    private var estimatorSection: some View {
        Section {
            Picker("시선 추정 모델", selection: $model.estimatorChoice) {
                ForEach(EstimatorChoice.allCases) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("ai.estimator")
            if let kind = model.estimatorChoice.kind, kind != model.activeEstimatorKind {
                Text("\(kind.title) 모델은 \(model.analysisMode.shortTitle) 방식으로 학습되지 않아 \(model.activeEstimatorKind.title) 모델을 사용합니다.")
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack {
                Text("모델")
                Spacer()
                Text("학습 오차").frame(width: 70, alignment: .trailing)
                Text("교차 검증").frame(width: 70, alignment: .trailing)
                Text("").frame(width: 110, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ForEach(EstimatorKind.allCases) { kind in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(kind.title).fontWeight(kind == model.activeEstimatorKind ? .semibold : .regular)
                        Text(kind.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Text(errorText(training: kind)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        .accessibilityIdentifier("ai.estimator.\(kind.rawValue).training")
                    Text(errorText(crossValidation: kind)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        .accessibilityIdentifier("ai.estimator.\(kind.rawValue).cv")
                    Text(statusText(kind))
                        .accessibilityIdentifier("ai.estimator.\(kind.rawValue).status")
                        .font(.caption)
                        .foregroundStyle(kind == model.activeEstimatorKind ? Color.accentColor : .secondary)
                        .frame(width: 110, alignment: .leading)
                }
                .font(.callout)
            }
        } header: {
            Text("시선 추정 모델 (\(model.analysisMode.shortTitle) 방식)")
        } footer: {
            FormNote("오차는 화면 폭에 대한 비율입니다. 자동을 선택하면 교차 검증 오차가 가장 작은 모델을 사용합니다.")
        }
    }

    private func errorText(training kind: EstimatorKind) -> String {
        if kind == .formula {
            return model.calibration?.formulaRMSE[model.analysisMode].map { String(format: "%.1f%%", $0 * 100) } ?? "—"
        }
        return model.calibration?.estimator(model.analysisMode, kind).map { String(format: "%.1f%%", $0.trainingRMSE * 100) } ?? "—"
    }

    private func errorText(crossValidation kind: EstimatorKind) -> String {
        if kind == .formula { return "—" }
        return model.calibration?.estimator(model.analysisMode, kind)?.crossValidationRMSE
            .map { String(format: "%.1f%%", $0 * 100) } ?? "—"
    }

    private func statusText(_ kind: EstimatorKind) -> String {
        var parts: [String] = []
        if kind == model.activeEstimatorKind { parts.append(String(localized: "사용 중")) }
        if kind != .formula, model.calibration?.bestKind(for: model.analysisMode) == kind { parts.append(String(localized: "자동 선택")) }
        if kind != .formula, model.calibration?.estimator(model.analysisMode, kind) == nil {
            parts.append(model.calibration == nil ? String(localized: "보정 필요") : String(localized: "학습 안 됨"))
        }
        return listText(parts)
    }
}

/// 라디오 버튼처럼 고르는 한 줄 (제목 · 설명 · 오른쪽 요약)
private struct ModeRow: View {
    let selected: Bool
    let title: String
    let detail: String
    let trailing: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.body)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(selected ? .semibold : .regular)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(trailing, id: \.self) { Text($0).font(.caption).monospacedDigit().foregroundStyle(.secondary) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
