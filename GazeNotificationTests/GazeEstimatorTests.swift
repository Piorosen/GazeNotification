import Foundation
import Testing
@testable import GazeNotification

/// 추정 모델(선형·곡선·점별 보간)·교차검증·보정 묶음 저장
@Suite("시선 추정 모델과 보정 묶음")
struct GazeEstimatorTests {
    /// 가상 사용자가 보정 점을 바라볼 때의 샘플 (세 분석 방식 모두)
    static func simulatedSamples(targets: [Double] = CalibrationPlan.evenTargets(5), perTarget: Int = 16) -> [CalibrationSample] {
        targets.flatMap { target in
            (0..<perTarget).map { i in
                let time = Double(i) * 0.1 + target * 10
                let vectors = Dictionary(uniqueKeysWithValues: AnalysisMode.allCases.map { mode in
                    (mode, SimulatedFaceSource.features(gaze: target, time: time, mode: mode).vector)
                })
                return CalibrationSample(vectors: vectors, target: target)
            }
        }
    }

    static func rows(_ samples: [CalibrationSample], _ mode: AnalysisMode) -> [RegressionRow] {
        samples.compactMap { sample in sample.vectors[mode].map { RegressionRow(features: $0, target: sample.target) } }
    }

    // MARK: - 점별 보간

