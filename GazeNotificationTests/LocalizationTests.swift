import Foundation
import Testing
@testable import GazeNotification

/// 언어팩 무결성: 빌드된 앱에 언어팩이 다 들어 있고, 언어마다 같은 문구가 있으며, 숫자 자리표시자가 원문과 맞는지
@Suite("언어팩")
struct LocalizationTests {
    /// 번역이 들어 있는 언어 (한국어는 개발 언어라 키가 곧 한국어 문구)
    static let translated = ["en", "ja", "zh-Hans"]

    private static func table(_ name: String, _ language: String) -> [String: String]? {
        guard let path = Bundle.main.path(forResource: name, ofType: "strings", inDirectory: nil, forLocalization: language) else { return nil }
        return NSDictionary(contentsOfFile: path) as? [String: String]
    }

    private static func bundle(_ language: String) -> Bundle? {
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:))
    }

    /// 문구 안의 숫자 자리표시자 (위치, 종류) — "%%" 는 글자 그대로라 뺀다
    static func placeholders(_ text: String) -> [String] {
        let cleaned = text.replacingOccurrences(of: "%%", with: "")
        let regex = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?(lld|ld|d|@|lf|f)"#)
        var order = 0
        return regex.matches(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)).map { match in
            order += 1
            let position = Range(match.range(at: 1), in: cleaned).map { String(cleaned[$0]) } ?? String(order)
            return position + ":" + String(cleaned[Range(match.range(at: 2), in: cleaned)!])
        }.sorted()
    }

    @Test("앱에 언어팩(영어·일본어·중국어 간체)이 들어 있다", arguments: translated)
    func packsArePresent(language: String) throws {
        #expect(Bundle.main.localizations.contains(language))
        let strings = try #require(Self.table("Localizable", language), "\(language) Localizable.strings")
        #expect(strings.count > 300)
        let infoPlist = try #require(Self.table("InfoPlist", language), "\(language) InfoPlist.strings")
        #expect(!(infoPlist["NSCameraUsageDescription"] ?? "").isEmpty, "카메라 권한 안내")
    }

    @Test("언어마다 같은 문구가 번역돼 있다")
    func sameKeysEverywhere() throws {
        let reference = try #require(Self.table("Localizable", "en"))
        for language in Self.translated.dropFirst() {
            let other = try #require(Self.table("Localizable", language))
            #expect(Set(other.keys) == Set(reference.keys), "\(language): 빠짐 \(Set(reference.keys).subtracting(other.keys)), 더 있음 \(Set(other.keys).subtracting(reference.keys))")
        }
    }

    @Test("숫자 자리표시자와 % 기호가 원문과 같다", arguments: translated)
    func placeholdersMatch(language: String) throws {
        let strings = try #require(Self.table("Localizable", language))
        for (key, value) in strings {
            #expect(Self.placeholders(value) == Self.placeholders(key), "\(language) \"\(key)\" → \"\(value)\"")
            #expect(value.components(separatedBy: "%%").count == key.components(separatedBy: "%%").count, "\(language) %% \"\(key)\"")
        }
    }

    @Test("번역에 한글이 남아 있지 않다 (옮기지 않고 복사한 문구 찾기)", arguments: translated)
    func noHangulLeft(language: String) throws {
        let strings = try #require(Self.table("Localizable", language))
        let hangul = strings.filter { $0.value.range(of: "[가-힣]", options: .regularExpression) != nil }
        #expect(hangul.isEmpty, "\(language): \(hangul.keys.sorted().prefix(5))")
    }

    @Test("소스 카탈로그의 모든 문구가 세 언어로 번역됨")
    func sourceCatalogComplete() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for name in ["Localizable", "InfoPlist"] {
            let url = root.appendingPathComponent("GazeNotification/\(name).xcstrings")
            let catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            #expect(catalog["sourceLanguage"] as? String == "ko")
            let strings = try #require(catalog["strings"] as? [String: [String: Any]])
            for (key, entry) in strings where !key.isEmpty && key != "NSHumanReadableCopyright" {
                let localizations = entry["localizations"] as? [String: [String: Any]] ?? [:]
                for language in Self.translated {
                    let unit = localizations[language]?["stringUnit"] as? [String: String]
                    #expect(unit?["state"] == "translated" && !(unit?["value"] ?? "").isEmpty, "\(name) \(language) \"\(key)\"")
                }
            }
        }
    }

    @Test("언어팩에서 실제 번역을 꺼내고, 숫자를 끼워 넣을 수 있다")
    func lookupAndFormat() throws {
        let en = try #require(Self.bundle("en")), ja = try #require(Self.bundle("ja")), zh = try #require(Self.bundle("zh-Hans"))
        #expect(en.localizedString(forKey: "카메라", value: nil, table: nil) == "Camera")
        #expect(ja.localizedString(forKey: "카메라", value: nil, table: nil) == "カメラ")
        #expect(zh.localizedString(forKey: "카메라", value: nil, table: nil) == "摄像头")
        let rate = en.localizedString(forKey: "초당 %@회 (%@초마다 1회)", value: nil, table: nil)
        #expect(String(format: rate, "0.5", "2.0") == "0.5/s (once every 2.0 s)")
        let order = en.localizedString(forKey: "실행 %@ 동안 평균 초당 %@회 (%@)", value: nil, table: nil)
        #expect(String(format: order, "3 min", "4.2", "Active 80%") == "Average 4.2/s over 3 min of running (Active 80%)", "영어는 어순을 바꾼다")
        let percent = ja.localizedString(forKey: "배터리 %lld%%", value: nil, table: nil)
        #expect(String(format: percent, 42) == "バッテリー 42%")
    }

    @Test("자리표시자 비교 도우미")
    func placeholderHelper() {
        #expect(Self.placeholders("%@ (자동, %@)") == Self.placeholders("%1$@ (Automatic, %2$@)"))
        #expect(Self.placeholders("실행 %@ 동안 평균 초당 %@회 (%@)") == Self.placeholders("Average %2$@/s over %1$@ (%3$@)"))
        #expect(Self.placeholders("배터리 %lld%%") == ["1:lld"])
        #expect(Self.placeholders("%@초") != Self.placeholders("%lld s"))
    }

    // MARK: - 언어 선택

    @Test("언어 선택 저장·읽기 (앱 전용 AppleLanguages)")
    func languageStore() {
        let name = "party.udon.GazeNotification.unittest.language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(AppLanguage.stored(in: defaults, domain: name) == .system)
        for language in AppLanguage.packs {
            language.store(in: defaults)
            #expect(AppLanguage.stored(in: defaults, domain: name) == language)
            #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] as? [String] == [language.rawValue])
        }
        AppLanguage.system.store(in: defaults)
        #expect(defaults.persistentDomain(forName: name)?["AppleLanguages"] == nil)
        #expect(AppLanguage.stored(in: defaults, domain: name) == .system)
        // 지역이 붙은 값(en-US)도 그 언어로, 언어팩이 없는 언어는 시스템으로
        defaults.set(["en-US"], forKey: "AppleLanguages")
        #expect(AppLanguage.stored(in: defaults, domain: name) == .english)
        defaults.set(["fr"], forKey: "AppleLanguages")
        #expect(AppLanguage.stored(in: defaults, domain: name) == .system)
    }

    @Test("언어 이름은 그 언어로, 언어팩 목록에 시스템은 없다")
    func languageNames() {
        #expect(AppLanguage.packs == [.korean, .english, .japanese, .simplifiedChinese])
        #expect(AppLanguage.english.title == "English")
        #expect(AppLanguage.japanese.title == "日本語")
        #expect(AppLanguage.simplifiedChinese.title == "简体中文")
        #expect(AppLanguage.korean.title == "한국어")
        #expect(AppLanguage.packs.allSatisfy { Bundle.main.localizations.contains($0.rawValue) || $0 == .korean })
        #expect(AppLanguage.packs.contains(AppLanguage.active))
    }

    @Test("앱 상태: 언어를 바꾸면 저장되고 다시 시작이 필요하다고 알린다")
    @MainActor
    func modelLanguage() {
        let name = "party.udon.GazeNotification.unittest.language.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(defaults: defaults, domain: name, simulation: nil)
        #expect(model.language == .system && !model.languageNeedsRestart)
        model.language = .japanese
        #expect(model.languageNeedsRestart)
        #expect(AppModel(defaults: defaults, domain: name, simulation: nil).language == .japanese)
        model.language = .system
        #expect(!model.languageNeedsRestart)
    }
}
