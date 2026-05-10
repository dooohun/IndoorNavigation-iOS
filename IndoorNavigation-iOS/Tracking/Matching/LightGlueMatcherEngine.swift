import Foundation
import CoreML
import Accelerate

/// 2026-05-10: 호출자(ARNavigationLogic) 측 토글 OFF. 본 wrapper 는 dead code 상태이지만 컴파일 단위 보존(추후 재활성화 위해).
/// LightGlue Core ML 모델 wrapper. 두 SuperPoint feature set 간 학습된 매칭.
///
/// Phase 8 — 운영 단계에서 `DescriptorMatcher` (NN+ratio) 를 본 클래스로 교체 (S1).
/// 모델은 `tools/lightglue_to_coreml.py` 로 PyTorch → mlpackage 변환했으며
/// 정적 그래프(N=1024 고정) 보장을 위해 depth/width confidence·flash 가 비활성화되어 있다.
///
/// 입출력 (mlpackage Manifest 기준):
///   Inputs:
///     keypoints0    (1, 1024, 2)   Float32   query (=src) keypoint pixel (u, v)
///     descriptors0  (1, 1024, 256) Float32   query L2-normalized descriptors
///     keypoints1    (1, 1024, 2)   Float32   reference (=dst)
///     descriptors1  (1, 1024, 256) Float32   reference L2-normalized
///     image_size0   (1, 2)         Float32   [width, height] (변환 스크립트 line 92, 17)
///     image_size1   (1, 2)         Float32
///   Outputs:
///     matches0      (1, 1024)      Int32     각 query idx → 매칭 reference idx, -1 = no match
///     scores0       (1, 1024)      Float16   sigmoid 출력 0..1 (mlprogram FP16 양자화)
///
/// **클래스명 결정**: Core ML 이 mlpackage → `LightGlueMatcher` 자동 생성 클래스를
/// 만들어내므로 wrapper 명을 `LightGlueMatcherEngine` 으로 분리. 자동 생성된
/// `LightGlueMatcher` / `LightGlueMatcherInput` / `LightGlueMatcherOutput` 을 직접 사용한다.
/// (SuperPointExtractorML.swift:135 `private let model: SuperPoint` 패턴 동일)
final class LightGlueMatcherEngine {

    // MARK: - Public types

    struct Match {
        /// query (=src=keypoints0) 인덱스 (0..<Q)
        let queryIdx: Int
        /// reference (=dst=keypoints1) 인덱스 (0..<R)
        let refIdx: Int
        /// LightGlue sigmoid 출력 0..1
        let score: Float
    }

    /// LightGlue 변환 스크립트가 박은 정적 keypoint 한도. 본 wrapper 와 일치해야 함.
    static let fixedKeypointCount = 1024
    /// SuperPoint 디스크립터 차원. SuperPointExtractor 와 일치.
    static let descriptorDim = 256

    enum LightGlueError: Error, CustomStringConvertible {
        case modelLoadFailed(underlying: Error)
        case tooManyKeypoints(count: Int, max: Int)
        case shapeMismatch(reason: String)
        case predictionFailed(underlying: Error)

        var description: String {
            switch self {
            case .modelLoadFailed(let e):
                return "LightGlueMatcher.mlpackage 로드 실패 (\(e)). IndoorNavigation-iOS/ 폴더에 mlpackage 배치 후 재빌드 필요."
            case .tooManyKeypoints(let n, let max):
                return "Keypoints \(n) > 최대 \(max). SuperPoint maxKeypoints 설정 확인."
            case .shapeMismatch(let r):
                return "Shape 불일치: \(r)"
            case .predictionFailed(let e):
                return "추론 실패: \(e)"
            }
        }
    }

    // MARK: - Properties

    /// Core ML 자동 생성 클래스 (mlpackage 컴파일 산출물).
    private let model: LightGlueMatcher

    // MARK: - Init

