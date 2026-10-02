import SwiftUI

/// 메뉴의 "처리 상세 정보": 지금 어떤 연산을, 어떻게, 1초에 몇 번 하는지.
/// 값은 메뉴가 열려 있는 동안 1초마다(시선 계산은 프레임마다) 갱신된다.
struct PipelineView: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.placementSource == .mouse {
                Text("위치 기준이 마우스로 설정되어 있어 카메라와 시선 추적이 꺼져 있습니다.")
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

    // MARK: - 현재 상태

    private var rateSection: some View {
        let rate = model.trackingRate
        let p = model.pipeline
        let live = model.liveStats
        return SectionBox("현재 상태") {
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
                PairGrid([
                    ("프로필", model.policy.applied.title),
                    ("카메라 프레임", "\(fps(p.receivedFPS))fps"),
                    ("목표 처리", perSecond(fps(model.targetHz))),
                    ("실제 처리", perSecond(fps(p.processedFPS))),
                    ("얼굴 검출", perSecond(fps(p.detectFPS))),
                    ("얼굴 감지", perSecond(fps(p.featuresFPS))),
                ])
            }
            if live.uptime > 5 {
                Text("실행 \(duration(live.uptime)) 동안 평균 초당 \(fps(live.averageProcessedFPS))회 (\(rateShareText(live.rateShare)))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 단계별

    private var stagesSection: some View {
        let p = model.pipeline
        let devices = model.visionDevices
        return SectionBox("프레임 처리 단계") {
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
                GridRow {
                    Text("단계").foregroundStyle(.secondary)
                    Text("내용").foregroundStyle(.secondary)
                    Text("초당 횟수").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text("소요 시간").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                stageRow("카메라", String(localized: "프레임 수신"), detail: cameraFormatText,
                         rate: p.receivedFPS, time: nil)
                stageRow("얼굴 검출", String(localized: "얼굴과 머리 방향 검출"),
                         detail: p.detectionInterval <= 1 ? devices.detection
                             : String(localized: "\(devices.detection), \(p.detectionInterval)프레임마다"),
                         rate: p.detectFPS, time: (p.detectWallMs, p.detectCPUms))
                if let landmarksDevice = devices.landmarks(for: model.analysisMode) {
                    stageRow("랜드마크", String(localized: "눈, 동공, 코 위치 검출"),
                             detail: String(localized: "\(landmarksDevice), \(model.analysisMode == .light ? 65 : 76)개"),
                             rate: p.landmarksFPS, time: (p.landmarksWallMs, p.landmarksCPUms))
                } else {
                    stageRow("랜드마크", String(localized: "사용 안 함"), detail: String(localized: "머리 방향 방식에서는 건너뜀"),
                             rate: 0, time: nil)
                }
                stageRow("특징 계산", String(localized: "코 방향, 동공 위치, 얼굴 위치 계산"), detail: "CPU",
                         rate: p.featuresFPS, time: (p.featuresCPUms, p.featuresCPUms))
                stageRow("시선 추정", String(localized: "화면 가로 위치 계산"), detail: listText([model.activeEstimatorKind.title, "CPU"]),
                         rate: p.featuresFPS, time: nil)
                stageRow("스무딩", String(localized: "떨림 보정"), detail: "CPU",
                         rate: p.featuresFPS, time: nil)
            }
        }
    }

    private var cameraFormatText: String {
        guard let format = model.cameraFormat else { return "—" }
        if format.sourceFormat == "yuvs" { return String(localized: "\(format.width)×\(format.height), 비압축") }
        return listText(["\(format.width)×\(format.height)", format.sourceFormat])
    }

    private func stageRow(_ name: LocalizedStringKey, _ op: String, detail: String, rate: Double,
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
        SectionBox("시선 계산") {
            if let b = model.gazeBreakdown, model.faceDetected {
                Text(b.modelName).fontWeight(.medium)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("특징").foregroundStyle(.secondary)
                        Text("값").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("기울기").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text("기여도").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
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
                // 평균 ± 기여 합 = 회귀 출력 → (점별 보간) → (수동 조정) → 스무딩 후
                let sum = b.terms.reduce(0) { $0 + $1.contribution }
                let regression = b.regressionOutput ?? b.raw
                let moverWidth = model.liveStats.mover?.screenWidth ?? 0
                let width = moverWidth > 0 ? moverWidth : Double(NSScreen.main?.frame.width ?? 0)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 2) {
                    GridRow {
                        Text("모델 출력").foregroundStyle(.secondary)
                        Text(verbatim: String(format: "%.1f%% %@ %.1f%% = %.1f%%", b.intercept * 100, sum >= 0 ? "+" : "−",
                                              abs(sum) * 100, regression * 100))
                    }
                    if b.regressionOutput != nil {
                        GridRow { Text("점별 보간").foregroundStyle(.secondary); Text(percentText(b.raw)) }
                    }
                    if abs(b.adjusted - b.raw) > 0.0005 {
                        GridRow { Text("수동 조정").foregroundStyle(.secondary); Text(percentText(b.adjusted)) }
                    }
                    GridRow { Text("스무딩 후").foregroundStyle(.secondary); Text(percentText(b.filtered)).fontWeight(.medium) }
                    if width > 0 {
                        GridRow {
                            Text("화면 위치").foregroundStyle(.secondary)
                            Text(verbatim: "\(Int(b.filtered * width)) / \(Int(width))pt")
                        }
                    }
                }
                Text("특징 이름 위에 포인터를 올리면 설명이 표시됩니다.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("얼굴이 감지되지 않아 마지막 위치를 유지합니다.").foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 알림 배치

    private var placementSection: some View {
        let live = model.liveStats
        return SectionBox("알림 배치") {
            if let mover = live.mover {
                Text(mover.mode.title)
                PairGrid([
                    ("창 확인", perSecond(fps(live.windowChecksPerSecond))),
                    ("창 이동", perSecond(fps(live.movesPerSecond))),
                    ("손쉬운 사용 API", perSecond(fps(live.axCallsPerSecond))),
                ])
                if let slot = mover.slotX, mover.screenWidth > 0 {
                    let fraction = (slot - mover.screenMinX) / mover.screenWidth
                    Text("다음 알림 위치: \(Int(slot))pt (화면의 \(Int((fraction * 100).rounded()))%)")
                        .foregroundStyle(.secondary)
                } else if !mover.containerFound {
                    Text("알림 창을 찾는 중입니다. 첫 알림이 표시되면 연결됩니다.").foregroundStyle(.secondary)
                } else {
                    Text("알림 창이 원래 위치(오른쪽 위)에 있습니다.").foregroundStyle(.secondary)
                }
            } else {
                Text("측정 중…").foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - 리소스 사용량

    private var costSection: some View {
        let p = model.pipeline
        let live = model.liveStats
        let wall = p.detectWallMs + p.landmarksWallMs
        let cpu = p.detectCPUms + p.landmarksCPUms + p.featuresCPUms
        var pairs: [(LocalizedStringKey, String)] = []
        if model.placementSource == .gaze {
            pairs.append(("Vision 처리", perSecond(fps(p.inferencesPerSecond))))
            pairs.append(("프레임당 시간", wall > 0 ? "\(ms(wall)) (CPU \(ms(cpu)))" : "—"))
        }
        pairs += [
            ("앱 전체 CPU", percent(live.processCPUPercent)),
            ("영상 처리 CPU", percent(live.trackingCPUPercent)),
            ("메인 스레드 CPU", percent(live.mainCPUPercent)),
        ]
        return SectionBox("리소스 사용량") {
            PairGrid(pairs)
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
        if minutes >= 60 { return String(localized: "\(minutes / 60)시간 \(minutes % 60)분") }
        return minutes > 0 ? String(localized: "\(minutes)분") : String(localized: "\(Int(seconds))초")
    }

    private func rateShareText(_ share: [TrackingRate: Double]) -> String {
        listText(TrackingRate.allCases.compactMap { rate in
            guard let value = share[rate], value >= 0.005 else { return nil }
            return "\(rate.title) \(Int((value * 100).rounded()))%"
        })
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

/// 이름·값을 두 쌍씩 한 줄에 놓는 표
private struct PairGrid: View {
    let pairs: [(title: LocalizedStringKey, value: String)]

    init(_ pairs: [(LocalizedStringKey, String)]) {
        self.pairs = pairs.map { (title: $0.0, value: $0.1) }
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 3) {
            ForEach(0..<(pairs.count + 1) / 2, id: \.self) { row in
                GridRow {
                    Text(pairs[row * 2].title).foregroundStyle(.secondary)
                    Text(pairs[row * 2].value)
                    if row * 2 + 1 < pairs.count {
                        Text(pairs[row * 2 + 1].title).foregroundStyle(.secondary).padding(.leading, 8)
                        Text(pairs[row * 2 + 1].value)
                    }
                }
            }
        }
    }
}

/// 제목 + 내용 묶음
private struct SectionBox<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }
}
