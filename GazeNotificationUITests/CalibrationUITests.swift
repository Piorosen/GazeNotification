import XCTest

/// 보정 화면 끝에서 끝까지: 가상 사용자가 화면의 점을 바라보는 동안 특징을 모아 세 방식 × 세 모델을 학습한다
final class CalibrationUITests: GazeUITestCase {
    var calibrationWindow: XCUIElement { app.windows["calibration"] }

    /// 보정 점 3개로 줄여 빨리 끝나게 한다 (안내 2.5초 + 3 × 2.5초 + 결과 1.8초 ≈ 12초).
    /// 점당 1.6초면 안쪽 점을 빼고 학습해도 샘플이 충분해 교차검증 오차까지 나온다.
    private func useShortCalibration() {
        openSettings(with: "menu.openAdjust")
        choose("3개", in: "adjust.points")
        XCTAssertEqual(text("adjust.seconds.value"), "1.6초")
    }

    private func runCalibration(button: String, title: String) {
        app.buttons[button].click()
        XCTAssertTrue(calibrationWindow.waitForExistence(timeout: 5), "보정 화면이 떠야 함")
        waitForText("calibration.title") { $0 == title }
        waitUntil("점을 보라는 안내", timeout: 8) { self.text("calibration.title").hasPrefix("점을 바라보세요") }
        waitUntil("보정 완료", timeout: 30) { self.text("calibration.title") == "\(title) 완료" }
        XCTAssertTrue(text("calibration.subtitle").contains("%"), text("calibration.subtitle"))
        waitUntil("보정 화면이 닫혀야 함", timeout: 8) { !self.calibrationWindow.exists }
    }

    func testFullCalibrationTrainsEveryModeAndModel() {
        useShortCalibration()
        runCalibration(button: "adjust.recalibrate", title: "보정")

        waitForText("adjust.summary") { $0.contains("교차 검증") && $0.contains("샘플") }

        // AI 모드 탭: 세 모델 모두 학습·교차검증 오차가 있고, 하나가 자동 선택됨
        selectTab("AI 모드")
        for kind in ["linear", "curve", "piecewise"] {
            waitForText("ai.estimator.\(kind).training") { $0.hasSuffix("%") }
            XCTAssertTrue(text("ai.estimator.\(kind).cv").hasSuffix("%"), "\(kind) 교차검증 \(text("ai.estimator.\(kind).cv"))")
        }
        XCTAssertTrue(text("ai.estimator.formula.training").hasSuffix("%"), "기본식도 같은 샘플로 비교")
        let statuses = ["linear", "curve", "piecewise"].map { text("ai.estimator.\($0).status") }
        XCTAssertEqual(statuses.filter { $0.contains("자동 선택") }.count, 1, "\(statuses)")
        XCTAssertEqual(statuses.filter { $0.contains("사용 중") }.count, 1, "\(statuses)")

        // 다른 분석 방식으로 바꿔도 다시 보정할 필요 없음
        for mode in ["light", "headPose"] {
            app.buttons["ai.mode.\(mode)"].click()
            waitForText("ai.estimator.linear.training") { $0.hasSuffix("%") }
            XCTAssertFalse(text("ai.estimator.formula.status").contains("사용 중"), "\(mode): 학습 모델을 써야 함")
        }

        openMenu()
        waitForText("status.calibration") { $0.hasPrefix("완료") }
        XCTAssertFalse(text("status.aiMode").contains("기본 추정식"), text("status.aiMode"))
    }

    func testQuickAdjustAfterCalibration() {
        useShortCalibration()
        runCalibration(button: "adjust.recalibrate", title: "보정")
        runCalibration(button: "adjust.quick", title: "빠른 위치 맞춤")
        openMenu()
        waitForText("menu.lastEvent") { $0.contains("빠른 위치 맞춤 완료") && $0.contains("좌우 이동") }
    }

    func testEscapeCancelsCalibration() {
        useShortCalibration()
        app.buttons["adjust.recalibrate"].click()
        XCTAssertTrue(calibrationWindow.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        waitUntil("ESC 로 보정 화면이 닫혀야 함", timeout: 5) { !self.calibrationWindow.exists }
        waitForText("adjust.summary") { $0.hasPrefix("아직 보정하지 않아") }
    }

    func testCalibrationFromMenu() {
        openSettings(with: "menu.openAdjust")
        choose("3개", in: "adjust.points")
        slider("adjust.seconds").adjust(toNormalizedSliderPosition: 0)   // 가장 짧은 쪽(점당 약 0.8초)도 학습돼야 한다
        waitForText("adjust.seconds.value") { (self.number(in: $0) ?? 9) <= 1.0 }
        openMenu()
        app.buttons["menu.calibrate"].click()
        XCTAssertTrue(calibrationWindow.waitForExistence(timeout: 5), "메뉴의 시선 보정 버튼으로도 시작")
        waitUntil("보정 완료", timeout: 30) { self.text("calibration.title") == "시선 보정 완료" }
        waitUntil("보정 화면 닫힘", timeout: 8) { !self.calibrationWindow.exists }
        openMenu()
        waitForText("status.calibration") { $0.hasPrefix("완료") }
    }
}

/// 설정을 바꾸고 앱을 다시 띄우면 그대로인지
final class PersistenceUITests: GazeUITestCase {
    func testSettingsSurviveRelaunch() {
        openSettings()
        selectTab("연산 제한")
        selectSegment("절전", in: "limits.profile")
        selectTab("AI 모드")
        app.buttons["ai.mode.light"].click()
        selectTab("보정 조정")
        slider("adjust.offset").adjust(toNormalizedSliderPosition: 0.25)
        waitForText("adjust.offset.value") { (self.number(in: $0) ?? 0) < -5 }
        let offset = text("adjust.offset.value")

        app.terminate()
        launch(reset: false)

        openSettings()
        selectTab("연산 제한")
        XCTAssertTrue(isSegmentSelected("절전", in: "limits.profile"))
        selectTab("AI 모드")
        XCTAssertTrue(app.buttons["ai.mode.light"].isSelected)
        selectTab("보정 조정")
        waitForText("adjust.offset.value") { $0 == offset }
    }
}
