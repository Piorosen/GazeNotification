import XCTest

/// 언어팩: 언어 선택 → 다시 시작 안내, 각 언어로 띄웠을 때 화면 문구가 그 언어인지
final class LocalizationUITests: GazeUITestCase {
    func testLanguagePickerAsksForRestart() {
        openMenu()
        XCTAssertFalse(app.buttons["menu.relaunch"].exists, "처음에는 다시 시작할 필요 없음")
        choose("English", in: "menu.language")
        XCTAssertTrue(app.buttons["menu.relaunch"].waitForExistence(timeout: 5), "언어를 바꾸면 다시 시작 버튼")
        XCTAssertTrue(staticText(value: "다시 시작하면 바뀝니다").exists, "다시 시작 전에는 화면이 그대로")
        choose("시스템 설정 따름", in: "menu.language")
        waitUntil("원래대로 되돌리면 다시 시작 버튼이 사라짐") { !self.app.buttons["menu.relaunch"].exists }
    }

    /// (언어, 가상 카메라 이름, 시선 보정 버튼, 설정 창 탭 이름 4개)
    private static let packs: [(String, String, String, [String])] = [
        ("en", "Virtual camera (UI testing)", "Calibrate Gaze", ["Performance", "Compute Limits", "AI Mode", "Calibration Tuning"]),
        ("ja", "仮想カメラ（UIテスト）", "視線キャリブレーション", ["パフォーマンス", "処理制限", "AIモード", "キャリブレーション調整"]),
        ("zh-Hans", "虚拟摄像头（UI 测试）", "视线校准", ["性能图表", "运算限制", "AI 模式", "校准调整"]),
    ]

    private func checkPack(_ language: String) {
        guard let (_, camera, calibrate, tabs) = Self.packs.first(where: { $0.0 == language }) else { return XCTFail(language) }
        app.terminate()
        launch(reset: true, language: language)
        openMenu()
        waitForText("status.camera") { $0 == camera }
        XCTAssertEqual(app.buttons["menu.calibrate"].label, calibrate)
        XCTAssertNil(text("status.policy").range(of: "[가-힣]", options: .regularExpression), "메뉴에 한글이 남아 있으면 안 됨: \(text("status.policy"))")
        app.buttons["menu.openPerformance"].click()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        for tab in tabs {
            XCTAssertTrue(settings.toolbars.radioButtons[tab].exists, "\(language) 탭 \(tab)")
        }
        // 각 탭의 글자에 한글이 섞여 있지 않은지 (번역 누락)
        for tab in tabs {
            selectTab(tab)
            let hangul = settings.staticTexts.allElementsBoundByIndex
                .compactMap { $0.value as? String }
                .filter { $0.range(of: "[가-힣]", options: .regularExpression) != nil }
            XCTAssertTrue(hangul.isEmpty, "\(language) \(tab) 탭에 번역 안 된 글자: \(hangul.prefix(3))")
        }
    }

    func testEnglishPack() { checkPack("en") }
    func testJapanesePack() { checkPack("ja") }
    func testSimplifiedChinesePack() { checkPack("zh-Hans") }
}
