import Foundation
import CoreML
import Accelerate

/// SuperPoint `semi` 출력을 keypoint (u, v, score) 배열로 디코드.
///
/// 입력: MLMultiArray shape (1, 65, H/8, W/8) FP16. SuperPoint 표준 — 65채널 중
/// 마지막(=index 64) 은 dustbin, 0..63 은 8×8 cell 내부 위치 logits.
///
/// 출력 좌표계: 추론 입력 해상도 (480 wide × 640 tall) 픽셀 좌표.
/// `keypoint = (u, v, score)`, `u ∈ 0..(W-1)`, `v ∈ 0..(H-1)`.
///
/// 디코딩 단계:
///   1. softmax (channel 65)
///   2. dustbin (channel 64) 제거
///   3. 8×8 depth-to-space → full-res heatmap (H × W)
///   4. score < threshold 마스킹
///   5. separable max-pool (반경 r) NMS — 본인 == max 인 픽셀만 후보
///   6. score 내림차순 정렬, 앞 maxK 개 반환
final class SuperPointHeatmapDecoder {

    struct Config {
        var inputWidth: Int = 480
        var inputHeight: Int = 640
        var cellSize: Int = 8
        var dustbinChannelIndex: Int = 64
        var scoreThreshold: Float = 0.005
        var nmsRadiusPx: Int = 4
        var maxKeypoints: Int = 512
    }

    private let config: Config

    init(config: Config = Config()) {
        self.config = config
        precondition(config.inputWidth % config.cellSize == 0)
        precondition(config.inputHeight % config.cellSize == 0)
    }

    /// `semi` MLMultiArray → keypoints. shape 미스매치 시 빈 배열 반환.
    func decode(semi: MLMultiArray) -> [SIMD3<Float>] {
        // 기대 shape: [1, 65, H/8, W/8]
        let shape = semi.shape.map { $0.intValue }
        guard shape.count == 4 else {
            print("[Decode] semi shape rank mismatch: \(shape)")
            return []
        }
        let totalChannels = shape[1]
        let gridH = shape[2]
        let gridW = shape[3]
        let cell = config.cellSize
        let outH = config.inputHeight
        let outW = config.inputWidth
        guard gridH * cell == outH, gridW * cell == outW,
              totalChannels == config.dustbinChannelIndex + 1 else {
            print("[Decode] semi shape mismatch: \(shape) vs expected (1, \(config.dustbinChannelIndex + 1), \(outH / cell), \(outW / cell))")
            return []
        }

        let nonDustChannels = config.dustbinChannelIndex // 64
        let gridCount = gridH * gridW

        // 1. FP16 → FP32 일괄 변환
        let f32 = float32Buffer(from: semi)

        // 2. channel-wise softmax + dustbin 제거 → (gridH, gridW, 64) probabilities
        // 메모리 layout: semi 의 strides 사용해 정확히 인덱싱.
        let strides = semi.strides.map { $0.intValue }
        // strides[0]=N, strides[1]=channel stride, strides[2]=row stride, strides[3]=col stride

        // softmax 결과는 nonDust 채널만 보관 — full heatmap 으로 펼치기 전 단계.
        // 각 grid cell 별로 softmax 수행.
        var cellProbs = [Float](repeating: 0, count: gridCount * nonDustChannels)

        for gy in 0..<gridH {
            for gx in 0..<gridW {
                // 해당 cell 의 65 logit 모으기
                var logits = [Float](repeating: 0, count: totalChannels)
                for c in 0..<totalChannels {
                    let idx = c * strides[1] + gy * strides[2] + gx * strides[3]
                    logits[c] = f32[idx]
                }
                // softmax
                var maxLogit: Float = -.infinity
                for v in logits where v > maxLogit { maxLogit = v }
                var sumExp: Float = 0
                var exps = [Float](repeating: 0, count: totalChannels)
                for c in 0..<totalChannels {
                    let e = expf(logits[c] - maxLogit)
                    exps[c] = e
                    sumExp += e
                }
                let invSum = sumExp > 0 ? (1.0 / sumExp) : 0
                // dustbin 제외 64채널만 보관
                let cellBase = (gy * gridW + gx) * nonDustChannels
                for c in 0..<nonDustChannels {
                    cellProbs[cellBase + c] = exps[c] * invSum
                }
            }
        }

        // 3. 8×8 depth-to-space: cellProbs[gy, gx, c] → heat[gy*8 + (c / 8), gx*8 + (c % 8)]
        var heat = [Float](repeating: 0, count: outH * outW)
        for gy in 0..<gridH {
            for gx in 0..<gridW {
                let cellBase = (gy * gridW + gx) * nonDustChannels
                for c in 0..<nonDustChannels {
                    let dy = c / cell
                    let dx = c % cell
                    let y = gy * cell + dy
                    let x = gx * cell + dx
                    heat[y * outW + x] = cellProbs[cellBase + c]
                }
            }
        }

        // 4. threshold 마스킹 + 5. NMS (separable max-pool)
        let r = max(0, config.nmsRadiusPx)
        let maxMap = separableMaxPool(heat: heat, width: outW, height: outH, radius: r)

        // 6. 후보 추출 (본인 == max 이고 threshold 통과)
        struct Candidate { let u: Int; let v: Int; let score: Float }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(2048)

        let thr = config.scoreThreshold
        for y in 0..<outH {
            let rowBase = y * outW
            for x in 0..<outW {
                let s = heat[rowBase + x]
                if s < thr { continue }
                if s != maxMap[rowBase + x] { continue }
                candidates.append(Candidate(u: x, v: y, score: s))
            }
        }

        // 7. score 내림차순 정렬 + top-K
        candidates.sort { $0.score > $1.score }
        let k = min(candidates.count, config.maxKeypoints)
        var result: [SIMD3<Float>] = []
        result.reserveCapacity(k)
        for i in 0..<k {
            let c = candidates[i]
            result.append(SIMD3<Float>(Float(c.u), Float(c.v), c.score))
        }
        return result
    }

