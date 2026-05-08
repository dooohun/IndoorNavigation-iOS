import Foundation
import simd

/// RANSAC 기반 robust PnP. DLTPnPSolver 를 wrapping 해 outlier 매칭에 면역성 추가.
///
/// 알고리즘 (표준 RANSAC):
/// 1. N 회 반복 (`iterations`):
///    a. 무작위 6 점 (DLT 최소 sample) sampling
///    b. 6 점으로 DLT 풀이 → 후보 pose
///    c. 모든 점에 대해 재투영 오차 계산 → reproj < `inlierThresholdPx` 인 점 = inlier
///    d. inlier 수 가장 많은 후보 보관
/// 2. best inlier set (≥ `minInliers`) 으로 다시 DLT 풀이 → 최종 pose
///
/// outlier 비율 50% 까지 견딤 (iter 200 기준 ~99% 신뢰). DLT 단독 대비 reproj 폭주 차단.
final class RansacPnPSolver: PnPSolving {

    let iterations: Int
    let inlierThresholdPx: Float
    let minInliers: Int
    private let minSampleSize = 6
    private let baseSolver: DLTPnPSolver

    /// - iterations: RANSAC 반복 수. 200 = outlier 50% 까지 99% 신뢰. 50/100 도 충분히 효과 있음
    /// - inlierThresholdPx: reproj 임계 (해당 점이 inlier 인지). 일반적 5px, noisy 환경 10px
    /// - minInliers: 최종 inlier 수가 이 미만이면 신뢰 불가 → nil 반환
    init(iterations: Int = 100, inlierThresholdPx: Float = 5.0, minInliers: Int = 12) {
        self.iterations = iterations
        self.inlierThresholdPx = inlierThresholdPx
        self.minInliers = minInliers
        self.baseSolver = DLTPnPSolver()
    }

    func solve(
        objectPoints: [SIMD3<Float>],
        imagePoints: [SIMD2<Float>],
        intrinsics: simd_float3x3
    ) -> PoseEstimate? {
        guard objectPoints.count == imagePoints.count,
              objectPoints.count >= minSampleSize else { return nil }
        let n = objectPoints.count

        var bestInlierIdx: [Int] = []
        var bestCandidate: PoseEstimate?

        var indexBuffer = Array(0..<n)
        for _ in 0..<iterations {
            // 6 점 random sample (Fisher-Yates partial shuffle)
            for k in 0..<minSampleSize {
                let r = k + Int.random(in: 0..<(n - k))
                indexBuffer.swapAt(k, r)
            }
            let sampleIdx = Array(indexBuffer.prefix(minSampleSize))
            let sObj = sampleIdx.map { objectPoints[$0] }
            let sImg = sampleIdx.map { imagePoints[$0] }

            guard let candidate = baseSolver.solve(
                objectPoints: sObj, imagePoints: sImg, intrinsics: intrinsics
            ) else { continue }

            let inliers = computeInliers(
                pose: candidate,
                objectPoints: objectPoints,
                imagePoints: imagePoints,
                intrinsics: intrinsics,
                threshold: inlierThresholdPx
            )
            if inliers.count > bestInlierIdx.count {
                bestInlierIdx = inliers
                bestCandidate = candidate
            }
        }

        guard bestInlierIdx.count >= minInliers else {
            // 실패 진단 — best inlier 수가 0 이면 모든 candidate 의 reproj 가 threshold 초과.
            // 즉 intrinsics 불일치 또는 매칭 outlier 매우 높음. threshold 완화 또는 K 정확화 필요.
            print("[RANSAC] inlier insufficient — best=\(bestInlierIdx.count), required=\(minInliers), threshold=\(inlierThresholdPx)px")
            return nil
        }

        // 최종 refit — inlier-only 로 다시 DLT
        let finalObj = bestInlierIdx.map { objectPoints[$0] }
        let finalImg = bestInlierIdx.map { imagePoints[$0] }
        if let refined = baseSolver.solve(
            objectPoints: finalObj, imagePoints: finalImg, intrinsics: intrinsics
        ) {
            return refined
        }
        // refit 실패 시 RANSAC best 후보 (그래도 inlier-검증된 것) 반환
        return bestCandidate
    }

    // MARK: - Helpers

    /// pose 로 모든 objectPoints 를 카메라에 투영 후, imagePoint 와의 거리(px) 가
    /// threshold 미만인 점들의 인덱스 반환.
    private func computeInliers(
        pose: PoseEstimate,
        objectPoints: [SIMD3<Float>],
        imagePoints: [SIMD2<Float>],
        intrinsics: simd_float3x3,
        threshold: Float
    ) -> [Int] {
        var inliers: [Int] = []
        inliers.reserveCapacity(objectPoints.count)
        for i in 0..<objectPoints.count {
            let Xc = pose.rotation * objectPoints[i] + pose.translation
            if Xc.z <= 1e-6 { continue }       // 카메라 뒤쪽 점 — outlier
            let projNorm = SIMD2<Float>(Xc.x / Xc.z, Xc.y / Xc.z)
            let projHom = intrinsics * SIMD3<Float>(projNorm.x, projNorm.y, 1)
            if abs(projHom.z) < 1e-8 { continue }
            let projPx = SIMD2<Float>(projHom.x / projHom.z, projHom.y / projHom.z)
            let err = simd_distance(projPx, imagePoints[i])
            if err < threshold { inliers.append(i) }
        }
        return inliers
    }
}
