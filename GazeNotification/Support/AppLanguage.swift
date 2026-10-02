import AppKit

/// 앱 화면 언어 (언어팩). 앱 전용 `AppleLanguages` 값을 바꾸고 다시 시작하면 적용된다
/// (시스템 설정 → 일반 → 언어 및 지역 → 앱별 언어와 같은 설정).
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case korean = "ko"
    case english = "en"
    case japanese = "ja"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    /// 언어 이름은 그 언어로 쓴다 (다른 언어 화면에서도 찾을 수 있게). "시스템 설정 따름"만 번역한다.
    var title: String {
        switch self {
        case .system: String(localized: "시스템 설정 따름")
        case .korean: "한국어"
        case .english: "English"
        case .japanese: "日本語"
        case .simplifiedChinese: "简体中文"
        }
    }

    /// 번역이 들어 있는 언어 (시스템 제외)
    static var packs: [AppLanguage] { allCases.filter { $0 != .system } }

    static let key = "AppleLanguages"

    /// `domain` 에 앱 전용으로 저장된 언어 (없으면 시스템 설정 따름)
    static func stored(in defaults: UserDefaults, domain: String) -> AppLanguage {
        guard let list = defaults.persistentDomain(forName: domain)?[key] as? [String], let first = list.first else { return .system }
        return packs.first { first == $0.rawValue || first.hasPrefix($0.rawValue + "-") } ?? .system
    }

    /// 앱 전용 언어로 저장 (시스템 설정 따름이면 지운다)
    func store(in defaults: UserDefaults) {
        if self == .system {
            defaults.removeObject(forKey: Self.key)
        } else {
            defaults.set([rawValue], forKey: Self.key)
        }
    }

    /// 지금 화면에 실제로 쓰이는 언어팩
    static var active: AppLanguage {
        let code = Bundle.main.preferredLocalizations.first ?? "ko"
        return packs.first { code == $0.rawValue || code.hasPrefix($0.rawValue + "-") } ?? .korean
    }

    /// 앱을 끝낸 뒤 다시 띄운다 (알림 창은 끝날 때 원위치되고, 새로 뜬 앱이 다시 옮긴다)
    @MainActor
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        // 지금 프로세스가 완전히 끝난 뒤 열도록 잠깐 기다린다. 경로는 인자로 넘겨 따옴표 문제를 피한다
        task.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            Log.error("다시 시작 실패: \(error.localizedDescription)")
        }
    }
}
