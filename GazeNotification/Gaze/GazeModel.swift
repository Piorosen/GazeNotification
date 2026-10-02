import Foundation

/// 보정 전 기본 추정식. 카메라가 모니터 상단 중앙에 있고 사용자가 정면 ~70cm 에 앉았다고 가정한 대략값.
/// 정확도는 낮으니 보정(`CalibrationSet`)을 권장.
enum DefaultGazeModel {
    /// (특징, 기울기, 기준값) — x = 0.5 + Σ 배율 · 기울기 · (값 − 기준값)
    static func terms(for mode: AnalysisMode) -> [(GazeFeature, Double, Double)] {
        switch mode {
        case .precise, .light: [(.nose, -1.25, 0), (.pupil, -0.8, 0), (.faceX, -0.7, 0.5)]
        // 코 방향 ≈ yaw(라디안) / 2 관계에서 옮긴 값
        case .headPose: [(.yaw, -0.6, 0), (.faceX, -0.7, 0.5)]
        }
    }

    /// - Parameter gains: 특징별 기여 배율 (`GazeAdjustment.featureGains`)
    static func predict(_ vector: [Double], mode: AnalysisMode, gains: [Double] = []) -> Double {
        var x = 0.5
        for (feature, slope, center) in terms(for: mode) {
            let value = vector[feature.rawValue]
            guard value.isFinite else { continue }
            x += featureGain(gains, feature) * slope * (value - center)
        }
        return x
    }

    static func breakdown(_ f: FaceFeatures, mode: AnalysisMode, gains: [Double] = []) -> GazeBreakdown {
        let vector = f.vector
        let terms = terms(for: mode)
        let rows = GazeFeature.allCases.map { feature -> GazeBreakdown.Term in
            let value = vector[feature.rawValue]
            guard let (_, slope, center) = terms.first(where: { $0.0 == feature }) else {
                return .init(feature: feature, value: value, slope: nil, gain: featureGain(gains, feature), contribution: 0)
            }
            let g = featureGain(gains, feature)
            let contribution = value.isFinite ? g * slope * (value - center) : 0
            return .init(feature: feature, value: value, slope: slope, gain: g, contribution: contribution)
        }
        return GazeBreakdown(modelName: String(localized: "기본 추정식 (보정 전)"),
                             intercept: 0.5, terms: rows, raw: predict(vector, mode: mode, gains: gains))
    }
}

/// 배율 배열에서 특징의 배율 (없으면 1)
func featureGain(_ gains: [Double], _ feature: GazeFeature) -> Double {
    feature.rawValue < gains.count ? gains[feature.rawValue] : 1
}

/// 회귀 입력 특징 (`FaceFeatures.vector` 순서)
enum GazeFeature: Int, CaseIterable, Identifiable {
    case nose, pupil, faceX, yaw

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .nose: String(localized: "코 방향")
        case .pupil: String(localized: "동공 위치")
        case .faceX: String(localized: "얼굴 위치")
        case .yaw: String(localized: "머리 회전")
        }
    }

    /// 어떻게 재는지
    var detail: String {
        switch self {
        case .nose: String(localized: "두 눈 사이 중점에 대한 코끝의 위치")
        case .pupil: String(localized: "눈 안에서 동공의 위치 (양쪽 눈 평균)")
        case .faceX: String(localized: "카메라 화면에서 얼굴의 가로 위치")
        case .yaw: String(localized: "얼굴 검출로 추정한 머리의 좌우 회전 각도")
        }
    }

    /// 표시 단위로 바꾸는 배율 (yaw 는 라디안 → 도)
    var displayScale: Double { self == .yaw ? 180 / .pi : 1 }

    func format(_ raw: Double) -> String {
        guard raw.isFinite else { return "—" }
        return self == .yaw ? String(format: "%+.1f°", raw * displayScale) : String(format: "%+.3f", raw)
    }
}

