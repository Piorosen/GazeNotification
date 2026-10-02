import Foundation

/// 학습된 시선 추정 모델 하나 (분석 방식 하나 × 모델 종류 하나)
struct GazeEstimator: Codable, Equatable {
    var kind: EstimatorKind
    /// 선형/곡선은 이 회귀가 곧 모델, 점별 보간은 이 선형 회귀 출력을 `knots` 로 다시 맞춘다
    var regression: GazeCalibration
    /// 점별 보간: (회귀 출력 → 실제 위치), 회귀 출력 오름차순
    var knots: [Knot]?
    /// 학습 데이터 기준 RMSE (화면 폭 비율)
    var trainingRMSE: Double
    /// 보정 점 하나씩 빼고 학습해 그 점을 맞혀 본 RMSE. 새 위치를 얼마나 잘 맞힐지에 더 가깝다
    var crossValidationRMSE: Double?
    var targetResults: [GazeCalibration.TargetResult]

    struct Knot: Codable, Equatable {
        var input: Double
        var output: Double
    }

    func predict(_ vector: [Double], gains: [Double] = []) -> Double {
        let y = regression.predict(vector, gains: gains)
        guard let knots else { return y }
        return Self.interpolate(y, knots)
    }

    func breakdown(_ f: FaceFeatures, gains: [Double] = []) -> GazeBreakdown {
        var breakdown = regression.breakdown(f, gains: gains)
        if let knots {
            breakdown.regressionOutput = breakdown.raw
            breakdown.raw = Self.interpolate(breakdown.raw, knots)
        }
        breakdown.modelName = crossValidationRMSE.map {
            String(localized: "\(kind.title) (학습 오차 \(percentText(trainingRMSE)), 교차 검증 오차 \(percentText($0)))")
        } ?? String(localized: "\(kind.title) (학습 오차 \(percentText(trainingRMSE)))")
        return breakdown
    }

    /// 점 사이는 직선, 바깥은 끝 구간의 기울기로 연장
    static func interpolate(_ x: Double, _ knots: [Knot]) -> Double {
        guard knots.count >= 2 else { return knots.first.map { x - $0.input + $0.output } ?? x }
        var i = 0
        while i < knots.count - 2 && x > knots[i + 1].input { i += 1 }
        let a = knots[i], b = knots[i + 1]
        let slope = (b.output - a.output) / max(b.input - a.input, 1e-6)
        return a.output + (x - a.input) * slope
    }

    /// - Returns: 학습할 수 없으면 nil (샘플 부족, 점별 보간인데 점 순서가 뒤바뀜 등)
    static func fit(_ kind: EstimatorKind, rows: [RegressionRow]) -> GazeEstimator? {
        switch kind {
        case .formula:
            return nil
        case .linear, .curve:
            guard let model = GazeCalibration.fit(rows, powers: kind == .curve ? curvePowers : [],
                                                  ridge: kind == .curve ? curveRidge : 0.02) else { return nil }
            return GazeEstimator(kind: kind, regression: model, knots: nil, trainingRMSE: model.rmse,
                                 crossValidationRMSE: nil, targetResults: model.targetResults ?? [])
        case .piecewise:
            guard let model = GazeCalibration.fit(rows), let results = model.targetResults, results.count >= 2 else { return nil }
            let knots = results.map { Knot(input: $0.predicted, output: $0.target) }.sorted { $0.input < $1.input }
            // 목표 순서와 회귀 출력 순서가 같아야 단조로운 보간이 된다
            guard zip(knots, knots.dropFirst()).allSatisfy({ $1.output > $0.output && $1.input - $0.input > 0.005 }) else {
                return nil
            }
            let draft = GazeEstimator(kind: kind, regression: model, knots: knots, trainingRMSE: 0,
                                      crossValidationRMSE: nil, targetResults: [])
            var estimator = draft
            estimator.trainingRMSE = rmse(rows) { draft.predict($0.features) }
            estimator.targetResults = Dictionary(grouping: rows, by: \.target).map { target, group in
                GazeCalibration.TargetResult(target: target,
                                             predicted: group.reduce(0) { $0 + draft.predict($1.features) } / Double(group.count),
                                             samples: group.count)
            }.sorted { $0.target < $1.target }
            return estimator
        }
    }

    /// 곡선 회귀: 세제곱 항. 머리 방향 → 화면 위치는 tan 처럼 좌우 대칭으로 휘어서 제곱(짝수) 항으로는 못 맞춘다.
    /// 합성 데이터(tan + 노이즈) 비교, 교차검증 오차: 선형 4.6% · 제곱 9.0% · 세제곱 1.9% · 제곱+세제곱 2.3%
    static let curvePowers = [3]
    static let curveRidge = 0.05

