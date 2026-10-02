import Charts
import SwiftUI

/// 설정 창 "성능 그래프": 최근 1~10분의 CPU·처리 횟수·처리 시간. 세 그래프는 마우스 위치(시각)를 함께 가리킨다.
struct PerformanceView: View {
    let model: AppModel
    @AppStorage("ui.chartRangeSeconds") private var rangeSeconds = 300
    @State private var selection: Date?

    private struct ChartRange: Identifiable {
        let seconds: Int
        let title: String
        var id: Int { seconds }
    }
    private static let ranges = [ChartRange(seconds: 60, title: String(localized: "1분")),
                                 ChartRange(seconds: 300, title: String(localized: "5분")),
                                 ChartRange(seconds: 600, title: String(localized: "10분"))]

    private var cpuRule: (value: Double, label: String)? {
        let limit = model.limits.cpuLimit
        guard limit > 0 else { return nil }
        return (limit, String(localized: "카메라·AI 상한 \(Int(limit))%"))
    }

    var body: some View {
        let now = model.history.last?.time ?? Date()
        // 기록이 기간보다 짧으면 있는 만큼만 (빈 축 방지)
        let start = max(now.addingTimeInterval(-Double(rangeSeconds)), model.history.first?.time ?? now)
        let samples = model.history.filter { $0.time >= start }
        let domain = start...max(now, start.addingTimeInterval(10))

        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                PolicyHeader(model: model)

                HStack {
                    Text("최근").foregroundStyle(.secondary)
                    Picker("기간", selection: $rangeSeconds) {
                        ForEach(Self.ranges) { Text($0.title).tag($0.seconds) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    .accessibilityIdentifier("performance.range")
                    Spacer()
                    Text("1초마다 기록 (시작 후 10초는 모델 로드라 제외) · 그래프 위에 마우스를 올리면 그 시각 값")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ChartCard(title: "CPU 사용량", unit: "%", note: "코어 1개 = 100%. 카메라·AI = 메인 스레드를 뺀 나머지(카메라 수신·Vision·Neural Engine 드라이버)") {
                    HistoryChart(id: "cpu", samples: samples, domain: domain, unit: "%", selection: $selection,
                                 series: [
                                     .init(name: String(localized: "앱 전체"), color: ChartPalette.slot1) { $0.processCPU },
                                     .init(name: String(localized: "카메라·AI"), color: ChartPalette.slot2) { $0.trackingCPU },
                                     .init(name: String(localized: "메인 스레드 (UI·알림 감시)"), color: ChartPalette.slot3) { $0.mainCPU },
                                 ],
                                 rule: cpuRule,
                                 format: { String(format: "%.1f%%", $0) })
                }

                ChartCard(title: "처리 횟수", unit: String(localized: "회/s"), note: "처리 = Vision 을 돌린 프레임, 얼굴 검출 = 그중 전체 검출(나머지는 추적), 목표 = 지금 정책이 요청한 값") {
                    HistoryChart(id: "rate", samples: samples, domain: domain, unit: String(localized: "회/s"), selection: $selection,
                                 series: [
                                     .init(name: String(localized: "처리"), color: ChartPalette.slot1) { $0.processedHz },
                                     .init(name: String(localized: "얼굴 검출"), color: ChartPalette.slot2) { $0.detectHz },
                                     .init(name: String(localized: "카메라 프레임"), color: ChartPalette.slot3) { $0.receivedFPS },
                                     .init(name: String(localized: "목표"), color: ChartPalette.reference, dashed: true) { $0.targetHz },
                                 ],
                                 format: { String(format: "%.1f", $0) })
                }

                ChartCard(title: "1회 처리 시간", unit: "ms", note: "Neural Engine 결과를 기다리는 시간 포함. 처리하지 않은 시각은 비어 있음") {
                    HistoryChart(id: "time", samples: samples, domain: domain, unit: "ms", selection: $selection,
                                 series: [
                                     .init(name: String(localized: "얼굴 검출"), color: ChartPalette.slot1) { $0.detectHz > 0 ? $0.detectMs : nil },
                                     .init(name: String(localized: "랜드마크"), color: ChartPalette.slot2) { $0.processedHz > 0 ? $0.landmarksMs : nil },
                                 ],
                                 format: { String(format: "%.1fms", $0) })
                }

                SummaryGrid(samples: samples)
            }
            .padding(20)
        }
    }
}

// MARK: - 지금 적용 중인 정책

private struct PolicyHeader: View {
    let model: AppModel

