import SwiftUI

/// 설정 창 "연산 제한": 프로필과 단계별 처리 횟수·검출 간격·CPU 상한·카메라 끄기.
/// 값을 하나라도 바꾸면 지금 적용 중인 값에서 시작하는 "사용자 지정" 프로필이 된다.
struct LimitsView: View {
    @Bindable var model: AppModel

    var body: some View {
        let limits = model.limits
        Form {
            Section {
                Picker("프로필", selection: $model.profile) {
                    ForEach(PerformanceProfile.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("limits.profile")
                Text(model.profile.summary).font(.callout).foregroundStyle(.secondary)
                if model.profile == .automatic {
                    Text(model.policy.reason.map { String(localized: "현재: \(model.policy.applied.title) (\($0))") }
                         ?? String(localized: "현재: \(model.policy.applied.title)"))
                        .font(.callout)
                        .accessibilityIdentifier("limits.current")
                }
            } header: {
                Text("프로필")
            } footer: {
                FormNote("아래 값을 변경하면 현재 값을 기준으로 사용자 지정 프로필로 전환됩니다.")
            }

            Section {
                LimitSlider(id: "limits.activeHz", title: "활동 중", value: binding(\.activeHz), range: PerformanceLimits.activeRange,
                            step: 0.5, text: hz(limits.activeHz))
                LimitSlider(id: "limits.stillHz", title: "시선 고정", value: binding(\.stillHz), range: PerformanceLimits.stillRange,
                            step: 0.1, text: hz(limits.stillHz))
                LimitSlider(id: "limits.awayHz", title: "자리 비움", value: binding(\.awayHz), range: PerformanceLimits.awayRange,
                            step: 0.1, text: hz(limits.awayHz))
                Toggle("알림이 표시되는 동안 활동 중 처리 횟수 사용", isOn: binding(\.boostWhileNotification))
                    .accessibilityIdentifier("limits.boost")
            } header: {
                Text("초당 처리 횟수")
            } footer: {
                FormNote("카메라 프레임 속도는 이 값 이상 중 카메라가 지원하는 가장 낮은 값으로 자동 설정됩니다\(supportedText). 보정, 카메라 미리보기, 보정 조정 중에는 초당 \(Int(TrackingRate.liveHz))회로 고정됩니다.")
            }

            Section("상태 전환") {
                LimitSlider(id: "limits.stillAfter", title: "시선 고정 전환 시간", value: binding(\.stillAfter), range: PerformanceLimits.delayRange,
                            step: 0.5, text: String(localized: "\(fixed(limits.stillAfter))초"))
                LimitSlider(id: "limits.awayAfter", title: "자리 비움 전환 시간", value: binding(\.awayAfter), range: PerformanceLimits.delayRange,
                            step: 0.5, text: String(localized: "\(fixed(limits.awayAfter))초"))
            }

            Section {
                Stepper(value: binding(\.detectionInterval), in: PerformanceLimits.detectionRange) {
                    HStack {
                        Text("얼굴 검출 간격")
                        Spacer()
                        Text(limits.detectionInterval == 1 ? String(localized: "매 프레임") : String(localized: "\(limits.detectionInterval)프레임마다"))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .accessibilityIdentifier("limits.detectionInterval.value")
                    }
                }
                .accessibilityIdentifier("limits.detectionInterval")
                LimitSlider(id: "limits.cpuLimit", title: "영상 처리 CPU 한도", value: binding(\.cpuLimit), range: PerformanceLimits.cpuLimitRange,
                            step: 1, text: limits.cpuLimit == 0 ? String(localized: "제한 없음") : fixed(limits.cpuLimit, 0) + "%")
            } header: {
                Text("연산 절약")
            } footer: {
                FormNote("얼굴 검출을 건너뛴 프레임은 이전 얼굴 위치를 기준으로 추적합니다. 영상 처리 CPU가 한도를 넘으면 처리 횟수를 자동으로 줄입니다.")
            }

            Section {
                LimitSlider(id: "limits.notificationCheckHz", title: "알림 창 확인", value: binding(\.notificationCheckHz),
                            range: PerformanceLimits.notificationCheckRange, step: 1, text: hz(limits.notificationCheckHz))
                LimitSlider(id: "limits.cameraOff", title: "자리 비움 시 카메라 끄기", value: binding(\.cameraOffAfterAway),
                            range: PerformanceLimits.cameraOffRange, step: 1,
                            text: limits.cameraOffAfterAway == 0 ? String(localized: "사용 안 함") : String(localized: "\(Int(limits.cameraOffAfterAway))분 후"))
            } header: {
                Text("알림 및 카메라")
            } footer: {
                FormNote("알림 창 확인은 알림이 없을 때 알림 창 상태를 확인하는 횟수입니다. 값을 낮추면 알림 센터를 열 때 창 복원이 늦어질 수 있습니다. 카메라가 꺼진 후 키보드나 마우스를 사용하면 다시 켜집니다. 화면이 꺼지거나 잠기면 항상 카메라를 끕니다.")
            }

            Section("예상 처리량") {
                Text("활동 중 Vision 처리: 초당 \(fixed(limits.activeInferencesPerSecond))회 (얼굴 검출 \(fixed(limits.activeHz / Double(limits.detectionInterval)))회, 랜드마크 \(fixed(limits.activeHz))회)")
                    .monospacedDigit()
                    .accessibilityIdentifier("limits.estimate")
                if model.profile == .custom {
                    HStack {
                        Text("프로필 값으로 재설정")
                        Spacer()
                        ForEach([PerformanceProfile.performance, .balanced, .saver]) { preset in
                            Button(preset.title) { model.customLimits = preset.presetLimits ?? .balanced }
                                .accessibilityIdentifier("limits.resetTo.\(preset.rawValue)")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var supportedText: String {
        guard let supported = model.cameraFormat?.supportedFPS, !supported.isEmpty else { return "" }
        let list = listText(supported.map(formatFPS))
        return " " + String(localized: "(현재 카메라: \(list)fps)")
    }

    private func binding<T>(_ keyPath: WritableKeyPath<PerformanceLimits, T>) -> Binding<T> {
        Binding(get: { model.limits[keyPath: keyPath] },
                set: { value in model.editLimits { $0[keyPath: keyPath] = value } })
    }

    private func hz(_ value: Double) -> String {
        value < 1 ? String(localized: "초당 \(fixed(value))회 (\(fixed(1 / value))초마다 1회)") : perSecond(fixed(value))
    }
}

/// 제목 · 슬라이더 · 현재 값
struct LimitSlider: View {
    /// 접근성 식별자 (UI 테스트). 값 글자는 "<id>.value"
    let id: String
    let title: Text
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: String

    /// 제목이 글자 그대로(번역 키)인 경우
    init(id: String, title: LocalizedStringKey, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String) {
        self.init(id: id, titleText: Text(title), value: value, range: range, step: step, text: text)
    }

    /// 제목이 이미 번역된 글자인 경우 (예: 특징 이름)
    @_disfavoredOverload
    init(id: String, title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String) {
        self.init(id: id, titleText: Text(verbatim: title), value: value, range: range, step: step, text: text)
    }

    private init(id: String, titleText: Text, value: Binding<Double>, range: ClosedRange<Double>, step: Double, text: String) {
        self.id = id
        title = titleText
        _value = value
        self.range = range
        self.step = step
        self.text = text
    }

    var body: some View {
        HStack(spacing: 12) {
            title.frame(width: 180, alignment: .leading)
            // step 을 주면 macOS 슬라이더에 눈금이 빽빽하게 그려져서, 값만 반올림한다
            Slider(value: Binding(get: { value },
                                  set: { value = (($0 / step).rounded() * step).clamped(to: range) }),
                   in: range)
                .accessibilityIdentifier(id)
                .accessibilityLabel(title)
            Text(text)
                .accessibilityIdentifier(id + ".value")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
        }
    }
}

/// 그룹 Form 의 설명 문구 (기본은 오른쪽 정렬이라 왼쪽으로)
struct FormNote: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) { self.text = text }

    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