    static func rmse(_ rows: [RegressionRow], _ predict: (RegressionRow) -> Double) -> Double {
        guard !rows.isEmpty else { return .nan }
        let squared = rows.reduce(0) { sum, row in
            let e = predict(row) - row.target
            return sum + e * e
        }
        return (squared / Double(rows.count)).squareRoot()
    }

    /// 안쪽 보정 점을 하나씩 빼고 나머지로 학습해 뺀 점을 맞혀 본 RMSE (leave-one-target-out).
    /// 양 끝 점은 빼지 않는다 — 실제로 보는 곳은 보정한 범위 안이라, 끝을 빼서 외삽시키면 보간 성능과 무관하게 나빠 보인다.
    static func crossValidate(_ kind: EstimatorKind, rows: [RegressionRow]) -> Double? {
        let targets = Set(rows.map(\.target)).sorted()
        guard targets.count >= 3 else { return nil }
        var squared = 0.0, count = 0
        for held in targets.dropFirst().dropLast() {
            let train = rows.filter { $0.target != held }
            guard let model = fit(kind, rows: train) else { return nil }
            for row in rows where row.target == held {
                let e = model.predict(row.features) - row.target
                guard e.isFinite else { continue }
                squared += e * e
                count += 1
            }
        }
        return count > 0 ? (squared / Double(count)).squareRoot() : nil
    }
}

/// 한 번의 보정으로 학습한 모든 모델 (분석 방식 × 모델 종류). 샘플도 저장해 두어 나중에 다시 학습할 수 있다.
struct CalibrationSet: Codable, Equatable {
    var createdAt: Date
    var targets: [Double]
    var samples: [CalibrationSample]
    /// 분석 방식 → 모델 종류 → 모델
    var models: [AnalysisMode: [EstimatorKind: GazeEstimator]]
    /// 기본 추정식을 같은 샘플에 적용했을 때의 RMSE (비교용)
    var formulaRMSE: [AnalysisMode: Double]

    func estimator(_ mode: AnalysisMode, _ kind: EstimatorKind) -> GazeEstimator? {
        models[mode]?[kind]
    }

    func hasModels(for mode: AnalysisMode) -> Bool {
        !(models[mode]?.isEmpty ?? true)
    }

    /// 교차검증 오차가 가장 작은 모델 (교차검증이 없으면 선형)
    func bestKind(for mode: AnalysisMode) -> EstimatorKind? {
        guard let candidates = models[mode], !candidates.isEmpty else { return nil }
        let scored = candidates.compactMap { kind, model in model.crossValidationRMSE.map { (kind, $0) } }
        if let best = scored.min(by: { $0.1 < $1.1 }) { return best.0 }
        return candidates[.linear] != nil ? .linear : candidates.keys.first
    }

    /// 모든 분석 방식 × 모델 종류를 학습한다
    static func fit(samples: [CalibrationSample], targets: [Double]) -> CalibrationSet {
        var models: [AnalysisMode: [EstimatorKind: GazeEstimator]] = [:]
        var formula: [AnalysisMode: Double] = [:]
        for mode in AnalysisMode.allCases {
            let rows = samples.compactMap { sample in
                sample.vectors[mode].map { RegressionRow(features: $0, target: sample.target) }
            }
            guard !rows.isEmpty else { continue }
            formula[mode] = GazeEstimator.rmse(rows) { DefaultGazeModel.predict($0.features, mode: mode) }
            var byKind: [EstimatorKind: GazeEstimator] = [:]
            for kind in EstimatorKind.allCases where kind != .formula {
                guard var model = GazeEstimator.fit(kind, rows: rows) else { continue }
                model.crossValidationRMSE = GazeEstimator.crossValidate(kind, rows: rows)
                byKind[kind] = model
            }
            if !byKind.isEmpty { models[mode] = byKind }
        }
        return CalibrationSet(createdAt: Date(), targets: targets, samples: samples, models: models, formulaRMSE: formula)
    }

    /// 예전 버전(분석 방식 하나, 선형 모델 하나)에서 저장한 보정
    static func migrated(from legacy: GazeCalibration) -> CalibrationSet {
        let estimator = GazeEstimator(kind: .linear, regression: legacy, knots: nil, trainingRMSE: legacy.rmse,
                                      crossValidationRMSE: nil, targetResults: legacy.targetResults ?? [])
        return CalibrationSet(createdAt: legacy.createdAt, targets: legacy.targetResults?.map(\.target) ?? [],
                              samples: [], models: [.precise: [.linear: estimator]], formulaRMSE: [:])
    }
}
