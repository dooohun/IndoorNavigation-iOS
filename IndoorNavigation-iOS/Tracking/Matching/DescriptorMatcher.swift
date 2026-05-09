import Foundation
import CoreML
import Accelerate

/// L2 정규화된 descriptor 두 집합의 cosine similarity 매칭.
///
/// 입력은 query (Q×256, FP16) 와 reference (R×256, FP16). 둘 다 L2 정규화된
/// 가정 (서버 lightglue + 클라 SuperPoint 모두 정규화 보장). 정규화 vector 의
/// cosine similarity = dot product 이므로 행렬곱 한 번으로 (Q, R) similarity
/// matrix 계산. 각 query 별 best match (top-1) 와 점수 반환.
///
/// 운영 단계에서는 LightGlue 같은 학습된 매처로 교체. mock 단계에선 nearest
/// neighbor + ratio test 로 sanity check.
final class DescriptorMatcher {

    struct Match {
        /// query descriptor index
        let queryIdx: Int
        /// reference descriptor index
        let refIdx: Int
        /// cosine similarity (L2 정규화된 vector → [-1, 1])
        let score: Float
    }

    struct Stats {
        /// query 총 개수
        let queryCount: Int
        /// threshold 통과한 매칭 수
        let matchedCount: Int
        /// 매칭된 점들의 평균 점수
        let avgScore: Float
        /// top-1 점수의 max
        let maxScore: Float
        /// top-1 점수의 min
        let minScore: Float
    }

    /// query (Q, 256) 와 reference (R, 256) 의 cosine similarity 계산.
    /// 각 query 의 top-1 reference 매칭 + (선택) Lowe's ratio test 적용 결과 반환.
    ///
    /// - Parameters:
    ///   - query: 클라 SuperPoint descriptors (Q × 256 FP16).
    ///   - referenceBytes: bundle keyframe descriptors raw bytes (R × 256 FP16).
    ///   - referenceCount: R (keypoint 수).
    ///   - threshold: top-1 점수 절대 임계 (0..1). 미달 시 매칭 X.
    ///   - ratio: Lowe's ratio test — top-1 / top-2 가 본 값보다 커야 매칭 인정.
    ///       1.0 = 효과 없음 (모든 best 통과). 1.3 = best 가 second 보다 30% 이상
    ///       우월해야 — false positive 강력 제거. 1.5+ 더 엄격.
    /// - Returns: 각 query 별 best match (실패 시 nil) 배열.
    static func matchTop1(
        query: MLMultiArray,
        referenceBytes: Data,
        referenceCount: Int,
        threshold: Float = 0.7,
        ratio: Float = 1.0
    ) -> [Match?] {
        let dim = 256
        guard query.shape.count == 2,
              query.shape[1].intValue == dim,
              query.dataType == .float16 else {
            return []
        }
        let q = query.shape[0].intValue
        let r = referenceCount
        guard q > 0, r > 0 else { return [] }
        guard referenceBytes.count == r * dim * MemoryLayout<Float16>.size else {
            return []
        }

        // 1. FP16 → FP32 일괄 변환 (vImage). vDSP_mmul 은 Float32 만 지원.
        let queryF32 = float32Array(fromFP16: query.dataPointer, count: q * dim)
        let refF32 = referenceBytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> [Float] in
            guard let base = buf.baseAddress else { return [] }
            return float32Array(fromFP16: UnsafeMutableRawPointer(mutating: base), count: r * dim)
        }
        guard !queryF32.isEmpty, !refF32.isEmpty else { return [] }

        // 2. similarity = query @ reference.T → (Q, R)
        // vDSP_mmul: C[M×N] = A[M×P] * B[P×N]. 여기서 A=query (Q×D), B=ref.T (D×R) 필요.
        // refF32 가 (R, D) row-major 이므로 transpose 해서 (D, R) 만들어야 함.
        var refT = [Float](repeating: 0, count: dim * r)
        // refF32[i, j] (R×D row-major, idx = i*D+j) → refT[j, i] (D×R row-major, idx = j*R+i)
        // vDSP_mtrans 활용: src (R, D) → dst (D, R)
        refF32.withUnsafeBufferPointer { srcPtr in
            refT.withUnsafeMutableBufferPointer { dstPtr in
                vDSP_mtrans(
                    srcPtr.baseAddress!, 1,
                    dstPtr.baseAddress!, 1,
                    vDSP_Length(dim), vDSP_Length(r)
                )
            }
        }

        var sim = [Float](repeating: 0, count: q * r)
        queryF32.withUnsafeBufferPointer { aPtr in
            refT.withUnsafeBufferPointer { bPtr in
                sim.withUnsafeMutableBufferPointer { cPtr in
                    vDSP_mmul(
                        aPtr.baseAddress!, 1,
                        bPtr.baseAddress!, 1,
                        cPtr.baseAddress!, 1,
                        vDSP_Length(q), vDSP_Length(r), vDSP_Length(dim)
                    )
                }
            }
        }

        // 3. 각 query row 의 top-1 + top-2 위치/점수 (ratio test 위해 top-2 필요)
        var matches: [Match?] = []
        matches.reserveCapacity(q)
        sim.withUnsafeBufferPointer { simPtr in
            let base = simPtr.baseAddress!
            for qi in 0..<q {
                let rowBase = qi * r
                var max1: Float = -.infinity
                var max2: Float = -.infinity
                var maxIdx1: Int = -1
                for ri in 0..<r {
                    let s = base[rowBase + ri]
                    if s > max1 {
                        max2 = max1
                        max1 = s
                        maxIdx1 = ri
                    } else if s > max2 {
                        max2 = s
                    }
                }
                guard max1 >= threshold, maxIdx1 >= 0 else {
                    matches.append(nil)
                    continue
                }
                // Lowe's ratio test: top-1 / top-2 > ratio (top-2 ~ 0 이면 무조건 통과)
                let ratioOK: Bool = (max2 <= 1e-6) || (max1 / max2 >= ratio)
                if ratioOK {
                    matches.append(Match(queryIdx: qi, refIdx: maxIdx1, score: max1))
                } else {
                    matches.append(nil)
                }
            }
        }
        return matches
    }

    /// 매칭 결과 통계 (디버그 HUD 등에 표시).
    static func stats(matches: [Match?], queryCount: Int) -> Stats {
        let valid = matches.compactMap { $0 }
        guard !valid.isEmpty else {
            return Stats(queryCount: queryCount, matchedCount: 0, avgScore: 0, maxScore: 0, minScore: 0)
        }
        let scores = valid.map { $0.score }
        let avg = scores.reduce(0, +) / Float(scores.count)
        let mx = scores.max() ?? 0
        let mn = scores.min() ?? 0
        return Stats(queryCount: queryCount, matchedCount: valid.count,
                     avgScore: avg, maxScore: mx, minScore: mn)
    }

    // MARK: - Helpers

    /// FP16 raw 메모리 → Float32 [count] 변환 (vImage 일괄).
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
