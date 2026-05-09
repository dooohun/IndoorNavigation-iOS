import Foundation
import CoreML
import Accelerate
import simd

/// SuperPoint `desc` 출력 (1, 256, H/8, W/8) 에서 keypoint 위치 별 256-d descriptor 를
/// bilinear sampling 으로 추출. Phase 8·9·10 공통 규약: 256 차원, FP16, L2 정규화.
final class DescriptorSampler {

    struct Config {
        var inputWidth: Int = 960
        var inputHeight: Int = 540
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

        // 결과 array (contiguous: strides = [dim, 1] — MLMultiArray 기본)
        let array: MLMultiArray
        do {
            array = try MLMultiArray(shape: [NSNumber(value: n), NSNumber(value: dim)], dataType: .float16)
        } catch {
            return Self.makeEmpty(dim: dim)
        }
        // dataPointer 직접 Float16 쓰기 — NSNumber 박싱 회피 (~N×256 박싱 → 0).
        // MLMultiArray 는 새로 alloc 시 contiguous 이므로 (i*dim + c) 인덱싱 안전.
        let outPtr = array.dataPointer.bindMemory(to: Float16.self, capacity: n * dim)

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

            // L2 정규화 (Accelerate)
            var sumSq: Float = 0
            vDSP_svesq(sampled, 1, &sumSq, vDSP_Length(dim))
            var inv = Float(1.0 / sqrt(max(sumSq, 1e-12)))
            vDSP_vsmul(sampled, 1, &inv, &sampled, 1, vDSP_Length(dim))

            // Float16 직접 쓰기 (NSNumber 박싱 회피)
            let rowBase = i * dim
            for c in 0..<dim {
                outPtr[rowBase + c] = Float16(sampled[c])
            }
        }

        return array
    }

    // MARK: - Helpers

    /// MLMultiArray → Float32 buffer. strides 기반 인덱싱이 안전하도록
    /// 실제 메모리 element 수만큼 변환한다 (Core ML/ANE 의 padded layout 대응).
    private func float32Buffer(from arr: MLMultiArray) -> [Float] {
        let shape = arr.shape.map { $0.intValue }
        let strides = arr.strides.map { $0.intValue }
        var maxIdx = 0
        for d in 0..<shape.count where shape[d] > 0 {
            maxIdx += (shape[d] - 1) * strides[d]
        }
        let count = maxIdx + 1
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
            break
        }
        return result
    }

    private static func makeEmpty(dim: Int) -> MLMultiArray {
        // 최후 fallback (정상 경로에선 도달하지 않음)
        return try! MLMultiArray(shape: [0, NSNumber(value: dim)], dataType: .float16)
    }
}
