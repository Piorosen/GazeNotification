import XCTest

/// 설정 창: 성능 그래프 · 연산 제한 · AI 모드 · 보정 조정의 컨트롤이 실제로 동작하는지
final class SettingsUITests: GazeUITestCase {
    // MARK: - 성능 그래프

    func testPerformanceChartsFillWithHistory() {
        openSettings()
        XCTAssertTrue(app.staticTexts["performance.applied"].value as? String != nil)
        let cpu = settings.otherElements["chart.cpu"]
        XCTAssertTrue(cpu.waitForExistence(timeout: 5))
        // 시작 후 10초는 기록하지 않으므로 그 뒤 몇 초 안에 기록이 쌓여야 한다
        waitUntil("CPU 그래프에 기록", timeout: 30) { (cpu.label.components(separatedBy: "개").first.flatMap(Int.init) ?? 0) >= 3 }
        for id in ["chart.cpu.legend.0", "chart.rate.legend.0", "chart.rate.legend.2", "chart.rate.legend.3"] {
            waitForText(id) { $0 != "—" && !$0.isEmpty }
        }
        // 가상 카메라는 5fps, 균형/절전 프로필 처리 횟수는 0보다 크다
        waitForText("chart.rate.legend.0") { (Double($0) ?? 0) > 0 }
        selectSegment("1분", in: "performance.range")
        XCTAssertTrue(isSegmentSelected("1분", in: "performance.range"))
        selectSegment("10분", in: "performance.range")
        XCTAssertTrue(isSegmentSelected("10분", in: "performance.range"))
    }

