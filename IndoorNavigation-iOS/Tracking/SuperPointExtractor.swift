import Foundation
import CoreVideo
import CoreML
import QuartzCore
import simd

protocol SuperPointExtracting: AnyObject {
    func extract(image: CVPixelBuffer, intrinsics: simd_float3x3, timestamp: TimeInterval) -> SuperPointFrame
    func warmUp()
}

// MARK: - Stub (mlmodel 미가용 fallback)

/// 본 PR 스텁 구현. mlmodel 없이도 파이프라인·시각화·빈도 적응 검증 가능.
/// 더미 keypoint 생성: 입력 해상도(480×640) 위에 10×8 grid (총 80점) + 각 점에 ±4px 결정적 노이즈, score 0.3..0.95.
/// descriptor 더미: N × 256 MLMultiArray(.float16), 각 행 단위벡터.
final class SuperPointExtractorStub: SuperPointExtracting {

    struct Config {
        var inputSize: CGSize = CGSize(width: 480, height: 640)
        var maxKeypoints: Int = 512
        var gridCols: Int = 10
        var gridRows: Int = 8
        var noiseRadiusPx: Float = 4
    }

    private let config: Config
    init(config: Config = Config()) { self.config = config }

    func warmUp() {
        print("[SuperPoint] warmUp (stub, no model loaded)")
    }

    func extract(image: CVPixelBuffer, intrinsics: simd_float3x3, timestamp: TimeInterval) -> SuperPointFrame {
        var keypoints: [SIMD3<Float>] = []
        keypoints.reserveCapacity(config.gridRows * config.gridCols)

        var rng = SeededRNG(seed: UInt64(bitPattern: Int64(timestamp * 1000)))
        let w = Float(config.inputSize.width)
        let h = Float(config.inputSize.height)

        for r in 0..<config.gridRows {
            for c in 0..<config.gridCols {
                let baseU = (Float(c) + 0.5) * w / Float(config.gridCols)
                let baseV = (Float(r) + 0.5) * h / Float(config.gridRows)
                let nu = baseU + rng.nextFloat(-config.noiseRadiusPx, config.noiseRadiusPx)
                let nv = baseV + rng.nextFloat(-config.noiseRadiusPx, config.noiseRadiusPx)
                let score = rng.nextFloat(0.3, 0.95)
                keypoints.append(SIMD3<Float>(nu, nv, score))
            }
        }

        if keypoints.count > config.maxKeypoints {
            keypoints = Array(keypoints.prefix(config.maxKeypoints))
        }

        let descriptors = SuperPointExtractorStub.makeDummyDescriptors(count: keypoints.count, rng: &rng)

        return SuperPointFrame(
            intrinsics: intrinsics,
            timestamp: timestamp,
            keypoints: keypoints,
            descriptors: descriptors,
            inputSize: config.inputSize
        )
    }

    private static func makeDummyDescriptors(count: Int, rng: inout SeededRNG) -> MLMultiArray {
        let array = try! MLMultiArray(shape: [NSNumber(value: count), 256], dataType: .float16)
        for i in 0..<count {
            var v = [Float](repeating: 0, count: 256)
            var sumSq: Float = 0
            for j in 0..<256 {
                let x = rng.nextFloat(-1, 1)
                v[j] = x; sumSq += x * x
            }
            let inv = 1.0 / sqrt(max(sumSq, 1e-6))
            for j in 0..<256 {
                let f16 = Float16(v[j] * inv)
                let idx = i * 256 + j
                array[idx] = NSNumber(value: Float(f16))
            }
        }
        return array
    }
}

private struct SeededRNG {
    var state: UInt64
    init(seed: UInt64) { self.state = seed == 0 ? 0xdeadbeef : seed }
    mutating func nextU64() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
    mutating func nextFloat(_ lo: Float, _ hi: Float) -> Float {
        let u = Float(nextU64() & 0x00FFFFFF) / Float(0x01000000)
        return lo + (hi - lo) * u
    }
}

// MARK: - ML 구현 (Core ML 추론 래퍼)

/// SuperPoint Core ML 모델을 호출하는 실제 추출기.
///
/// 흐름:
///   ARFrame capturedImage(YUV) → PixelBufferPreprocessor (480×640 GRAY)
///   → SuperPoint.prediction(image:) → semi/desc MLMultiArray
///   → SuperPointHeatmapDecoder (NMS + top-K) → keypoints
///   → DescriptorSampler (bilinear + L2 + FP16) → descriptors
///
/// 자동 생성 클래스 시그니처가 가정과 다른 경우 (e.g. `SuperPointInput` wrapper)
/// `runPrediction(grayBuffer:)` 만 보정하면 됨.
final class SuperPointExtractorML: SuperPointExtracting {