    // MARK: - Helpers

    /// MLMultiArray (.float16) → contiguous Float32 buffer (vImage 사용).
    /// dataType 가 .float32 면 직접 복사.
    private func float32Buffer(from arr: MLMultiArray) -> [Float] {
        let count = arr.count
        var result = [Float](repeating: 0, count: count)

        switch arr.dataType {
        case .float16:
            // Float16 → Float32 일괄 변환 (vImage)
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
            print("[Decode] unsupported MLMultiArray dataType: \(arr.dataType)")
        }
        return result
    }

    /// Separable max-pool: 행 방향 max-pool → 열 방향 max-pool. 결과는 각 픽셀이
    /// (2r+1)×(2r+1) 윈도우 내 최댓값. 본인 == max 인 위치만 NMS 후보.
    private func separableMaxPool(heat: [Float], width: Int, height: Int, radius: Int) -> [Float] {
        if radius <= 0 { return heat }
        let total = width * height

        // 1단계: 각 행에서 [-r, +r] 윈도우 max → rowMax
        var rowMax = [Float](repeating: 0, count: total)
        for y in 0..<height {
            let base = y * width
            for x in 0..<width {
                let lo = max(0, x - radius)
                let hi = min(width - 1, x + radius)
                var m: Float = -.infinity
                for k in lo...hi {
                    let v = heat[base + k]
                    if v > m { m = v }
                }
                rowMax[base + x] = m
            }
        }

        // 2단계: 각 열에서 [-r, +r] 윈도우 max → result
        var result = [Float](repeating: 0, count: total)
        for x in 0..<width {
            for y in 0..<height {
                let lo = max(0, y - radius)
                let hi = min(height - 1, y + radius)
                var m: Float = -.infinity
                for k in lo...hi {
                    let v = rowMax[k * width + x]
                    if v > m { m = v }
                }
                result[y * width + x] = m
            }
        }
        return result
    }
}
