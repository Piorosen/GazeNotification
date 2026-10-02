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
                Text(model.profile.summary).font(.callout).foregroundStyle(.secondary)
                if model.profile == .automatic {
                    Text("지금: \(model.policy.applied.title)" + (model.policy.reason.map { " — \($0)" } ?? ""))
                        .font(.callout)
                }
            } header: {
                Text("프로필")
            } footer: {
                FormNote("아래 값을 바꾸면 지금 적용 중인 값을 바탕으로 \"사용자 지정\"으로 바뀝니다.")
            }

            Section {
                LimitSlider(title: "시선이 움직일 때", value: binding(\.activeHz), range: PerformanceLimits.activeRange,
                            step: 0.5, text: hz(limits.activeHz))
                LimitSlider(title: "시선이 머물 때", value: binding(\.stillHz), range: PerformanceLimits.stillRange,
                            step: 0.1, text: hz(limits.stillHz))
                LimitSlider(title: "얼굴이 안 보일 때", value: binding(\.awayHz), range: PerformanceLimits.awayRange,
                            step: 0.1, text: hz(limits.awayHz))
                Toggle("알림이 떠 있는 동안은 \"움직일 때\" 속도로", isOn: binding(\.boostWhileNotification))
            } header: {
                Text("처리 횟수 (초당 Vision 처리)")
            } footer: {
                FormNote("카메라 장치 fps 는 이 값 이상에서 카메라가 지원하는 가장 낮은 값으로 자동 설정됩니다\(supportedText). 보정·카메라 미리보기·보정 조정 중에는 \(Int(TrackingRate.liveHz))회/s 로 고정.")
            }

            Section("단계 전환") {
                LimitSlider(title: "\"머묾\"으로 보는 시간", value: binding(\.stillAfter), range: PerformanceLimits.delayRange,
                            step: 0.5, text: String(format: "%.1f초", limits.stillAfter))
                LimitSlider(title: "\"자리 비움\"으로 보는 시간", value: binding(\.awayAfter), range: PerformanceLimits.delayRange,
                            step: 0.5, text: String(format: "%.1f초", limits.awayAfter))
            }

            Section {
                Stepper(value: binding(\.detectionInterval), in: PerformanceLimits.detectionRange) {
                    HStack {
                        Text("얼굴 전체 검출")
                        Spacer()
                        Text(limits.detectionInterval == 1 ? "매번" : "\(limits.detectionInterval)번에 1번")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                LimitSlider(title: "카메라·AI CPU 상한", value: binding(\.cpuLimit), range: PerformanceLimits.cpuLimitRange,
                            step: 1, text: limits.cpuLimit == 0 ? "제한 없음" : String(format: "%.0f%%", limits.cpuLimit))
            } header: {
                Text("연산 줄이기")
            } footer: {
                FormNote("검출 사이 프레임은 직전 얼굴 위치를 눈에 맞춰 옮겨 랜드마크만 찾습니다 (검출 1회를 건너뛰면 CPU 약 9ms + Neural Engine 11ms 절약, 고개를 크게 돌리면 바로 다시 검출). "
                     + "CPU 상한은 메인 스레드를 뺀 카메라·AI CPU(코어 1개 = 100%) 기준이며, 넘으면 처리 횟수를 자동으로 줄입니다.")
            }

            Section {
                LimitSlider(title: "알림 창 확인", value: binding(\.notificationCheckHz),
                            range: PerformanceLimits.notificationCheckRange, step: 1, text: hz(limits.notificationCheckHz))
                LimitSlider(title: "오래 자리 비우면 카메라 끄기", value: binding(\.cameraOffAfterAway),
                            range: PerformanceLimits.cameraOffRange, step: 1,
                            text: limits.cameraOffAfterAway == 0 ? "끄지 않음" : "\(Int(limits.cameraOffAfterAway))분 후")
            } header: {
                Text("알림 감시 · 카메라")
            } footer: {
                FormNote("알림 창 확인은 알림이 없을 때 창 서버에 묻는 횟수입니다 (낮추면 알림 센터 패널을 열 때 원위치가 조금 늦어짐). "
                     + "카메라를 끈 뒤 키보드·마우스를 쓰면 다시 켭니다. 화면이 꺼지거나 잠기면 설정과 관계없이 카메라를 끕니다.")
            }

            Section("예상") {
                Text(String(format: "시선이 움직일 때 신경망 추론 약 %.1f회/s (얼굴 검출 %.1f + 랜드마크 %.1f)",
                            limits.activeInferencesPerSecond, limits.activeHz / Double(limits.detectionInterval), limits.activeHz))
                    .monospacedDigit()
                if model.profile == .custom {
                    HStack {
                        Text("프로필 값으로 되돌리기")
                        Spacer()
                        ForEach([PerformanceProfile.performance, .balanced, .saver]) { preset in
                            Button(preset.title) { model.customLimits = preset.presetLimits ?? .balanced }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var supportedText: String {
        guard let supported = model.cameraFormat?.supportedFPS, !supported.isEmpty else { return "" }
        return " (지금 카메라: " + supported.map(formatFPS).joined(separator: "·") + "fps)"
    }

    private func binding<T>(_ keyPath: WritableKeyPath<PerformanceLimits, T>) -> Binding<T> {
        Binding(get: { model.limits[keyPath: keyPath] },
                set: { value in model.editLimits { $0[keyPath: keyPath] = value } })
    }

    private func hz(_ value: Double) -> String {
        value < 1 ? String(format: "%.1f회/s (%.1f초에 1번)", value, 1 / value) : String(format: "%.1f회/s", value)
    }
}

/// 제목 · 슬라이더 · 현재 값
struct LimitSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 180, alignment: .leading)
            // step 을 주면 macOS 슬라이더에 눈금이 빽빽하게 그려져서, 값만 반올림한다
            Slider(value: Binding(get: { value },
                                  set: { value = (($0 / step).rounded() * step).clamped(to: range) }),
                   in: range)
            Text(text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .trailing)
        }
    }
}

/// 그룹 Form 의 설명 문구 (기본은 오른쪽 정렬이라 왼쪽으로)
struct FormNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