/// 한 프레임의 시선 계산 과정 (메뉴 표시용)
struct GazeBreakdown: Equatable {
    struct Term: Equatable, Identifiable {
        let feature: GazeFeature
        /// 원시 값 (yaw 는 라디안)
        let value: Double
        /// 원시 단위 1 당 x 변화 (수동 배율 적용 전). nil = 이 모델에서 사용 안 함
        let slope: Double?
        /// 수동으로 정한 기여 배율 (1 = 그대로)
        let gain: Double
        /// x 에 더해진 양 (화면 폭 비율, 배율 적용 후)
        let contribution: Double

        var id: Int { feature.rawValue }

        var slopeText: String {
            guard let slope else { return String(localized: "사용 안 함") }
            // yaw 는 1° 당 기울기로 표시
            let perUnit = slope / feature.displayScale
            return feature == .yaw ? String(format: "×%+.4f/°", perUnit) : String(format: "×%+.2f", perUnit)
        }
    }

    var modelName: String
    let intercept: Double
    let terms: [Term]
    /// 모델 출력 (필터 전)
    var raw: Double
    /// 점별 보간 전 회귀 출력 (점별 보간 모델일 때만)
    var regressionOutput: Double?
    /// 좌우 이동·범위 조정 후 (필터 전)
    var adjusted: Double = 0
    /// One Euro 필터·구역 맞춤 후 최종값
    var filtered: Double = 0
}

/// 보정 중 한 프레임: 분석 방식별 특징 벡터 (보정 중에는 모든 방식을 함께 계산한다)
struct CalibrationSample: Sendable, Codable, Equatable {
    var vectors: [AnalysisMode: [Double]]
    /// 사용자가 바라본 목표 지점 (화면 폭 기준 0...1)
    var target: Double
}

/// 회귀에 넣는 (특징, 목표) 한 줄
struct RegressionRow: Sendable {
    var features: [Double]
    var target: Double
}

/// 보정 데이터로 학습한 ridge 회귀: 특징 벡터 → 화면 가로 위치(0...1).
/// `expansion` 이 있으면 각 특징의 (값 − 중심)ⁿ 항을 더한 다항 회귀다.
struct GazeCalibration: Codable, Equatable {
    var used: [Bool]
    var means: [Double]
    var scales: [Double]
    var weights: [Double]
    var intercept: Double
    /// 학습 데이터 기준 RMSE (화면 폭 비율)
    var rmse: Double
    var sampleCount: Int
    var createdAt: Date
    /// 보정 점마다 학습 결과가 그 점을 얼마나 맞히는지 (예전 버전에서 저장한 보정에는 없음)
    var targetResults: [TargetResult]?
    /// 다항 회귀의 추가 항. nil = 선형
    var expansion: Expansion?

    /// 기본 특징마다 (값 − 중심)ⁿ 항을 `powers` 순서대로 덧붙인다
    struct Expansion: Codable, Equatable {
        /// 기본 특징별 중심 (보정 샘플 평균)
        var centers: [Double]
        var powers: [Int]
    }

    struct TargetResult: Codable, Equatable {
        var target: Double
        /// 그 점을 보는 동안 모델 출력 평균
        var predicted: Double
        var samples: Int
    }

    /// 기본 특징 수 (다항이면 가중치는 그 배수)
    private var baseCount: Int { expansion?.centers.count ?? weights.count }

    /// 기본 특징 → 회귀 입력 (다항이면 거듭제곱 항을 뒤에 붙인다)
    func expand(_ base: [Double]) -> [Double] {
        guard let expansion else { return base }
        var vector = base
        for power in expansion.powers {
            for j in expansion.centers.indices {
                let d = (j < base.count ? base[j] : .nan) - expansion.centers[j]
                vector.append(Foundation.pow(d, Double(power)))
            }
        }
        return vector
    }

