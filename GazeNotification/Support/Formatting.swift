import Foundation

// 번역 문구에 숫자를 끼워 넣을 때 쓴다. `String(localized: "\(fixed(v))회/s")` 의 번역 키는 "%@회/s" 가 되어
// 언어마다 어순을 바꿀 수 있고, 숫자 모양(소수 자릿수·부호)은 모든 언어에서 같게 유지된다.

/// 소수 `digits` 자리 (예: 2.5)
func fixed(_ value: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", value)
}

/// 부호를 붙인 소수 (예: +3.1)
func signed(_ value: Double, _ digits: Int = 1) -> String {
    String(format: "%+.\(digits)f", value)
}

/// 비율 → 백분율 글자 (예: 0.034 → "3.4%")
func percentText(_ fraction: Double, _ digits: Int = 1) -> String {
    fixed(fraction * 100, digits) + "%"
}

/// 초당 횟수 (예: "초당 5.0회"). 숫자는 미리 정한 자릿수로 넘긴다
func perSecond(_ number: String) -> String {
    String(localized: "초당 \(number)회")
}

/// 짧은 항목 나열 (예: "활동 중 80%, 시선 고정 20%"). 일본어·중국어는 "、" 로 잇는다
func listText(_ items: [String]) -> String {
    let language = Bundle.main.preferredLocalizations.first ?? "ko"
    return items.joined(separator: language.hasPrefix("ja") || language.hasPrefix("zh") ? "、" : ", ")
}
