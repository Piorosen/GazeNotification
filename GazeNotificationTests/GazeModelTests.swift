import Foundation
import Testing
@testable import GazeNotification

/// 회귀·기본식·필터·선형 방정식 — 시선 계산의 수학이 맞는지
@Suite("시선 모델 수식")
struct GazeModelTests {
    /// 결정적인 의사 난수 (테스트가 매번 같은 데이터로 돌도록)
    struct SeededRandom {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func uniform(_ range: ClosedRange<Double>) -> Double {
            range.lowerBound + (range.upperBound - range.lowerBound) * next()
        }
    }

    // MARK: - 선형 방정식

    @Test("가우스 소거: 알려진 해를 찾는다")
    func solvesKnownSystem() throws {
        // 2x + y − z = 8, −3x − y + 2z = −11, −2x + y + 2z = −3 → (2, 3, −1)
        let solution = try #require(solveLinearSystem([[2, 1, -1], [-3, -1, 2], [-2, 1, 2]], [8, -11, -3]))
        #expect(abs(solution[0] - 2) < 1e-9)
        #expect(abs(solution[1] - 3) < 1e-9)
        #expect(abs(solution[2] + 1) < 1e-9)
    }

    @Test("특이 행렬이면 nil")
    func singularSystemIsNil() {
        #expect(solveLinearSystem([[1, 2], [2, 4]], [1, 2]) == nil)
    }

    // MARK: - ridge 회귀

    private func linearRows(count: Int, noise: Double = 0, seed: UInt64 = 1) -> [RegressionRow] {
        var random = SeededRandom(state: seed)
        return (0..<count).map { _ in
            let a = random.uniform(-0.3...0.3), b = random.uniform(-0.2...0.2), c = random.uniform(0.4...0.6), d = random.uniform(-0.5...0.5)
            let y = 0.5 - 1.1 * a - 0.6 * b - 0.4 * (c - 0.5) - 0.2 * d + random.uniform(-noise...noise)
            return RegressionRow(features: [a, b, c, d], target: y)
        }
    }

    @Test("잡음 없는 선형 데이터는 규제 0 에서 정확히 복원")
    func linearFitRecoversExactly() throws {
        let rows = linearRows(count: 80)
        let model = try #require(GazeCalibration.fit(rows, ridge: 0))
        for row in rows.prefix(10) {
            #expect(abs(model.predict(row.features) - row.target) < 1e-9)
        }
        #expect(model.rmse < 1e-9)
        #expect(model.used == [true, true, true, true])
    }

    @Test("규제가 클수록 기울기가 0 쪽으로 줄어든다")
    func ridgeShrinksWeights() throws {
        let rows = linearRows(count: 80, noise: 0.01)
        let loose = try #require(GazeCalibration.fit(rows, ridge: 0.001))
        let tight = try #require(GazeCalibration.fit(rows, ridge: 1))
        let looseNorm = loose.weights.reduce(0) { $0 + $1 * $1 }
        let tightNorm = tight.weights.reduce(0) { $0 + $1 * $1 }
        #expect(tightNorm < looseNorm)
        #expect(tight.rmse > loose.rmse)
    }

    @Test("샘플이 30개 미만이면 학습하지 않는다")
    func tooFewSamples() {
        #expect(GazeCalibration.fit(linearRows(count: 29)) == nil)
        #expect(GazeCalibration.fit(linearRows(count: 30)) != nil)
        #expect(GazeCalibration.fit([]) == nil)
    }

    @Test("값이 80% 미만인 특징과 변하지 않는 특징은 쓰지 않는다")
    func dropsSparseAndConstantFeatures() throws {
        var rows = linearRows(count: 60)
        for i in rows.indices {
            if i % 3 != 0 { rows[i].features[1] = .nan } // 동공: 33% 만 있음
            rows[i].features[2] = 0.5                     // 얼굴 위치: 상수
        }
        let model = try #require(GazeCalibration.fit(rows))
        #expect(model.used == [true, false, false, true])
        // 쓰지 않는 특징은 값이 무엇이든 예측에 영향이 없다
        let base = model.predict([0.1, 0.0, 0.5, 0.2])
        #expect(model.predict([0.1, 9.0, 0.9, 0.2]) == base)
    }

    @Test("예측할 때 빠진 값(NaN)은 보정 때 평균으로 채운다")
    func missingValueUsesMean() throws {
        let model = try #require(GazeCalibration.fit(linearRows(count: 80, noise: 0.005)))
        let withMean = model.predict([0.1, model.means[1], 0.5, 0.0])
        #expect(abs(model.predict([0.1, .nan, 0.5, 0.0]) - withMean) < 1e-12)
    }

    @Test("특징 배율 0 이면 그 특징의 기여가 사라진다")
    func featureGainZeroRemovesContribution() throws {
        let model = try #require(GazeCalibration.fit(linearRows(count: 80, noise: 0.005)))
        let features = [0.2, 0.1, 0.55, -0.3]
        var atMean = features
        atMean[0] = model.means[0]
        #expect(abs(model.predict(features, gains: [0, 1, 1, 1]) - model.predict(atMean)) < 1e-12)
        #expect(model.predict(features, gains: [1, 1, 1, 1]) == model.predict(features))
    }

    @Test("곡선 회귀(세제곱 항)는 tan 처럼 휘는 관계를 선형보다 잘 맞춘다")
    func curveFitsBentRelation() throws {
        var random = SeededRandom(state: 7)
        let rows = (0..<120).map { _ -> RegressionRow in
            let x = random.uniform(0.02...0.98)
            let yaw = -atan((x - 0.5) * 2.4) * 0.8
            return RegressionRow(features: [yaw / 2, .nan, 0.55, yaw], target: x)
        }
        let linear = try #require(GazeCalibration.fit(rows))
        let curve = try #require(GazeCalibration.fit(rows, powers: [3], ridge: 0.05))
        #expect(curve.expansion?.powers == [3])
        #expect(curve.weights.count == 8)
        #expect(curve.rmse < linear.rmse * 0.75)
    }