    struct Config {
        var inputWidth: Int = 480
        var inputHeight: Int = 640
        var scoreThreshold: Float = 0.005
        var nmsRadiusPx: Int = 4
        var maxKeypoints: Int = 512
    }

    private let config: Config
    private let model: SuperPoint
    private let preprocessor: PixelBufferPreprocessor
    private let decoder: SuperPointHeatmapDecoder
    private let sampler: DescriptorSampler

    /// 추론 1회 소요 시간 (ms) 콜백. 호출자(ARNavigationLogic)가 ring buffer 에 누적.
    var onInferenceTimeMs: ((Double) -> Void)?

    init(config: Config = Config()) throws {
        self.config = config
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = .all
        self.model = try SuperPoint(configuration: mlConfig)
        self.preprocessor = PixelBufferPreprocessor()
        self.decoder = SuperPointHeatmapDecoder(config: SuperPointHeatmapDecoder.Config(
            inputWidth: config.inputWidth,
            inputHeight: config.inputHeight,
            cellSize: 8,
            dustbinChannelIndex: 64,
            scoreThreshold: config.scoreThreshold,
            nmsRadiusPx: config.nmsRadiusPx,
            maxKeypoints: config.maxKeypoints
        ))
        self.sampler = DescriptorSampler(config: DescriptorSampler.Config(
            inputWidth: config.inputWidth,
            inputHeight: config.inputHeight,
            cellSize: 8,
            descriptorDim: 256
        ))
    }

    func warmUp() {
        // 0-fill GRAY 480×640 buffer 1회 prediction → ANE 핫스타트.
        guard let buf = makeBlankGrayBuffer() else {
            print("[SuperPoint] warmUp skipped (failed to alloc blank buffer)")
            return
        }
        do {
            _ = try runPrediction(grayBuffer: buf)
            print("[SuperPoint] warmUp done")
        } catch {
            print("[SuperPoint] warmUp failed: \(error)")
        }
    }

    func extract(image: CVPixelBuffer, intrinsics: simd_float3x3, timestamp: TimeInterval) -> SuperPointFrame {
        let inputSize = CGSize(width: config.inputWidth, height: config.inputHeight)
        let emptyDesc = (try? MLMultiArray(shape: [0, 256], dataType: .float16)) ??
            (try! MLMultiArray(shape: [0, 256], dataType: .float16))
        let empty = SuperPointFrame(
            intrinsics: intrinsics,
            timestamp: timestamp,
            keypoints: [],
            descriptors: emptyDesc,
            inputSize: inputSize
        )

        let t0 = CACurrentMediaTime()

        guard let grayBuf = preprocessor.toGrayscale480x640(image) else {
            print("[SuperPoint] preprocess failed")
            return empty
        }

        let semiDesc: (semi: MLMultiArray, desc: MLMultiArray)
        do {
            semiDesc = try runPrediction(grayBuffer: grayBuf)
        } catch {
            print("[SuperPoint] prediction failed: \(error)")
            return empty
        }

        let keypoints = decoder.decode(semi: semiDesc.semi)
        let descriptors = sampler.sample(descMap: semiDesc.desc, keypoints: keypoints)

        let elapsedMs = (CACurrentMediaTime() - t0) * 1000.0
        onInferenceTimeMs?(elapsedMs)

        return SuperPointFrame(
            intrinsics: intrinsics,
            timestamp: timestamp,
            keypoints: keypoints,
            descriptors: descriptors,
            inputSize: inputSize
        )
    }

    // MARK: - 자동 생성 클래스 어댑터

    /// `SuperPoint` 자동 생성 클래스의 prediction 시그니처를 호출.
    /// 가정: `prediction(image: CVPixelBuffer) -> SuperPointOutput`, output 에 `semi`, `desc` 프로퍼티.
    /// 실제 시그니처가 다르면(예: `SuperPointInput` wrapper, `var_xxx` naming) 본 메서드만 보정.
    private func runPrediction(grayBuffer: CVPixelBuffer) throws -> (semi: MLMultiArray, desc: MLMultiArray) {
        let output = try model.prediction(image: grayBuffer)
        return (semi: output.semi, desc: output.desc)
    }

    private func makeBlankGrayBuffer() -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_OneComponent8,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any]
        ]
        var buf: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            config.inputWidth, config.inputHeight,
            kCVPixelFormatType_OneComponent8,
            attrs as CFDictionary,
            &buf
        )
        guard status == kCVReturnSuccess, let pb = buf else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        if let base = CVPixelBufferGetBaseAddress(pb) {
            let rows = CVPixelBufferGetHeight(pb)
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            memset(base, 0, rows * bpr)
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}
