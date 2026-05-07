import Foundation
import CoreML
import Accelerate
import simd

/// SuperPoint `desc` 출력 (1, 256, H/8, W/8) 에서 keypoint 위치 별 256-d descriptor 를
/// bilinear sampling 으로 추출. Phase 8·9·10 공통 규약: 256 차원, FP16, L2 정규화.
final class DescriptorSampler {

    struct Config {
        var inputWidth: Int = 480
        var inputHeight: Int = 640
        var cellSize: Int = 8
        var descriptorDim: Int = 256
    }

    private let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    /// keypoints 각각의 입력 이미지 좌표(u, v)에 대응하는 desc 좌표(u/cell, v/cell)에서
    /// bilinear sampling → L2 정규화 → Float16 으로 변환하여 (N × 256, .float16) MLMultiArray 반환.
    /// keypoints.count == 0 인 경우 (0 × 256) MLMultiArray 반환.
    func sample(descMap: MLMultiArray, keypoints: [SIMD3<Float>]) -> MLMultiArray {
        let dim = config.descriptorDim
        let n = keypoints.count

        // n == 0 가드: empty MLMultiArray
        if n == 0 {
            return (try? MLMultiArray(shape: [0, NSNumber(value: dim)], dataType: .float16))
                ?? Self.makeEmpty(dim: dim)
        }

        let shape = descMap.shape.map { $0.intValue }
        guard shape.count == 4, shape[1] == dim else {
            print("[DescSample] descMap shape unexpected: \(shape)")
            return (try? MLMultiArray(shape: [NSNumber(value: n), NSNumber(value: dim)], dataType: .float16))
                ?? Self.makeEmpty(dim: dim)
        }
        let descH = shape[2]
        let descW = shape[3]
        let strides = descMap.strides.map { $0.intValue }
        // strides[1] = channel stride, strides[2] = row stride, strides[3] = col stride

        // FP16 → FP32 일괄 변환 (vImage)
        let f32 = float32Buffer(from: descMap)

        let cell = Float(config.cellSize)

        // 결과 array
        let array: MLMultiArray
        do {
            array = try MLMultiArray(shape: [NSNumber(value: n), NSNumber(value: dim)], dataType: .float16)
        } catch {
            print("[DescSample] MLMultiArray alloc failed: \(error)")
            return Self.makeEmpty(dim: dim)
        }

        var sampled = [Float](repeating: 0, count: dim)

        for i in 0..<n {
            let kp = keypoints[i]
            // desc 좌표 (실수): (u/cell, v/cell)
            let dx = kp.x / cell
            let dy = kp.y / cell
            // 경계 클램프 ([0, descW-1], [0, descH-1])
            let cx = min(max(dx, 0), Float(descW - 1))
            let cy = min(max(dy, 0), Float(descH - 1))

            let x0 = Int(floor(cx))
            let y0 = Int(floor(cy))
            let x1 = min(x0 + 1, descW - 1)
            let y1 = min(y0 + 1, descH - 1)
            let tx = cx - Float(x0)
            let ty = cy - Float(y0)
            let w00 = (1 - tx) * (1 - ty)
            let w10 = tx * (1 - ty)
            let w01 = (1 - tx) * ty
            let w11 = tx * ty

            // 각 채널 c 에 대해 4-tap weighted sum
            for c in 0..<dim {
                let baseC = c * strides[1]
                let v00 = f32[baseC + y0 * strides[2] + x0 * strides[3]]
                let v10 = f32[baseC + y0 * strides[2] + x1 * strides[3]]
                let v01 = f32[baseC + y1 * strides[2] + x0 * strides[3]]
                let v11 = f32[baseC + y1 * strides[2] + x1 * strides[3]]
                sampled[c] = v00 * w00 + v10 * w10 + v01 * w01 + v11 * w11
            }

            // L2 정규화
            var norm: Float = 0
            for c in 0..<dim { norm += sampled[c] * sampled[c] }
            let inv = 1.0 / sqrt(max(norm, 1e-12))
            for c in 0..<dim { sampled[c] *= inv }

            // Float16 으로 quantize 후 array 에 저장
            let rowBase = i * dim
            for c in 0..<dim {
                let f16 = Float16(sampled[c])
                array[rowBase + c] = NSNumber(value: Float(f16))
            }
        }

        return array
    }

    // MARK: - Helpers

    private func float32Buffer(from arr: MLMultiArray) -> [Float] {
        let count = arr.count
        var result = [Float](repeating: 0, count: count)

        switch arr.dataType {
        case .float16:
            arr.dataPointer.withMemoryRebound(to: UInt16.self, capacity: count) { src in
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
            }
        case .float32:
            arr.dataPointer.withMemoryRebound(to: Float.self, capacity: count) { src in
                for i in 0..<count { result[i] = src[i] }
            }
        case .double:
            arr.dataPointer.withMemoryRebound(to: Double.self, capacity: count) { src in
                for i in 0..<count { result[i] = Float(src[i]) }
            }
        default:
            print("[DescSample] unsupported MLMultiArray dataType: \(arr.dataType)")
        }
        return result
    }

    private static func makeEmpty(dim: Int) -> MLMultiArray {
        // 최후 fallback (정상 경로에선 도달하지 않음)
        return try! MLMultiArray(shape: [0, NSNumber(value: dim)], dataType: .float16)
    }
}
