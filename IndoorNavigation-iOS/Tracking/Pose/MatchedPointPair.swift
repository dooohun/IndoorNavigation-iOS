import Foundation
import simd

/// PnP solver 입력 — 클라 카메라가 본 2D 픽셀 좌표 ↔ 매핑 좌표계의 3D 점.
struct MatchedPointPair {
    /// 클라 추출 키포인트 픽셀 좌표 (SuperPoint 입력 사이즈 기준, 예: 960×536).
    let imagePoint: SIMD2<Float>
    /// bundle keyframe 의 매핑된 3D world 좌표 (m, 매핑 좌표계).
    let worldPoint: SIMD3<Float>
    /// cosine similarity 매칭 점수 — RANSAC 가중치 등에 사용 가능 (선택).
    let matchScore: Float
}

/// `DescriptorMatcher.matchTop1` 결과 + best `BundleKeyframe` 에서 valid 2D-3D 쌍 추출.
/// `world_3d` 가 nil(매핑 시 multi-view triangulation 실패) 인 점은 PnP 입력으로 사용 불가
/// 이므로 제외한다.
enum MatchedPointExtractor {

    /// matches.count == queryKeypoints.count 이어야 함 (matchTop1 의 출력 형태).
    /// nil match 또는 nil world_3d 항목은 결과에서 제외.
    static func extract(
        matches: [DescriptorMatcher.Match?],
        queryKeypoints: [SIMD3<Float>],
        bundleKeyframe: BundleKeyframe
    ) -> [MatchedPointPair] {
        var pairs: [MatchedPointPair] = []
        pairs.reserveCapacity(matches.count)
        let kfWorld = bundleKeyframe.world3d

        for (qi, m) in matches.enumerated() {
            guard let m = m,
                  qi < queryKeypoints.count,
                  m.refIdx >= 0, m.refIdx < kfWorld.count,
                  let w = kfWorld[m.refIdx] else { continue }
            guard w.count == 3 else { continue }

            let kp = queryKeypoints[qi]
            // SuperPointFrame.keypoints 는 SIMD3<Float>(u, v, score). PnP 에는 (u, v) 만 사용.
            pairs.append(MatchedPointPair(
                imagePoint: SIMD2<Float>(kp.x, kp.y),
                worldPoint: SIMD3<Float>(w[0], w[1], w[2]),
                matchScore: m.score
            ))
        }
        return pairs
    }

    /// LightGlue 매처 결과 어댑터. `LightGlueMatcherEngine.match(...)` 가 nil 없는 compact
    /// `[Match]` 를 반환하므로 DescriptorMatcher 어댑터(option array)와 별도 오버로드.
    /// nil world_3d / 인덱스 범위 가드는 동일하게 적용.
    static func extract(
        lightGlueMatches: [LightGlueMatcherEngine.Match],
        queryKeypoints: [SIMD3<Float>],
        bundleKeyframe: BundleKeyframe
    ) -> [MatchedPointPair] {
        var pairs: [MatchedPointPair] = []
        pairs.reserveCapacity(lightGlueMatches.count)
        let kfWorld = bundleKeyframe.world3d

        for m in lightGlueMatches {
            let qi = m.queryIdx
            guard qi >= 0, qi < queryKeypoints.count,
                  m.refIdx >= 0, m.refIdx < kfWorld.count,
                  let w = kfWorld[m.refIdx] else { continue }
            guard w.count == 3 else { continue }

            let kp = queryKeypoints[qi]
            // SuperPointFrame.keypoints 는 SIMD3<Float>(u, v, score). PnP 에는 (u, v) 만 사용.
            pairs.append(MatchedPointPair(
                imagePoint: SIMD2<Float>(kp.x, kp.y),
                worldPoint: SIMD3<Float>(w[0], w[1], w[2]),
                matchScore: m.score
            ))
        }
        return pairs
    }
}