    func testChartHoverShowsTooltip() {
        openSettings()
        let cpu = settings.otherElements["chart.cpu"]
        waitUntil("CPU 그래프에 기록", timeout: 30) { (cpu.label.components(separatedBy: "개").first.flatMap(Int.init) ?? 0) >= 3 }
        // 마우스를 올리면 그 시각을 고르고(십자선·툴팁), 치우면 해제
        // 포인터를 한 번만 옮기면 hover 가 시작되지 않을 수 있어 그래프 안에서 두 번 옮긴다
        cpu.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).hover()
        cpu.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.5)).hover()
        waitUntil("그래프 위 마우스 → 시각 선택") { (cpu.value as? String)?.hasPrefix("선택 ") == true }
        let rate = settings.otherElements["chart.rate"]
        waitUntil("세 그래프가 같은 시각을 가리킨다") { (rate.value as? String) == (cpu.value as? String) }
        settings.staticTexts["performance.applied"].hover()
        waitUntil("마우스를 치우면 선택 해제") { (cpu.value as? String)?.hasPrefix("선택 ") == false }
    }

    // MARK: - 연산 제한

    func testProfileSelectionAppliesPresetValues() {
        openSettings()
        selectTab("연산 제한")
        selectSegment("절전", in: "limits.profile")
        waitForText("limits.activeHz.value") { $0 == "초당 2.5회" }
        XCTAssertEqual(text("limits.detectionInterval.value"), "6프레임마다")
        XCTAssertEqual(text("limits.cpuLimit.value"), "5%")
        selectSegment("성능 우선", in: "limits.profile")
        waitForText("limits.activeHz.value") { $0 == "초당 10.0회" }
        XCTAssertEqual(text("limits.detectionInterval.value"), "매 프레임")
        XCTAssertEqual(text("limits.cpuLimit.value"), "제한 없음")
        // 성능 그래프 탭과 메뉴도 같은 프로필을 보여 준다
        selectTab("성능")
        waitForText("performance.applied") { $0 == "현재 프로필: 성능 우선" }
        openMenu()
        waitForText("status.policy") { $0.hasPrefix("성능 우선") }
    }

    func testEditingALimitSwitchesToCustomAndCanReset() {
        openSettings()
        selectTab("연산 제한")
        selectSegment("균형", in: "limits.profile")
        waitForText("limits.activeHz.value") { $0 == "초당 5.0회" }
        // 슬라이더는 정확한 위치로 가지 않으므로 값은 범위로 확인한다
        slider("limits.activeHz").adjust(toNormalizedSliderPosition: 1)
        waitForText("limits.activeHz.value") { (self.number(in: $0) ?? 0) >= 13 }
        let activeHz = number("limits.activeHz.value") ?? 0
        XCTAssertTrue(isSegmentSelected("사용자 지정", in: "limits.profile"), "값을 바꾸면 사용자 지정")
        XCTAssertEqual(text("limits.stillHz.value"), "초당 2.5회", "나머지는 균형 값 그대로")

        let stepper = app.steppers["limits.detectionInterval"]
        stepper.incrementArrows.firstMatch.click()
        waitForText("limits.detectionInterval.value") { $0 == "4프레임마다" }
        stepper.decrementArrows.firstMatch.click()
        stepper.decrementArrows.firstMatch.click()
        waitForText("limits.detectionInterval.value") { $0 == "2프레임마다" }
        let expected = String(format: "초당 %.1f회", activeHz * 1.5)   // 처리 × (1 + 1/2)
        waitForText("limits.estimate") { $0.contains(expected) }

        app.buttons["limits.resetTo.balanced"].click()
        waitForText("limits.activeHz.value") { $0 == "초당 5.0회" }
        XCTAssertEqual(text("limits.detectionInterval.value"), "3프레임마다")
    }

    func testCPULimitSliderAndCameraOffSlider() {
        openSettings()
        selectTab("연산 제한")
        slider("limits.cpuLimit").adjust(toNormalizedSliderPosition: 0.2)
        waitForText("limits.cpuLimit.value") { $0.hasSuffix("%") && (self.number(in: $0) ?? 0) > 0 }
        slider("limits.cpuLimit").adjust(toNormalizedSliderPosition: 0)
        waitForText("limits.cpuLimit.value") { $0 == "제한 없음" }
        slider("limits.cameraOff").adjust(toNormalizedSliderPosition: 0)
        waitForText("limits.cameraOff.value") { $0 == "사용 안 함" }
        let boost = app.switches["limits.boost"]
        boost.click()
        waitUntil("알림 중 속도 올리기 끔") { (boost.value as? Int) == 0 || (boost.value as? String) == "0" }
    }

    // MARK: - AI 모드

    func testAnalysisModeDeviceAndEstimatorSelection() {
        openSettings()
        selectTab("AI 모드")
        let headPose = app.buttons["ai.mode.headPose"]
        headPose.click()
        waitUntil("머리 방향만 선택") { headPose.isSelected }
        XCTAssertFalse(app.buttons["ai.mode.precise"].isSelected)

        choose("CPU", in: "ai.device")
        waitForText("ai.devices") { $0.contains("얼굴 검출 CPU") }
        choose("Neural Engine", in: "ai.device")
        waitForText("ai.devices") { !$0.contains("얼굴 검출 CPU") }

        // 보정 전이라 학습 모델은 없고, 기본 추정식을 쓴다
        XCTAssertEqual(text("ai.estimator.formula.status"), "사용 중")
        XCTAssertTrue(text("ai.estimator.linear.status").contains("보정 필요"))
        choose("곡선 회귀 (3차)", in: "ai.estimator")
        XCTAssertEqual(text("ai.estimator.formula.status"), "사용 중", "학습 안 된 모델을 고르면 기본 추정식으로")

        openMenu()
        waitForText("status.aiMode") { $0.hasPrefix("머리 방향") }
    }

    // MARK: - 보정 조정

    func testPositionSlidersAndResets() {
        openSettings(with: "menu.openAdjust")
        XCTAssertTrue(isSelectedTab("보정 조정"))
        waitForText("adjust.final") { $0.hasSuffix("%") }   // 가상 사용자 위치가 미리보기에 나온다

        slider("adjust.offset").adjust(toNormalizedSliderPosition: 0.8)
        waitForText("adjust.offset.value") { (self.number(in: $0) ?? 0) > 5 && $0.contains("오른쪽") }
        let resetPosition = app.buttons["adjust.resetPosition"]
        XCTAssertTrue(resetPosition.isEnabled)
        slider("adjust.leftGain").adjust(toNormalizedSliderPosition: 1)
        waitForText("adjust.leftGain.value") { (self.number(in: $0) ?? 0) >= 2 }
        resetPosition.click()
        waitForText("adjust.offset.value") { $0 == "+0.0%" }
        XCTAssertEqual(text("adjust.leftGain.value"), "×1.00")
        XCTAssertFalse(resetPosition.isEnabled)

        slider("adjust.feature.1").adjust(toNormalizedSliderPosition: 0)
        waitForText("adjust.feature.1.value") { (self.number(in: $0) ?? 100) <= 10 }
        choose("3구역", in: "adjust.zones")
        slider("adjust.smoothing").adjust(toNormalizedSliderPosition: 0)
        waitForText("adjust.smoothing.value") { $0.contains("부드럽게") }   // 0.6Hz 미만

        let resetAll = app.buttons["adjust.resetAll"]
        resetAll.click()
        waitForText("adjust.feature.1.value") { $0.hasPrefix("100%") }
        XCTAssertEqual(app.popUpButtons["adjust.zones"].value as? String, "사용 안 함")
        XCTAssertEqual(text("adjust.smoothing.value"), "0.80Hz (보통)")
    }

    func testCalibrationOptions() {
        openSettings(with: "menu.openAdjust")
        choose("3개", in: "adjust.points")
        slider("adjust.seconds").adjust(toNormalizedSliderPosition: 0)
        waitForText("adjust.seconds.value") { (self.number(in: $0) ?? 9) <= 1.0 }
        XCTAssertEqual(text("adjust.summary").hasPrefix("보정하지 않아"), true)
    }
}