    /// 앱 번들에 포함된 mlpackage 자동 로드.
    init() throws {
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = .cpuAndNeuralEngine
        do {
            self.model = try LightGlueMatcher(configuration: mlConfig)
        } catch {
            throw LightGlueError.modelLoadFailed(underlying: error)
        }
    }

    /// 컴파일된 .mlmodelc URL 직접 지정 (테스트/디버그).
    init(modelURL: URL) throws {
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = .cpuAndNeuralEngine
        do {
            self.model = try LightGlueMatcher(contentsOf: modelURL, configuration: mlConfig)
        } catch {
            throw LightGlueError.modelLoadFailed(underlying: error)
        }
    }

    // MARK: - 저수준 매칭 API

    /// query/reference 의 keypoint·descriptor 입력으로 매칭 수행.
    ///
    /// - Parameters:
    ///   - queryKeypoints: SuperPoint 키포인트 (u, v) — `querySize` 픽셀 단위. ≤ 1024.
    ///   - queryDescriptors: (Q, 256) FP16 MLMultiArray. L2 정규화 가정.
    ///   - querySize: query 이미지 해상도 (LightGlue position encoding 정규화에 사용).
    ///   - refKeypoints: bundle keyframe 키포인트 (u, v).
    ///   - refDescriptors: (R, 256) FP16 MLMultiArray.
    ///   - refSize: reference 이미지 해상도.
    /// - Returns: matches 배열. zero-pad 영역 (idx ≥ Q 또는 idx ≥ R) 으로의 매칭은 폐기.
    func match(
        queryKeypoints: [SIMD2<Float>],
        queryDescriptors: MLMultiArray,
        querySize: CGSize,
        refKeypoints: [SIMD2<Float>],
        refDescriptors: MLMultiArray,
        refSize: CGSize
    ) throws -> [Match] {
        let q = queryKeypoints.count
        let r = refKeypoints.count
        let n = LightGlueMatcherEngine.fixedKeypointCount
        let dim = LightGlueMatcherEngine.descriptorDim

        // 빈 입력 short-circuit.
        if q == 0 || r == 0 { return [] }
        if q > n { throw LightGlueError.tooManyKeypoints(count: q, max: n) }
        if r > n { throw LightGlueError.tooManyKeypoints(count: r, max: n) }

        // Descriptor shape/dtype 검증.
        guard queryDescriptors.shape.count == 2,
              queryDescriptors.shape[0].intValue == q,
              queryDescriptors.shape[1].intValue == dim,
              queryDescriptors.dataType == .float16 else {
            throw LightGlueError.shapeMismatch(reason: "query descriptors expected (\(q), \(dim)) FP16, got \(queryDescriptors.shape) \(queryDescriptors.dataType)")
        }
        guard refDescriptors.shape.count == 2,
              refDescriptors.shape[0].intValue == r,
              refDescriptors.shape[1].intValue == dim,
              refDescriptors.dataType == .float16 else {
            throw LightGlueError.shapeMismatch(reason: "ref descriptors expected (\(r), \(dim)) FP16, got \(refDescriptors.shape) \(refDescriptors.dataType)")
        }

        // (1, 1024, 2) keypoints, (1, 1024, 256) descriptors, (1, 2) image_size 패딩.
        let kp0Array = try makeKeypointsArray(queryKeypoints, capacity: n)
        let desc0Array = try makePaddedDescriptorsArray(fp16Source: queryDescriptors, validRows: q, capacity: n)
        let kp1Array = try makeKeypointsArray(refKeypoints, capacity: n)
        let desc1Array = try makePaddedDescriptorsArray(fp16Source: refDescriptors, validRows: r, capacity: n)
        let imgSize0Array = try makeImageSizeArray(querySize)
        let imgSize1Array = try makeImageSizeArray(refSize)

        let input = LightGlueMatcherInput(
            keypoints0: kp0Array,
            descriptors0: desc0Array,
            keypoints1: kp1Array,
            descriptors1: desc1Array,
            image_size0: imgSize0Array,
            image_size1: imgSize1Array
        )

        let output: LightGlueMatcherOutput
        do {
            output = try model.prediction(input: input)
        } catch {
            throw LightGlueError.predictionFailed(underlying: error)
        }

        return parseOutput(matches0: output.matches0, scores0: output.scores0, validQ: q, validR: r)
    }

