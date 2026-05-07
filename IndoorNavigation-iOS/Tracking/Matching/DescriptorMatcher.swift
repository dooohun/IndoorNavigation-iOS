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
    /// 각 query 의 top-1 reference 매칭 + 점수 임계 적용 결과를 반환.
    ///
    /// - Parameters:
    ///   - query: 클라 SuperPoint descriptors (Q × 256 FP16). DescriptorSampler 산출물.
    ///   - referenceBytes: bundle keyframe descriptors raw bytes (R × 256 FP16).
    ///       BundleKeyframe.descriptorsB64 → Data(base64Encoded:) 로 디코딩한 결과.
    ///   - referenceCount: R (keypoint 수).
    ///   - threshold: top-1 점수 임계 (0..1). 미달 시 매칭 X.
    /// - Returns: 각 query 별 best match (threshold 미달이면 nil) 배열.
    static func matchTop1(
        query: MLMultiArray,
        referenceBytes: Data,
        referenceCount: Int,
        threshold: Float = 0.7
    ) -> [Match?] {
        let dim = 256
        guard query.shape.count == 2,
              query.shape[1].intValue == dim,
              query.dataType == .float16 else {
            print("[Match] query shape/dtype 불일치: \(query.shape), \(query.dataType)")
            return []
        }
        let q = query.shape[0].intValue
        let r = referenceCount
        guard q > 0, r > 0 else { return [] }
        guard referenceBytes.count == r * dim * MemoryLayout<Float16>.size else {
            print("[Match] reference 사이즈 불일치: \(referenceBytes.count) ≠ \(r * dim * 2)")
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

        // 3. 각 query row 의 max 위치 + 점수
        var matches: [Match?] = []
        matches.reserveCapacity(q)
        sim.withUnsafeBufferPointer { simPtr in
            for qi in 0..<q {
                let rowBase = qi * r
                var maxIdx: vDSP_Length = 0
                var maxVal: Float = 0
                vDSP_maxvi(simPtr.baseAddress!.advanced(by: rowBase), 1,
                           &maxVal, &maxIdx, vDSP_Length(r))
                if maxVal >= threshold {
                    matches.append(Match(queryIdx: qi, refIdx: Int(maxIdx), score: maxVal))
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
