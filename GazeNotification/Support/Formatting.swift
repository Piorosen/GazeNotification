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