    // MARK: - 고수준 매칭 API (SuperPointFrame ↔ BundleKeyframe)

    /// SuperPoint 프레임 ↔ bundle keyframe 매칭. `targetIntrinsics` 는 reference 이미지 해상도 제공.
    func match(
        query: SuperPointFrame,
        targetKeyframe: BundleKeyframe,
        targetIntrinsics: BundleIntrinsics
    ) throws -> [Match] {
        // 1. query: SIMD3 (u, v, score) → SIMD2 (u, v)
        let queryKp: [SIMD2<Float>] = query.keypoints.map { SIMD2<Float>($0.x, $0.y) }

        // 2. reference: [[Float]] (u, v) → SIMD2
        let refKp: [SIMD2<Float>] = targetKeyframe.keypoints.compactMap { kp in
            guard kp.count >= 2 else { return nil }
            return SIMD2<Float>(kp[0], kp[1])
        }

        // 3. reference descriptors base64 → (R, 256) FP16 MLMultiArray
        guard let refData = Data(base64Encoded: targetKeyframe.descriptorsB64) else {
            throw LightGlueError.shapeMismatch(reason: "descriptors_b64 base64 디코딩 실패")
        }
        let r = refKp.count
        let dim = LightGlueMatcherEngine.descriptorDim
        let expectedBytes = r * dim * MemoryLayout<Float16>.size
        guard refData.count == expectedBytes else {
            throw LightGlueError.shapeMismatch(reason: "reference descriptors 사이즈 불일치: \(refData.count) ≠ \(expectedBytes)")
        }
        let refDescArr = try MLMultiArray(shape: [NSNumber(value: r), NSNumber(value: dim)], dataType: .float16)
        let refPtr = refDescArr.dataPointer.bindMemory(to: Float16.self, capacity: r * dim)
        refData.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let src = buf.bindMemory(to: Float16.self).baseAddress else { return }
            for i in 0..<(r * dim) { refPtr[i] = src[i] }
        }

        // 4. reference 이미지 사이즈
        let refSize = CGSize(width: targetIntrinsics.width, height: targetIntrinsics.height)

