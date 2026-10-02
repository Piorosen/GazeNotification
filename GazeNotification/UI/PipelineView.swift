import SwiftUI

/// 메뉴의 "AI 연산 상세": 지금 어떤 연산을, 어떻게, 1초에 몇 번 하는지.
/// 값은 메뉴가 열려 있는 동안 1초마다(시선 계산은 프레임마다) 갱신된다.
struct PipelineView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.placementSource == .mouse {
                Text("위치 기준이 마우스라 카메라와 AI 연산이 꺼져 있습니다.")
                    .foregroundStyle(.secondary)
            } else {
                rateSection
                stagesSection
                gazeSection
            }
            placementSection
            costSection
        }
        .font(.caption)
        .monospacedDigit()
        .padding(.top, 4)
    }

    // MARK: - 지금 속도

    private var rateSection: some View {
        let rate = model.trackingRate
        let p = model.pipeline
        let live = model.liveStats
        return SectionBox("지금 하는 일") {
            HStack(spacing: 6) {
                Text(rate.title)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(rateColor(rate).opacity(0.2), in: Capsule())
                    .foregroundStyle(rateColor(rate))
                Text(rate.reason).foregroundStyle(.secondary)
            }
            if rate == .paused {
                Text(model.cameraPause?.title ?? rate.reason)
            } else {
                Text("\(model.policy.applied.title) 프로필 · 목표 \(fps(model.targetHz))회/s 처리 · 카메라 \(formatFPS(p.deviceFPS))fps · "
                     + (p.detectionInterval <= 1 ? "얼굴 검출 매번" : "얼굴 검출 \(p.detectionInterval)번에 1번"))
            }
            Text("측정: 받은 프레임 \(fps(p.receivedFPS))/s · 처리 \(fps(p.processedFPS))/s · 검출 \(fps(p.detectFPS))/s · 얼굴 있음 \(fps(p.featuresFPS))/s")
                .foregroundStyle(.secondary)
            if live.uptime > 5 {
                Text("실행 \(duration(live.uptime)) 동안 평균 \(fps(live.averageProcessedFPS))회/s · " + rateShareText(live.rateShare))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 단계별

    private var stagesSection: some View {
        let p = model.pipeline
        let devices = model.visionDevices
        let format = model.cameraFormat
        return SectionBox("1프레임 처리 순서") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                GridRow {
                    Text("단계").foregroundStyle(.secondary)
                    Text("연산 · 장치").foregroundStyle(.secondary)
                    Text("횟수/s").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text("1회 시간").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                stageRow("① 카메라",
                         format.map { "\($0.width)×\($0.height) \($0.sourceFormat == "yuvs" ? "비압축" : $0.sourceFormat) → \($0.outputFormat)" } ?? "—",
                         detail: "UVC 드라이버가 프레임 전달 (디코딩 없음)",
                         rate: p.receivedFPS, time: nil)
                stageRow("② 얼굴 검출", "VNDetectFaceRectangles · \(devices.detection)",
                         detail: p.detectionInterval <= 1 ? "이미지 전체 → 얼굴 상자 + 머리 방향(yaw)"
                             : "\(p.detectionInterval)번에 1번 · 그 사이는 직전 얼굴 상자를 눈에 맞춰 옮김",
                         rate: p.detectFPS, time: (p.detectWallMs, p.detectCPUms))
                if let landmarksDevice = devices.landmarks(for: model.analysisMode) {
                    stageRow("③ 랜드마크", "VNDetectFaceLandmarks \(model.analysisMode == .light ? 65 : 76)점 · \(landmarksDevice)",
                             detail: "얼굴 상자 안 → 눈·동공·코 등 점 좌표",
                             rate: p.landmarksFPS, time: (p.landmarksWallMs, p.landmarksCPUms))
                } else {
                    stageRow("③ 랜드마크", "사용 안 함 (머리 방향 방식)", detail: "얼굴 상자와 yaw 만 사용",
                             rate: 0, time: nil)
                }
                stageRow("④ 특징 계산", "기하 계산 · CPU",
                         detail: "점 좌표 → 코 방향·동공 위치·얼굴 위치",
                         rate: p.featuresFPS, time: (p.featuresCPUms, p.featuresCPUms))
                stageRow("⑤ 시선 추정", "\(model.activeEstimatorKind.title) · CPU",
                         detail: "특징 \(model.analysisMode.features.count)개 → 화면 가로 위치 x",
                         rate: p.featuresFPS, time: nil)
                stageRow("⑥ 스무딩", "One Euro 필터 · CPU",
                         detail: "느리게 움직이면 강하게, 빠르면 약하게 평활",
                         rate: p.featuresFPS, time: nil)
            }
        }
    }

    private func stageRow(_ name: String, _ op: String, detail: String, rate: Double,
                          time: (wall: Double, cpu: Double)?) -> some View {
        GridRow(alignment: .top) {
            Text(name).fontWeight(.medium)
            VStack(alignment: .leading, spacing: 1) {
                Text(op)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
            Text(fps(rate))
            VStack(alignment: .trailing, spacing: 1) {
                if let time, time.wall > 0 {
                    Text(ms(time.wall))
                    if time.wall - time.cpu > 0.5 {
                        Text("CPU \(ms(time.cpu))").font(.caption2).foregroundStyle(.secondary)
                    }
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 시선 계산

    @ViewBuilder
    private var gazeSection: some View {
        SectionBox("시선 계산 (최근 프레임)") {
            if let b = model.gazeBreakdown, model.faceDetected {
                Text(b.modelName).fontWeight(.medium)
                Text(b.formula).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("특징").foregroundStyle(.secondary)
                        Text("값").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("기울기").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("x 기여").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    }
                    ForEach(b.terms) { term in
                        GridRow {
                            Text(term.feature.title).help(term.feature.detail)
                            Text(term.feature.format(term.value))
                            Text(term.slopeText + (term.slope != nil && abs(term.gain - 1) > 0.001 ? String(format: " (%.0f%%)", term.gain * 100) : ""))
                                .foregroundStyle(term.slope == nil ? .tertiary : .secondary)
                            Text(term.slope == nil ? "—" : String(format: "%+.1f%%", term.contribution * 100))
                                .foregroundStyle(term.slope == nil ? Color.secondary : contributionColor(term.contribution))
                        }
                    }
                }
                let sum = b.terms.reduce(0) { $0 + $1.contribution }
                let interpolated = b.regressionOutput == nil ? "" : String(format: "  →  점별 보간 %.1f%%", b.raw * 100)
                let regression = b.regressionOutput ?? b.raw
                let adjustedText = abs(b.adjusted - b.raw) > 0.0005 ? String(format: "  →  수동 조정 %.1f%%", b.adjusted * 100) : ""
                Text(String(format: "%.1f%% %@ %.1f%% = %.1f%%", b.intercept * 100, sum >= 0 ? "+" : "−", abs(sum) * 100, regression * 100)
                     + interpolated + adjustedText + String(format: "  →  필터 후 %.1f%%", b.filtered * 100))
                    .fontWeight(.medium)
                let moverWidth = model.liveStats.mover?.screenWidth ?? 0
                let width = moverWidth > 0 ? moverWidth : Double(NSScreen.main?.frame.width ?? 0)
                if width > 0 {
                    Text("= 화면 왼쪽에서 \(Int(b.filtered * width))pt (전체 \(Int(width))pt)")
                        .foregroundStyle(.secondary)
                }
                Text("특징 이름에 마우스를 올리면 측정 방법이 보입니다.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("얼굴이 보이지 않아 계산하지 않음 (마지막 위치 유지)").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 알림 배치

    private var placementSection: some View {
        let live = model.liveStats
        return SectionBox("알림 배치 (Accessibility)") {
            if let mover = live.mover {
                Text(mover.mode.rawValue)
                Text("창 확인 \(fps(live.windowChecksPerSecond))회/s (창 서버, AX 아님) · "
                     + "AX 호출 \(fps(live.axCallsPerSecond))회/s · 창 이동 \(fps(live.movesPerSecond))회/s")
                    .foregroundStyle(.secondary)
                if let slot = mover.slotX, mover.screenWidth > 0 {
                    let fraction = (slot - mover.screenMinX) / mover.screenWidth
                    Text("다음 알림 자리: x = \(Int(slot))pt (화면 \(Int((fraction * 100).rounded()))%)")
                        .foregroundStyle(.secondary)
                } else if !mover.containerFound {
                    Text("알림 창을 아직 못 찾음 — 첫 알림이 뜨면 확보").foregroundStyle(.secondary)
                } else {
                    Text("알림 창 원위치 (오른쪽 위)").foregroundStyle(.secondary)
                }
            } else {
                Text("1초 뒤 표시").foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 비용

    private var costSection: some View {
        let p = model.pipeline
        let live = model.liveStats
        return SectionBox("비용") {
            if model.placementSource == .gaze {
                Text("신경망 추론 \(fps(p.inferencesPerSecond))회/s (Neural Engine) · Vision 호출 중 CPU \(percent(p.cpuPercent))")
                let wall = p.detectWallMs + p.landmarksWallMs
                let cpu = p.detectCPUms + p.landmarksCPUms + p.featuresCPUms
                if wall > 0 {
                    Text("프레임당 \(ms(wall)) 중 CPU \(ms(cpu)) — 나머지는 Neural Engine 결과 대기")
                        .foregroundStyle(.secondary)
                }
            }
            Text("GazeNotification 전체 CPU \(percent(live.processCPUPercent)) = 카메라·AI \(percent(live.trackingCPUPercent)) + 메인 스레드 \(percent(live.mainCPUPercent)) (코어 1개 = 100%)")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 표시 도우미

    private func fps(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func ms(_ value: Double) -> String {
        value >= 10 ? String(format: "%.0fms", value) : String(format: "%.1fms", value)
    }

    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60)시간 \(minutes % 60)분" : (minutes > 0 ? "\(minutes)분" : "\(Int(seconds))초")
    }

    private func rateShareText(_ share: [TrackingRate: Double]) -> String {
        TrackingRate.allCases
            .compactMap { rate in
                guard let value = share[rate], value >= 0.005 else { return nil }
                return "\(rate.title) \(Int((value * 100).rounded()))%"
            }
            .joined(separator: " · ")
    }

    private func rateColor(_ rate: TrackingRate) -> Color {
        switch rate {
        case .live: .orange
        case .normal: .green
        case .still: .blue
        case .away: .gray
        case .paused: .secondary
        }
    }

    private func contributionColor(_ value: Double) -> Color {
        abs(value) < 0.01 ? .secondary : (value > 0 ? .blue : .purple)
    }
}

/// 제목 + 내용 묶음
private struct SectionBox<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}