    var body: some View {
        let policy = model.policy
        let power = model.power
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("지금 적용: \(policy.applied.title)").font(.title3.weight(.semibold))
                    .accessibilityIdentifier("performance.applied")
                if policy.selected == .automatic, let reason = policy.reason {
                    Text("자동 · \(reason)").foregroundStyle(.secondary)
                }
                Spacer()
                Button("연산 제한 바꾸기…") { model.settingsTab = .limits }
            }
            HStack(spacing: 14) {
                Label(power.powerText, systemImage: power.onBattery ? "battery.75percent" : "powerplug")
                Label(power.lowPowerMode ? String(localized: "저전력 모드 켬") : String(localized: "저전력 모드 끔"), systemImage: "leaf")
                Label("발열 \(power.thermalText)", systemImage: "thermometer.medium")
                Label("추적: \(model.trackingRate.title)", systemImage: "eye")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            if let pause = model.cameraPause {
                Label(pause.title, systemImage: "zzz").font(.callout)
            } else if model.governorScale < 0.999 {
                let scale = fixed(model.governorScale * 100, 0)
                Label(model.governorScale <= 0.051
                      ? String(localized: "카메라·AI CPU 가 상한을 넘어 처리 횟수를 \(scale)% 로 줄이는 중 — 상한이 카메라 수신 비용보다 낮아 최소 속도로 동작")
                      : String(localized: "카메라·AI CPU 가 상한을 넘어 처리 횟수를 \(scale)% 로 줄이는 중"),
                      systemImage: "speedometer")
                    .font(.callout)
            }
        }
    }
}

// MARK: - 그래프

enum ChartPalette {
    // 검증한 범주형 팔레트의 1~3번 (밝은/어두운 모드 각각)
    static let slot1 = dynamic(light: 0x2a78d6, dark: 0x3987e5)
    static let slot2 = dynamic(light: 0xeb6834, dark: 0xd95926)
    static let slot3 = dynamic(light: 0x1baf7a, dark: 0x199e70)
    /// 목표·상한처럼 기준선은 범주색 대신 중립 회색 점선
    static let reference = dynamic(light: 0x7a7974, dark: 0xa3a29b)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

struct ChartSeries: Identifiable {
    let name: String
    let color: Color
    var dashed = false
    let value: (PerformanceSample) -> Double?

    var id: String { name }

    init(name: String, color: Color, dashed: Bool = false, value: @escaping (PerformanceSample) -> Double?) {
        self.name = name
        self.color = color
        self.dashed = dashed
        self.value = value
    }
}

private struct ChartCard<Content: View>: View {
    let title: LocalizedStringKey
    let unit: String
    let note: LocalizedStringKey
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.headline)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            content
            Text(note).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 시간축 꺾은선 그래프 + 현재 값 범례 + 마우스 위치 십자선·툴팁
struct HistoryChart: View {
    /// 접근성 식별자 접두사 (UI 테스트): "chart.<id>", 범례 값 "chart.<id>.legend.<순번>", 기록 수 "chart.<id>.count"
    let id: String
    let samples: [PerformanceSample]
    let domain: ClosedRange<Date>
    let unit: String
    @Binding var selection: Date?
    let series: [ChartSeries]
    var rule: (value: Double, label: String)?
    let format: (Double) -> String