        return try match(
            queryKeypoints: queryKp,
            queryDescriptors: query.descriptors,
            querySize: query.inputSize,
            refKeypoints: refKp,
            refDescriptors: refDescArr,
            refSize: refSize
        )
    }

    // MARK: - 입력 패딩 헬퍼

    /// (1, capacity, 2) Float32 MLMultiArray 생성. 앞 keypoints.count 채움 + 뒤 zero-pad.
    private func makeKeypointsArray(_ keypoints: [SIMD2<Float>], capacity: Int) throws -> MLMultiArray {
        let shape: [NSNumber] = [1, NSNumber(value: capacity), 2]
        let arr = try MLMultiArray(shape: shape, dataType: .float32)
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: capacity * 2)
        // 0-fill 후 앞부분 채우기.
        memset(arr.dataPointer, 0, capacity * 2 * MemoryLayout<Float>.size)
        for (i, kp) in keypoints.enumerated() where i < capacity {
            ptr[i * 2 + 0] = kp.x
            ptr[i * 2 + 1] = kp.y
        }
        return arr
    }

    /// (1, capacity, 256) Float32 MLMultiArray 생성. 앞 validRows 만큼 FP16 → FP32 변환 + 뒤 zero-pad.
    private func makePaddedDescriptorsArray(fp16Source: MLMultiArray, validRows: Int, capacity: Int) throws -> MLMultiArray {
        let dim = LightGlueMatcherEngine.descriptorDim
        let shape: [NSNumber] = [1, NSNumber(value: capacity), NSNumber(value: dim)]
        let arr = try MLMultiArray(shape: shape, dataType: .float32)
        // 0-fill 전체.
        memset(arr.dataPointer, 0, capacity * dim * MemoryLayout<Float>.size)
        if validRows == 0 { return arr }

        // FP16 → FP32 변환 (vImage). DescriptorMatcher.float32Array(fromFP16:count:) 패턴 복제.
        let f32 = LightGlueMatcherEngine.float32Array(fromFP16: fp16Source.dataPointer, count: validRows * dim)
        guard f32.count == validRows * dim else {
            throw LightGlueError.shapeMismatch(reason: "FP16→FP32 변환 결과 길이 불일치")
        }
        let dst = arr.dataPointer.bindMemory(to: Float.self, capacity: capacity * dim)
        f32.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            memcpy(dst, base, validRows * dim * MemoryLayout<Float>.size)
        }
        return arr
    }

    /// (1, 2) Float32 [width, height] MLMultiArray. 변환 스크립트 입력 정의 일치.
    private func makeImageSizeArray(_ size: CGSize) throws -> MLMultiArray {
        let arr = try MLMultiArray(shape: [1, 2], dataType: .float32)
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: 2)
        ptr[0] = Float(size.width)
        ptr[1] = Float(size.height)
        return arr
    }

    // MARK: - Output 파싱

    /// `matches0 (1, 1024)` Int32 + `scores0 (1, 1024)` Float16 → `[Match]`.
    /// zero-pad 영역으로 매칭된 항목(`dst >= validR`)은 폐기.
    private func parseOutput(matches0: MLMultiArray, scores0: MLMultiArray, validQ: Int, validR: Int) -> [Match] {
        let count = matches0.count
        guard count >= validQ else {
            return []
        }
        guard scores0.count >= validQ else {
            return []
        }

        var result: [Match] = []
        result.reserveCapacity(validQ)

        // matches0 dtype 은 Int32 (자동 생성 헤더 line 79 명시).
        // scores0 dtype 은 Float16 (line 89 명시) — NSNumber 추출 시 floatValue 자동 변환.
        for i in 0..<validQ {
            let dst = matches0[i].intValue
            // -1 = no match (LightGlue sentinel). dst < 0 또는 dst >= validR (zero-pad 영역) 폐기.
            guard dst >= 0, dst < validR else { continue }
            let s = scores0[i].floatValue
            result.append(Match(queryIdx: i, refIdx: dst, score: s))
        }
        return result
    }

    // MARK: - FP16 → FP32 변환 (DescriptorMatcher.swift:162-182 패턴 복제)

    /// FP16 raw 메모리 → Float32 [count] 변환 (vImage 일괄).
    /// DescriptorMatcher.float32Array(fromFP16:count:) 와 동일. 본 wrapper 자급자족 위해 복제.
    private static func float32Array(fromFP16 ptr: UnsafeMutableRawPointer, count: Int) -> [Float] {
        var result = [Float](repeating: 0, count: count)
        let src = ptr.bindMemory(to: UInt16.self, capacity: count)
        var srcBuf = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: src),
            height: 1,
            width: vImagePixelCount(count),
            rowBytes: count * MemoryLayout<UInt16>.size
        )
        result.withUnsafeMutableBufferPointer { dstPtr in
            var dstBuf = vImage_Buffer(
                data: dstPtr.baseAddress!,
                height: 1,
                width: vImagePixelCount(count),
                rowBytes: count * MemoryLayout<Float>.size
            )
            _ = vImageConvert_Planar16FtoPlanarF(&srcBuf, &dstBuf, vImage_Flags(kvImageNoFlags))
        }
        return result
    }
}
