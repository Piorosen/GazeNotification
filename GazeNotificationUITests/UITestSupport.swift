import XCTest

/// UI 테스트 공통: 앱을 UI 테스트 모드(-uiTesting)로 띄운다.
/// 이 모드의 앱은 카메라 대신 가상 사용자(보정 중엔 화면의 점을 보고, 그 밖엔 좌우로 오감)를 쓰고,
/// 알림 창을 옮기거나 권한을 묻지 않으며, 설정은 별도 저장소(-uiTestingReset 이면 비운 채)에 둔다.
class GazeUITestCase: XCTestCase {
    var app: XCUIApplication!

    /// 매 테스트를 빈 설정으로 시작할지 (설정 유지 테스트만 false)
    var resetsSettings: Bool { true }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        launch(reset: resetsSettings)
    }

    override func tearDownWithError() throws {
        app?.terminate()
    }

    func launch(reset: Bool) {
        app.launchArguments = ["-uiTesting"] + (reset ? ["-uiTestingReset"] : [])
        app.launch()
        XCTAssertTrue(app.statusItems.firstMatch.waitForExistence(timeout: 15), "메뉴 막대 아이콘이 생겨야 함")
    }

    // MARK: - 메뉴

    /// 메뉴 막대 아이콘을 눌러 패널을 연다 (이미 열려 있으면 그대로).
    /// 다른 창(보정 화면 등)이 막 닫힌 직후에는 첫 클릭이 무시될 수 있어 몇 번 다시 누른다.
    func openMenu() {
        let marker = app.buttons["menu.calibrate"]
        for _ in 0..<3 where !marker.exists {
            app.statusItems.firstMatch.click()
            if marker.waitForExistence(timeout: 3) { break }
        }
        XCTAssertTrue(marker.exists, "메뉴 패널이 열려야 함")
    }

    func closeMenu() {
        guard app.buttons["menu.calibrate"].exists else { return }
        app.statusItems.firstMatch.click()
        waitUntil("메뉴 패널이 닫혀야 함") { !self.app.buttons["menu.calibrate"].exists }
    }

    // MARK: - 설정 창

    var settings: XCUIElement { app.windows["settings"] }

    /// 메뉴 버튼으로 설정 창을 연다
    @discardableResult
    func openSettings(with buttonID: String = "menu.openPerformance") -> XCUIElement {
        openMenu()
        app.buttons[buttonID].click()
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "설정 창이 떠야 함")
        return settings
    }

    func selectTab(_ title: String) {
        let tab = settings.toolbars.radioButtons[title]
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "탭 \(title)")
        tab.click()
        waitUntil("탭 \(title) 선택") { (tab.value as? Int) == 1 || (tab.value as? String) == "1" }
    }

    func isSelectedTab(_ title: String) -> Bool {
        let tab = settings.toolbars.radioButtons[title]
        return tab.exists && ((tab.value as? Int) == 1 || (tab.value as? String) == "1")
    }

    // MARK: - 값 읽기·조작

    /// 글자 요소의 내용 (없으면 "")
    func text(_ id: String) -> String {
        let element = app.staticTexts[id]
        guard element.exists else { return "" }
        return (element.value as? String) ?? element.label
    }

    /// 내용이 정확히 이 글자인 글자 요소
    func staticText(value: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value == %@", value)).firstMatch
    }

    /// 조건이 맞을 때까지 기다린다 (값이 1초마다 갱신되는 화면용)
    func waitUntil(_ message: @autoclosure () -> String, timeout: TimeInterval = 10, _ condition: () -> Bool,
                   file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("시간 초과(\(Int(timeout))초): \(message())", file: file, line: line)
    }

    /// 글자 요소가 조건을 만족할 때까지 기다린다
    func waitForText(_ id: String, timeout: TimeInterval = 10, _ condition: (String) -> Bool,
                     file: StaticString = #filePath, line: UInt = #line) {
        waitUntil("\(id) 값: \"\(text(id))\"", timeout: timeout, { condition(text(id)) }, file: file, line: line)
    }

    /// 세그먼트(라디오 그룹)에서 고른다
    func selectSegment(_ label: String, in groupID: String) {
        let button = app.radioGroups[groupID].radioButtons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 5), "\(groupID) → \(label)")
        button.click()
    }

    func isSegmentSelected(_ label: String, in groupID: String) -> Bool {
        let button = app.radioGroups[groupID].radioButtons[label]
        return button.exists && ((button.value as? Int) == 1 || (button.value as? String) == "1")
    }

    /// 선택 메뉴(PopUpButton)에서 항목을 고른다
    func choose(_ item: String, in popUpID: String) {
        let popUp = app.popUpButtons[popUpID]
        XCTAssertTrue(popUp.waitForExistence(timeout: 5), popUpID)
        popUp.click()
        let menuItem = app.menuItems[item]
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "\(popUpID) 항목 \(item)")
        menuItem.click()
        waitUntil("\(popUpID) = \(item)") { (popUp.value as? String)?.hasPrefix(String(item.prefix(6))) == true }
    }

    /// 슬라이더 (화면 밖이면 보이도록 스크롤)
    func slider(_ id: String) -> XCUIElement {
        let slider = app.sliders[id]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), id)
        reveal(slider)
        return slider
    }

    /// 스크롤해야 보이는 요소를 보이게 한다 (설정 창은 UI 테스트에서 화면 높이만큼이라 보통 필요 없음)
    func reveal(_ element: XCUIElement) {
        let scroll = settings.scrollViews.firstMatch
        guard scroll.exists else { return }
        for _ in 0..<20 where !element.isHittable {
            let below = element.frame.minY > scroll.frame.maxY
            scroll.scroll(byDeltaX: 0, deltaY: below ? -120 : 120)
        }
    }

    /// 글자에서 첫 숫자 (부호·소수점 포함). 슬라이더는 정확한 위치로 가지 않으므로 값은 범위로 확인한다.
    func number(in text: String) -> Double? {
        guard let range = text.range(of: #"[+-]?\d+(\.\d+)?"#, options: .regularExpression) else { return nil }
        return Double(text[range])
    }

    func number(_ id: String) -> Double? { number(in: text(id)) }

    /// 메뉴 막대 아이콘 이름 (SF Symbol 의 접근성 이름)
    var statusItemTitle: String {
        let item = app.statusItems.firstMatch
        return item.title.isEmpty ? item.label : item.title
    }
}