    func breakdown(_ f: FaceFeatures, gains: [Double] = []) -> GazeBreakdown {
        let base = f.vector
        let vector = expand(base)
        let n = baseCount
        let rows = GazeFeature.allCases.map { feature -> GazeBreakdown.Term in
            let j = feature.rawValue
            let g = featureGain(gains, feature)
            // 이 특징에서 나온 항: 선형 항 j, (다항이면) 거듭제곱 항 n·k + j
            let indices = stride(from: j, to: weights.count, by: max(n, 1)).filter { used[$0] }
            guard j < n, !indices.isEmpty else {
                return .init(feature: feature, value: base[j], slope: nil, gain: g, contribution: 0)
            }
            let contribution = indices.reduce(0.0) { sum, k in
                let filled = vector[k].isFinite ? vector[k] : means[k]
                return sum + g * weights[k] * (filled - means[k]) / scales[k]
            }
            let slope = used[j] ? weights[j] / scales[j] : 0
            return .init(feature: feature, value: base[j], slope: slope, gain: g, contribution: contribution)
        }
        let name = expansion == nil ? String(localized: "선형 회귀") : String(localized: "곡선 회귀")
        return GazeBreakdown(modelName: String(localized: "\(name) (학습 오차 \(percentText(rmse)))"),
                             intercept: intercept, terms: rows, raw: predict(base, gains: gains))
    }

    /// - Parameter gains: 특징별 기여 배율 (`GazeAdjustment.featureGains`)
    func predict(_ features: [Double], gains: [Double] = []) -> Double {
        let vector = expand(features)
        let n = baseCount
        var y = intercept
        for j in weights.indices where j < vector.count && used[j] {
            let value = vector[j].isFinite ? vector[j] : means[j]
            let g = GazeFeature(rawValue: j % max(n, 1)).map { featureGain(gains, $0) } ?? 1
            y += g * weights[j] * (value - means[j]) / scales[j]
        }
        return y
    }

    /// - Parameter ridge: 표준화된 특징 공간에서의 L2 규제 강도 (샘플 수에 비례해 적용)
    /// 학습에 필요한 최소 샘플 수. 보정 점 3개 × 점당 0.8초(실시간 10회/s → 점당 약 8개)도 학습되도록.
    static let minimumSamples = 20

    /// - Parameter powers: 덧붙일 거듭제곱 (빈 배열 = 선형). 예: [3] = 세제곱 항
    static func fit(_ baseRows: [RegressionRow], powers: [Int] = [], ridge: Double = 0.02,
                    minSamples: Int = minimumSamples) -> GazeCalibration? {
        guard let baseDimension = baseRows.first?.features.count, baseDimension > 0, baseRows.count >= minSamples else { return nil }
        var expansion: Expansion?
        if !powers.isEmpty {
            let centers = (0..<baseDimension).map { j in
                let column = baseRows.map { $0.features[j] }.filter(\.isFinite)
                return column.isEmpty ? 0 : column.reduce(0, +) / Double(column.count)
            }
            expansion = Expansion(centers: centers, powers: powers)
        }
        let expander = GazeCalibration(used: [], means: [], scales: [], weights: [], intercept: 0, rmse: 0,
                                       sampleCount: 0, createdAt: Date(), expansion: expansion)
        let samples = baseRows.map { RegressionRow(features: expander.expand($0.features), target: $0.target) }
        let dimension = samples[0].features.count

        // 80% 이상 값이 있는 특징만 사용하고, 사용하는 특징이 모두 있는 행만 남긴다.
        var used = (0..<dimension).map { j in
            Double(samples.filter { $0.features[j].isFinite }.count) >= 0.8 * Double(samples.count)
        }
        let rows = samples.filter { s in (0..<dimension).allSatisfy { !used[$0] || s.features[$0].isFinite } }
        guard rows.count >= minSamples else { return nil }
        let n = Double(rows.count)

        var means = [Double](repeating: 0, count: dimension)
        var scales = [Double](repeating: 1, count: dimension)
        for j in 0..<dimension where used[j] {
            let column = rows.map { $0.features[j] }
            let mean = column.reduce(0, +) / n
            let std = (column.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n).squareRoot()
            means[j] = mean
            if std < 1e-6 { used[j] = false } else { scales[j] = std }
        }

        let active = (0..<dimension).filter { used[$0] }
        guard !active.isEmpty else { return nil }
        let k = active.count
        let yMean = rows.reduce(0) { $0 + $1.target } / n

        var a = [[Double]](repeating: [Double](repeating: 0, count: k), count: k)
        var b = [Double](repeating: 0, count: k)
        for row in rows {
            let z = active.map { (row.features[$0] - means[$0]) / scales[$0] }
            let yc = row.target - yMean
            for p in 0..<k {
                b[p] += z[p] * yc
                for q in 0..<k { a[p][q] += z[p] * z[q] }
            }
        }
        for p in 0..<k { a[p][p] += ridge * n }
        guard let solution = solveLinearSystem(a, b) else { return nil }

        var weights = [Double](repeating: 0, count: dimension)
        for (p, j) in active.enumerated() { weights[j] = solution[p] }

        var model = GazeCalibration(used: used, means: means, scales: scales, weights: weights,
                                    intercept: yMean, rmse: 0, sampleCount: rows.count, createdAt: Date(),
                                    expansion: expansion)
        // rows 는 확장된 특징이므로 예측은 확장 전 기본 특징으로
        let baseCount = baseDimension
        func base(_ row: RegressionRow) -> [Double] { Array(row.features.prefix(baseCount)) }
        let squaredError = rows.reduce(0) { acc, row in
            let e = model.predict(base(row)) - row.target
            return acc + e * e
        }
        model.rmse = (squaredError / n).squareRoot()
        model.targetResults = Dictionary(grouping: rows, by: \.target)
            .map { target, group in
                TargetResult(target: target,
                             predicted: group.reduce(0) { $0 + model.predict(base($1)) } / Double(group.count),
                             samples: group.count)
            }
            .sorted { $0.target < $1.target }
        return model
    }
}