    @Test("계산 과정 표시: 평균 + 기여 합 = 출력 (선형·곡선)", arguments: [[Int](), [3]])
    func breakdownSumsToPrediction(powers: [Int]) throws {
        let model = try #require(GazeCalibration.fit(linearRows(count: 80, noise: 0.01), powers: powers, ridge: 0.05))
        let features = FaceFeatures(timestamp: 0, faceX: 0.52, faceWidth: 0.2, noseOffset: 0.12, pupilOffset: -0.05, yaw: 0.3)
        let gains = [1.0, 0.5, 1.5, 1.0]
        let breakdown = model.breakdown(features, gains: gains)
        let sum = breakdown.intercept + breakdown.terms.reduce(0) { $0 + $1.contribution }
        #expect(abs(sum - breakdown.raw) < 1e-9)
        #expect(abs(breakdown.raw - model.predict(features.vector, gains: gains)) < 1e-12)
    }

    @Test("학습 결과의 점별 평균 예측이 목표 근처")
    func targetResultsNearTargets() throws {
        var rows: [RegressionRow] = []
        for t in [0.1, 0.5, 0.9] {
            for i in 0..<20 {
                let nose: Double = -(t - 0.5) * 0.5 + Double(i % 5) * 0.001
                rows.append(RegressionRow(features: [nose, 0, 0.5, 0], target: t))
            }
        }
        let model = try #require(GazeCalibration.fit(rows))
        let results = try #require(model.targetResults)
        #expect(results.map { $0.target } == [0.1, 0.5, 0.9])
        for result in results { #expect(abs(result.predicted - result.target) < 0.01) }
    }

    // MARK: - 기본 추정식

    @Test("기본 추정식: 정면·화면 가운데면 0.5", arguments: AnalysisMode.allCases)
    func defaultModelCenter(mode: AnalysisMode) {
        let vector = [0.0, 0.0, 0.5, 0.0]
        #expect(abs(DefaultGazeModel.predict(vector, mode: mode) - 0.5) < 1e-12)
    }

    @Test("기본 추정식: 코가 +x(사용자 왼쪽)로 가면 화면 왼쪽")
    func defaultModelDirection() {
        let left = DefaultGazeModel.predict([0.2, 0.0, 0.5, 0.0], mode: .precise)
        let right = DefaultGazeModel.predict([-0.2, 0.0, 0.5, 0.0], mode: .precise)
        #expect(left < 0.5 && right > 0.5)
        // 머리 방향 방식은 코·동공을 쓰지 않는다
        #expect(DefaultGazeModel.predict([.nan, .nan, 0.5, 0.0], mode: .headPose) == 0.5)
        #expect(DefaultGazeModel.predict([0.3, 0.3, 0.5, 0.0], mode: .headPose) == 0.5)
    }

    @Test("기본 추정식 계산 과정 합 = 출력", arguments: AnalysisMode.allCases)
    func defaultBreakdown(mode: AnalysisMode) {
        let f = FaceFeatures(timestamp: 0, faceX: 0.6, faceWidth: 0.2, noseOffset: 0.1, pupilOffset: 0.05, yaw: -0.2)
        let b = DefaultGazeModel.breakdown(f, mode: mode, gains: [1, 2, 1, 1])
        let sum = b.intercept + b.terms.reduce(0) { $0 + $1.contribution }
        #expect(abs(sum - b.raw) < 1e-12)
        let usedFeatures = Set(DefaultGazeModel.terms(for: mode).map(\.0))
        for term in b.terms { #expect((term.slope != nil) == usedFeatures.contains(term.feature)) }
    }

    // MARK: - One Euro 필터

    @Test("필터: 일정한 입력은 그대로")
    func filterConstant() {
        var filter = OneEuroFilter()
        for i in 0..<50 { #expect(abs(filter.filter(0.3, timestamp: Double(i) * 0.2) - 0.3) < 1e-12) }
    }

    @Test("필터: 계단 입력에 점점 다가가고 넘지 않는다")
    func filterStepResponse() {
        var filter = OneEuroFilter()
        _ = filter.filter(0, timestamp: 0)
        var previous = 0.0
        for i in 1...40 {
            let value = filter.filter(1, timestamp: Double(i) * 0.2)
            #expect(value >= previous - 1e-12 && value <= 1 + 1e-12)
            previous = value
        }
        #expect(previous > 0.95)
    }

    @Test("필터: 차단 주파수가 높을수록 빨리 따라온다")
    func filterCutoffSpeed() {
        func firstStep(minCutoff: Double) -> Double {
            var filter = OneEuroFilter()
            filter.minCutoff = minCutoff
            filter.beta = 0
            _ = filter.filter(0, timestamp: 0)
            return filter.filter(1, timestamp: 0.2)
        }
        #expect(firstStep(minCutoff: 3) > firstStep(minCutoff: 0.3))
    }

    @Test("필터: 초기화하면 첫 값을 그대로 낸다")
    func filterReset() {
        var filter = OneEuroFilter()
        _ = filter.filter(0, timestamp: 0)
        _ = filter.filter(0, timestamp: 0.2)
        filter.reset()
        #expect(filter.filter(0.8, timestamp: 0.4) == 0.8)
    }

    @Test("필터: 시간이 거꾸로 가면 값을 새로 시작")
    func filterNonIncreasingTime() {
        var filter = OneEuroFilter()
        _ = filter.filter(0, timestamp: 1)
        #expect(filter.filter(0.7, timestamp: 0.5) == 0.7)
    }
}