    var body: some View {
        let selected = selection.flatMap(nearest)
        VStack(alignment: .leading, spacing: 6) {
            legend(for: selected ?? samples.last)
            Chart {
                ForEach(series) { s in
                    ForEach(samples) { sample in
                        if let value = s.value(sample) {
                            LineMark(x: .value("시각", sample.time), y: .value(unit, value),
                                     series: .value("항목", s.name))
                                .foregroundStyle(s.color)
                                .lineStyle(StrokeStyle(lineWidth: s.dashed ? 1.5 : 2, lineCap: .round,
                                                       lineJoin: .round, dash: s.dashed ? [4, 3] : []))
                        }
                    }
                }
                if let rule {
                    RuleMark(y: .value("상한", rule.value))
                        .foregroundStyle(ChartPalette.reference)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text(rule.label).font(.caption2).foregroundStyle(.secondary)
                        }
                }
                if let selected {
                    RuleMark(x: .value("선택", selected.time))
                        .foregroundStyle(Color.secondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                            tooltip(selected)
                        }
                    ForEach(series) { s in
                        if let value = s.value(selected) {
                            PointMark(x: .value("시각", selected.time), y: .value(unit, value))
                                .foregroundStyle(s.color)
                                .symbolSize(50)
                        }
                    }
                }
            }
            .chartXScale(domain: domain)
            .chartYScale(domain: 0...yMax)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(Self.timeFormatter.string(from: date)) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                    AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                    AxisValueLabel()
                }
            }
            .chartLegend(.hidden)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plot = proxy.plotFrame else { return }
                                let x = location.x - geometry[plot].origin.x
                                selection = proxy.value(atX: x, as: Date.self)
                            case .ended:
                                selection = nil
                            }
                        }
                }
            }
            .frame(height: 150)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("chart.\(id)")
            .accessibilityLabel("\(samples.count)개 기록")
            .accessibilityValue(selected.map { String(localized: "선택 \(Self.timeFormatter.string(from: $0.time))") } ?? "\(samples.count)")
        }
    }

    /// 범례: 색 + 이름 + 값 (마우스가 없으면 최신 값). 색만으로 구분하지 않도록 값을 글자로 함께 보여 준다.
    private func legend(for sample: PerformanceSample?) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(series.enumerated()), id: \.element.id) { index, s in
                HStack(spacing: 5) {
                    swatch(s)
                    Text(s.name).foregroundStyle(.secondary)
                    Text(sample.flatMap(s.value).map(format) ?? "—")
                        .monospacedDigit()
                        .accessibilityIdentifier("chart.\(id).legend.\(index)")
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
    }

    private func swatch(_ s: ChartSeries) -> some View {
        Capsule()
            .fill(s.color)
            .frame(width: 14, height: s.dashed ? 2 : 3)
            .opacity(s.dashed ? 0.8 : 1)
    }

    private func tooltip(_ sample: PerformanceSample) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sample.time.formatted(date: .omitted, time: .standard))
                .font(.caption2).foregroundStyle(.secondary)
            ForEach(series) { s in
                HStack(spacing: 5) {
                    swatch(s)
                    Text(s.name)
                    Spacer(minLength: 8)
                    Text(s.value(sample).map(format) ?? "—").monospacedDigit()
                }
            }
            Text("\(sample.profile.title) · \(sample.rate.title)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(8)
        .frame(width: 210)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private var yMax: Double {
        let values = samples.flatMap { sample in series.compactMap { $0.value(sample) } } + [rule?.value ?? 0]
        let top = values.max() ?? 1
        return max(1, top * 1.15)
    }

    private func nearest(to date: Date) -> PerformanceSample? {
        samples.min { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }
    }
}

// MARK: - 기간 요약

private struct SummaryGrid: View {
    let samples: [PerformanceSample]

    var body: some View {
        let n = Double(max(samples.count, 1))
        func average(_ value: (PerformanceSample) -> Double) -> Double { samples.reduce(0) { $0 + value($1) } / n }
        let processed = average(\.processedHz)
        let detected = average(\.detectHz)
        let shares = Dictionary(grouping: samples, by: \.rate).mapValues { Double($0.count) / n }

        return VStack(alignment: .leading, spacing: 6) {
            Text("기간 평균").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow {
                    stat("앱 전체 CPU", fixed(average(\.processCPU)) + "%")
                    stat("카메라·AI CPU", fixed(average(\.trackingCPU)) + "%")
                    stat("메인 스레드 CPU", fixed(average(\.mainCPU)) + "%")
                }
                GridRow {
                    stat("처리", String(localized: "\(fixed(processed))회/s"))
                    stat("얼굴 검출", processed > 0
                         ? String(localized: "\(fixed(detected))회/s (\(fixed(detected / processed * 100, 0))%)") : "—")
                    stat("알림 창 확인", String(localized: "\(fixed(average(\.notificationChecksPerSecond)))회/s · AX \(fixed(average(\.axCallsPerSecond)))회/s"))
                }
            }
            Text(TrackingRate.allCases.compactMap { rate in
                guard let share = shares[rate], share >= 0.005 else { return nil }
                return "\(rate.title) \(Int((share * 100).rounded()))%"
            }.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit()
        }
    }
}