/// 부분 피벗 가우스 소거. 특이 행렬이면 nil.
func solveLinearSystem(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
    let n = vector.count
    var a = matrix
    var b = vector
    for col in 0..<n {
        guard let pivot = (col..<n).max(by: { abs(a[$0][col]) < abs(a[$1][col]) }), abs(a[pivot][col]) > 1e-12 else {
            return nil
        }
        a.swapAt(col, pivot)
        b.swapAt(col, pivot)
        for row in (col + 1)..<n {
            let factor = a[row][col] / a[col][col]
            for c in col..<n { a[row][c] -= factor * a[col][c] }
            b[row] -= factor * b[col]
        }
    }
    var x = [Double](repeating: 0, count: n)
    for row in stride(from: n - 1, through: 0, by: -1) {
        var sum = b[row]
        for c in (row + 1)..<n { sum -= a[row][c] * x[c] }
        x[row] = sum / a[row][row]
    }
    return x
}

/// One Euro Filter: 천천히 움직일 땐 강하게, 빠르게 움직일 땐 약하게 스무딩.
struct OneEuroFilter {
    var minCutoff: Double = 0.8
    var beta: Double = 2.0
    var derivativeCutoff: Double = 1.0

    private var previousValue: Double?
    private var previousDerivative: Double = 0
    private var previousTime: TimeInterval?

    mutating func reset() {
        previousValue = nil
        previousTime = nil
        previousDerivative = 0
    }

    mutating func filter(_ value: Double, timestamp: TimeInterval) -> Double {
        guard let lastValue = previousValue, let lastTime = previousTime, timestamp > lastTime else {
            previousValue = value
            previousTime = timestamp
            return value
        }
        let dt = timestamp - lastTime
        let derivative = (value - lastValue) / dt
        let smoothedDerivative = Self.alpha(derivativeCutoff, dt) * derivative
            + (1 - Self.alpha(derivativeCutoff, dt)) * previousDerivative
        let cutoff = minCutoff + beta * abs(smoothedDerivative)
        let a = Self.alpha(cutoff, dt)
        let result = a * value + (1 - a) * lastValue
        previousValue = result
        previousDerivative = smoothedDerivative
        previousTime = timestamp
        return result
    }

    private static func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
