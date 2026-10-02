import XCTest

/// 메뉴 막대 패널: 상태 표시, 켜기/끄기, 위치 기준, 카메라 미리보기(실시간 속도), 설정 창 열기
final class MenuUITests: GazeUITestCase {
    func testStatusRowsShowSimulatedPipeline() {
        openMenu()
        waitForText("status.camera") { $0.contains("가상 카메라") }
        waitForText("status.face") { $0.hasPrefix("감지됨") }
        XCTAssertTrue(text("status.calibration").hasPrefix("안 함"), text("status.calibration"))
        XCTAssertTrue(text("status.aiMode").hasPrefix("76점"), text("status.aiMode"))
        XCTAssertTrue(text("status.aiMode").contains("기본 추정식"), "보정 전에는 기본 추정식")
        let policy = text("status.policy")
        XCTAssertTrue(policy.contains("균형") || policy.contains("절전"), "자동 프로필: \(policy)")
        XCTAssertTrue(policy.contains("자동"), policy)
    }

    func testDisablingStopsCameraAndEnablingRestarts() {
        openMenu()
        waitForText("status.camera") { $0.contains("가상 카메라") }
        let toggle = app.checkBoxes["menu.enabled"]
        let iconBefore = statusItemTitle
        XCTAssertFalse(iconBefore.isEmpty)
        toggle.click()
        waitForText("status.camera") { $0 == "꺼짐" }
        waitUntil("꺼지면 메뉴 막대 아이콘이 바뀐다 (\(iconBefore))") { self.statusItemTitle != iconBefore }
        toggle.click()
        waitForText("status.camera") { $0.contains("가상 카메라") }
    }

    func testMousePlacementTurnsCameraOff() {
        openMenu()
        waitForText("status.camera") { $0.contains("가상 카메라") }
        selectSegment("마우스", in: "menu.placementSource")
        waitForText("status.camera") { $0 == "꺼짐" }
        XCTAssertFalse(app.staticTexts["status.face"].exists, "마우스 기준이면 얼굴 상태를 숨긴다")
        XCTAssertFalse(app.staticTexts["status.aiMode"].exists)
        selectSegment("시선", in: "menu.placementSource")
        waitForText("status.camera") { $0.contains("가상 카메라") }
        XCTAssertTrue(app.staticTexts["status.face"].waitForExistence(timeout: 5))
    }

    func testCameraPreviewSwitchesToLiveRate() {
        openMenu()
        let rateTitle = staticText(value: "움직임")
        let liveTitle = staticText(value: "실시간")
        waitUntil("평소 단계(움직임)") { rateTitle.exists || self.staticText(value: "머묾").exists }
        let preview = app.buttons["menu.preview"]
        XCTAssertTrue(preview.exists)
        preview.click()
        waitUntil("미리보기를 펼치면 실시간 단계") { liveTitle.exists }
        preview.click()
        waitUntil("접으면 다시 평소 단계") { !liveTitle.exists }
    }

    func testTestNotificationDoesNotSendInTestMode() {
        openMenu()
        app.buttons["menu.testNotification"].click()
        openMenu()
        waitForText("menu.lastEvent") { $0.contains("테스트 모드") }
    }

    func testMenuButtonsOpenSettingsOnTheRightTab() {
        openSettings(with: "menu.openPerformance")
        XCTAssertTrue(isSelectedTab("성능 그래프"))
        settings.buttons["_XCUI:CloseWindow"].click()
        waitUntil("설정 창이 닫혀야 함") { !self.settings.exists }

        openSettings(with: "menu.openAdjust")
        XCTAssertTrue(isSelectedTab("보정 조정"))
    }
}