    @Test("보간: 점 사이는 직선, 바깥은 끝 구간 기울기")
    func interpolation() {
        let knots = [GazeEstimator.Knot(input: 0.2, output: 0.0), .init(input: 0.4, output: 0.5), .init(input: 0.8, output: 1.0)]
        #expect(abs(GazeEstimator.interpolate(0.3, knots) - 0.25) < 1e-12)
        #expect(abs(GazeEstimator.interpolate(0.6, knots) - 0.75) < 1e-12)
        #expect(abs(GazeEstimator.interpolate(0.1, knots) - -0.25) < 1e-12)   // 왼쪽 연장 (기울기 2.5)
        #expect(abs(GazeEstimator.interpolate(1.0, knots) - 1.25) < 1e-12)    // 오른쪽 연장 (기울기 1.25)
        for knot in knots { #expect(abs(GazeEstimator.interpolate(knot.input, knots) - knot.output) < 1e-12) }
    }

    @Test("보간: 점이 하나면 평행 이동, 없으면 그대로")
    func interpolationDegenerate() {
        #expect(GazeEstimator.interpolate(0.3, [.init(input: 0.2, output: 0.5)]) == 0.6)
        #expect(GazeEstimator.interpolate(0.3, []) == 0.3)
    }

    @Test("점별 보간 모델은 보정 점에서 목표를 거의 그대로 맞히고 단조 증가")
    func piecewiseHitsTargets() throws {
        let rows = Self.rows(Self.simulatedSamples(), .precise)
        let model = try #require(GazeEstimator.fit(.piecewise, rows: rows))
        let knots = try #require(model.knots)
        #expect(zip(knots, knots.dropFirst()).allSatisfy { $1.input > $0.input && $1.output > $0.output })
        for result in model.targetResults { #expect(abs(result.predicted - result.target) < 0.01) }
        // 화면을 훑으면 출력도 같은 순서로
        let sweep = stride(from: 0.0, through: 1.0, by: 0.05).map {
            model.predict(SimulatedFaceSource.features(gaze: $0, time: 0, mode: .precise).vector)
        }
        #expect(zip(sweep, sweep.dropFirst()).allSatisfy { $1 > $0 })
    }

    @Test("점 순서가 뒤바뀌면 점별 보간은 학습하지 않는다")
    func piecewiseRejectsNonMonotonic() {
        // 0.5 를 볼 때 특징이 양 끝보다 더 오른쪽 → 회귀 출력 순서가 목표 순서와 다름
        let rows = [(0.1, 0.10), (0.5, 0.30), (0.9, 0.20)].flatMap { target, feature in
            (0..<15).map { i in RegressionRow(features: [feature + Double(i) * 0.0001, .nan, 0.5, .nan], target: target) }
        }
        #expect(GazeEstimator.fit(.piecewise, rows: rows) == nil)
        #expect(GazeEstimator.fit(.formula, rows: rows) == nil)
    }

    // MARK: - 교차검증

    @Test("교차검증은 안쪽 점만 빼 보고, 보정 점이 3개 미만이면 하지 않는다")
    func crossValidationTargets() {
        let three = Self.rows(Self.simulatedSamples(targets: [0.04, 0.5, 0.96]), .precise)
        #expect(GazeEstimator.crossValidate(.linear, rows: three) != nil)
        let two = Self.rows(Self.simulatedSamples(targets: [0.04, 0.96], perTarget: 20), .precise)
        #expect(GazeEstimator.crossValidate(.linear, rows: two) == nil)
    }

    @Test("곡선 회귀는 휘는 관계에서 교차검증 오차가 선형보다 작다")
    func curveBeatsLinearOnBentData() throws {
        let rows = Self.rows(Self.simulatedSamples(), .precise)
        let linear = try #require(GazeEstimator.crossValidate(.linear, rows: rows))
        let curve = try #require(GazeEstimator.crossValidate(.curve, rows: rows))
        #expect(curve < linear)
    }

    // MARK: - 보정 묶음

    @Test("보정 한 번으로 세 방식 × 세 모델을 모두 학습")
    func calibrationSetFitsEverything() throws {
        let set = CalibrationSet.fit(samples: Self.simulatedSamples(), targets: CalibrationPlan.evenTargets(5))
        for mode in AnalysisMode.allCases {
            #expect(set.hasModels(for: mode))
            for kind in [EstimatorKind.linear, .curve, .piecewise] {
                let model = try #require(set.estimator(mode, kind), "\(mode) \(kind)")
                #expect(model.kind == kind)
                #expect(model.trainingRMSE < 0.05)
                #expect(model.crossValidationRMSE != nil)
            }
            #expect(set.estimator(mode, .formula) == nil)
            #expect(set.formulaRMSE[mode] != nil)
        }
    }

    @Test("자동 선택은 교차검증 오차가 가장 작은 모델")
    func bestKindHasLowestCrossValidation() throws {
        let set = CalibrationSet.fit(samples: Self.simulatedSamples(), targets: CalibrationPlan.evenTargets(5))
        for mode in AnalysisMode.allCases {
            let best = try #require(set.bestKind(for: mode))
            let bestError = try #require(set.estimator(mode, best)?.crossValidationRMSE)
            for (_, model) in set.models[mode] ?? [:] {
                #expect(bestError <= (model.crossValidationRMSE ?? .infinity) + 1e-12)
            }
        }
    }

    /// 랜드마크 방식은 3%, 머리 방향만은 5% (코·동공이 없어 얼굴 위치의 작은 흔들림에 더 민감)
    @Test("학습한 모델이 처음 보는 위치의 가상 시선을 맞힌다", arguments: [(AnalysisMode.precise, 0.03), (.light, 0.03), (.headPose, 0.05)])
    func trainedModelTracksSimulatedGaze(mode: AnalysisMode, tolerance: Double) throws {
        let set = CalibrationSet.fit(samples: Self.simulatedSamples(), targets: CalibrationPlan.evenTargets(5))
        let kind = try #require(set.bestKind(for: mode))
        let model = try #require(set.estimator(mode, kind))
        for gaze in stride(from: 0.1, through: 0.9, by: 0.1) {
            let predicted = model.predict(SimulatedFaceSource.features(gaze: gaze, time: 3.3, mode: mode).vector)
            #expect(abs(predicted - gaze) < tolerance, "\(kind) gaze \(gaze) → \(predicted)")
        }
    }

    @Test("한 방식의 샘플만 있으면 그 방식만 학습")
    func partialSamples() {
        let samples = Self.simulatedSamples().map { CalibrationSample(vectors: [.light: $0.vectors[.light]!], target: $0.target) }
        let set = CalibrationSet.fit(samples: samples, targets: CalibrationPlan.evenTargets(5))
        #expect(set.hasModels(for: .light))
        #expect(!set.hasModels(for: .precise))
        #expect(set.bestKind(for: .precise) == nil)
    }

    @Test("저장·복원: 빠진 값(NaN)이 있어도 모델과 샘플이 그대로")
    func codableRoundTripWithNaN() throws {
        let set = CalibrationSet.fit(samples: Self.simulatedSamples(), targets: CalibrationPlan.evenTargets(5))
        #expect(set.samples.contains { $0.vectors[.headPose]?.first?.isNaN == true })
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let restored = try decoder.decode(CalibrationSet.self, from: encoder.encode(set))
        #expect(restored.models == set.models)
        #expect(restored.targets == set.targets)
        #expect(restored.samples.count == set.samples.count)
        #expect(restored.samples.first?.vectors[.headPose]?.first?.isNaN == true)
        let probe = SimulatedFaceSource.features(gaze: 0.3, time: 1, mode: .precise).vector
        #expect(restored.estimator(.precise, .curve)?.predict(probe) == set.estimator(.precise, .curve)?.predict(probe))
    }

    @Test("NaN 처리 없이 저장하면 실패한다 (저장 코드가 전략을 꼭 써야 하는 이유)")
    func plainEncoderRejectsNaN() {
        let set = CalibrationSet.fit(samples: Self.simulatedSamples(), targets: CalibrationPlan.evenTargets(5))
        #expect(throws: (any Error).self) { try JSONEncoder().encode(set) }
    }

    @Test("예전 보정(v1)은 정밀·선형 모델 하나로 옮긴다")
    func legacyMigration() throws {
        let rows = Self.rows(Self.simulatedSamples(), .precise)
        let legacy = try #require(GazeCalibration.fit(rows))
        let set = CalibrationSet.migrated(from: legacy)
        #expect(set.models.keys.sorted { $0.rawValue < $1.rawValue } == [.precise])
        #expect(set.estimator(.precise, .linear)?.regression == legacy)
        #expect(set.bestKind(for: .precise) == .linear)
        #expect(set.samples.isEmpty)
        #expect(set.createdAt == legacy.createdAt)
    }

    @Test("모델 계산 과정: 점별 보간이면 회귀 출력과 보간 후 값을 함께 보여 준다")
    func estimatorBreakdown() throws {
        let set = CalibrationSet.fit(samples: Self.simulatedSamples(), targets: CalibrationPlan.evenTargets(5))
        let features = SimulatedFaceSource.features(gaze: 0.7, time: 0, mode: .precise)
        let piecewise = try #require(set.estimator(.precise, .piecewise))
        let b = piecewise.breakdown(features)
        let regression = try #require(b.regressionOutput)
        #expect(abs(b.intercept + b.terms.reduce(0) { $0 + $1.contribution } - regression) < 1e-9)
        #expect(abs(b.raw - piecewise.predict(features.vector)) < 1e-12)
        #expect(b.modelName.contains(EstimatorKind.piecewise.title))
        let linear = try #require(set.estimator(.precise, .linear))
        #expect(linear.breakdown(features).regressionOutput == nil)
    }
}
