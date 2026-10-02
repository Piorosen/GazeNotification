import Foundation
import Testing
@testable import GazeNotification

/// 손으로 맞추는 보정값과 구역 나누기
@Suite("수동 보정·구역 나누기")
struct GazeAdjustmentTests {
    @Test("기본값은 아무것도 바꾸지 않는다")
    func identity() {
        let adjustment = GazeAdjustment()
        #expect(adjustment.isPositionDefault)
        for x in stride(from: -0.1, through: 1.1, by: 0.1) { #expect(abs(adjustment.mapPosition(x) - x) < 1e-12) }
        #expect(adjustment.featureGains == [1, 1, 1, 1])
        #expect(adjustment.sanitized == adjustment)
    }

    @Test("좌우 이동은 전체를 평행 이동")
    func offsetShifts() {
        var adjustment = GazeAdjustment()
        adjustment.offset = 0.1
        #expect(abs(adjustment.mapPosition(0.3) - 0.4) < 1e-12)
        #expect(abs(adjustment.mapPosition(0.7) - 0.8) < 1e-12)
        #expect(!adjustment.isPositionDefault)
    }

    @Test("왼쪽·오른쪽 범위는 가운데를 기준으로 그쪽만 늘인다")
    func sideGains() {
        var adjustment = GazeAdjustment()
        adjustment.leftGain = 2
        adjustment.rightGain = 0.5
        #expect(abs(adjustment.mapPosition(0.4) - 0.3) < 1e-12)   // 왼쪽: 0.1 → 0.2 만큼
        #expect(abs(adjustment.mapPosition(0.6) - 0.55) < 1e-12)  // 오른쪽: 0.1 → 0.05 만큼
        #expect(adjustment.mapPosition(0.5) == 0.5)                // 가운데는 그대로 (끊김 없음)
    }

    @Test("빠른 위치 맞춤: 세 점의 모델 출력에서 이동·범위를 정확히 되찾는다")
    func quickFitRecoversParameters() throws {
        var truth = GazeAdjustment()
        truth.offset = 0.06
        truth.leftGain = 1.3
        truth.rightGain = 0.8
        // map(raw) = target 이 되는 raw 를 거꾸로 구한다
        func raw(for target: Double) -> Double {
            let gain = target < 0.5 ? truth.leftGain : truth.rightGain
            return 0.5 + (target - 0.5) / gain - truth.offset
        }
        let fit = try GazeAdjustment.fit(left: (0.04, raw(for: 0.04)), center: (0.5, raw(for: 0.5)),
                                         right: (0.96, raw(for: 0.96))).get()
        #expect(abs(fit.offset - truth.offset) < 1e-9)
        #expect(abs(fit.leftGain - truth.leftGain) < 1e-9)
        #expect(abs(fit.rightGain - truth.rightGain) < 1e-9)
    }

    @Test("빠른 위치 맞춤 실패: 좌우 차이가 너무 작음 / 많이 벗어남")
    func quickFitFailures() {
        let flat = GazeAdjustment.fit(left: (0.04, 0.49), center: (0.5, 0.5), right: (0.96, 0.51))
        #expect(throws: GazeAdjustment.FitError.noSpread) { try flat.get() }
        let shifted = GazeAdjustment.fit(left: (0.04, -0.5), center: (0.5, 0.0), right: (0.96, 0.5))
        #expect(throws: GazeAdjustment.FitError.outOfRange) { try shifted.get() }
        #expect(!GazeAdjustment.FitError.noSpread.message.isEmpty)
    }

    @Test("빠른 위치 맞춤의 범위 배율은 허용 범위로 제한")
    func quickFitClampsGains() throws {
        let fit = try GazeAdjustment.fit(left: (0.04, 0.4), center: (0.5, 0.5), right: (0.96, 0.9)).get()
        #expect(fit.leftGain == GazeAdjustment.gainRange.upperBound)
        #expect(GazeAdjustment.gainRange.contains(fit.rightGain))
    }

    @Test("저장값 바로잡기: 범위 밖 값과 특징 수가 다른 배열")
    func sanitized() {
        var broken = GazeAdjustment()
        broken.offset = 5
        broken.leftGain = -1
        broken.rightGain = 99
        broken.featureGains = [3, -1]
        broken.smoothing = 0
        broken.responsiveness = 100
        broken.zones = 7
        broken.followThreshold = 1
        let fixed = broken.sanitized
        #expect(fixed.offset == GazeAdjustment.offsetRange.upperBound)
        #expect(fixed.leftGain == GazeAdjustment.gainRange.lowerBound)
        #expect(fixed.rightGain == GazeAdjustment.gainRange.upperBound)
        #expect(fixed.featureGains == [2, 0, 1, 1])
        #expect(fixed.smoothing == GazeAdjustment.smoothingRange.lowerBound)
        #expect(fixed.responsiveness == GazeAdjustment.responsivenessRange.upperBound)
        #expect(fixed.zones == 0)
        #expect(fixed.followThreshold == GazeAdjustment.followRange.upperBound)
    }

    @Test("위치 초기화는 이동·범위만 되돌린다")
    func resettingPosition() {
        var adjustment = GazeAdjustment()
        adjustment.offset = 0.1
        adjustment.leftGain = 1.5
        adjustment.featureGains = [0.5, 1, 1, 1]
        adjustment.zones = 3
        let reset = adjustment.resettingPosition()
        #expect(reset.isPositionDefault)
        #expect(reset.featureGains == [0.5, 1, 1, 1])
        #expect(reset.zones == 3)
    }

    // MARK: - 구역 나누기

    @Test("구역 가운데로 맞춤")
    func zoneCenters() {
        var snapper = ZoneSnapper()
        #expect(abs(snapper.snap(0.1, zones: 3) - 1.0 / 6) < 1e-12)
        snapper.reset()
        #expect(abs(snapper.snap(0.99, zones: 4) - 0.875) < 1e-12)
        snapper.reset()
        #expect(abs(snapper.snap(1.0, zones: 4) - 0.875) < 1e-12)   // 오른쪽 끝도 마지막 구역
        snapper.reset()
        #expect(abs(snapper.snap(0.0, zones: 4) - 0.125) < 1e-12)
    }

    @Test("경계 근처에서는 구역 폭의 20% 를 더 넘어야 옮긴다")
    func zoneHysteresis() {
        var snapper = ZoneSnapper()
        let width = 1.0 / 3
        #expect(abs(snapper.snap(0.30, zones: 3) - width / 2) < 1e-12)     // 구역 0
        #expect(abs(snapper.snap(0.39, zones: 3) - width / 2) < 1e-12)     // 경계(0.333) + 여유 안 → 그대로
        #expect(abs(snapper.snap(0.41, zones: 3) - 0.5) < 1e-12)           // 여유(0.4) 넘음 → 구역 1
        #expect(abs(snapper.snap(0.28, zones: 3) - 0.5) < 1e-12)           // 아래 여유(0.267) 안 → 그대로
        #expect(abs(snapper.snap(0.25, zones: 3) - width / 2) < 1e-12)     // 넘음 → 구역 0
    }

    @Test("구역 수가 1 이하면 그대로, 구역 수가 바뀌면 처음부터")
    func zonePassthroughAndChange() {
        var snapper = ZoneSnapper()
        #expect(snapper.snap(0.37, zones: 0) == 0.37)
        #expect(snapper.snap(0.37, zones: 1) == 0.37)
        _ = snapper.snap(0.39, zones: 3)                                   // 구역 1 (0.333~0.667)
        #expect(abs(snapper.snap(0.39, zones: 2) - 0.25) < 1e-12)          // 2구역으로 바뀌면 이력 없이 구역 0
    }
}
