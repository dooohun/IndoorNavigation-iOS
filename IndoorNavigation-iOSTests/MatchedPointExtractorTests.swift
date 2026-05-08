import Testing
import Foundation
import simd
@testable import IndoorNavigation_iOS

/// MatchedPointExtractor 의 nil 필터링 + 매칭 인덱스 매핑 단위 테스트.
struct MatchedPointExtractorTests {

    private func makeKeyframe(world3d: [[Float]?]) -> BundleKeyframe {
        // 테스트용 — keypoints / descriptors 는 무시, world_3d 만 검증.
        return BundleKeyframe(
            index: 0,
            pose4x4: [[1,0,0,0], [0,1,0,0], [0,0,1,0], [0,0,0,1]],
            keypoints: world3d.map { _ in [0, 0] },
            descriptorsB64: "",
            world3d: world3d,
            globalDescriptorB64: ""
        )
    }

    @Test("매칭이 없으면 빈 결과")
    func emptyMatchesProducesEmpty() {
        let kf = makeKeyframe(world3d: [[1, 2, 3]])
        let pairs = MatchedPointExtractor.extract(
            matches: [],
            queryKeypoints: [],
            bundleKeyframe: kf
        )
        #expect(pairs.isEmpty)
    }

    @Test("nil match 항목은 제외")
    func skipsNilMatches() {
        let kf = makeKeyframe(world3d: [[1, 2, 3], [4, 5, 6]])
        let queryKp: [SIMD3<Float>] = [
            SIMD3<Float>(100, 50, 0.9),
            SIMD3<Float>(200, 60, 0.8),
            SIMD3<Float>(300, 70, 0.7),
        ]
        let matches: [DescriptorMatcher.Match?] = [
            DescriptorMatcher.Match(queryIdx: 0, refIdx: 0, score: 0.9),
            nil,
            DescriptorMatcher.Match(queryIdx: 2, refIdx: 1, score: 0.8),
        ]
        let pairs = MatchedPointExtractor.extract(
            matches: matches, queryKeypoints: queryKp, bundleKeyframe: kf
        )
        #expect(pairs.count == 2)
        #expect(pairs[0].imagePoint == SIMD2<Float>(100, 50))
        #expect(pairs[0].worldPoint == SIMD3<Float>(1, 2, 3))
        #expect(pairs[1].imagePoint == SIMD2<Float>(300, 70))
        #expect(pairs[1].worldPoint == SIMD3<Float>(4, 5, 6))
    }

    @Test("world_3d 가 nil 인 점은 제외 (multi-view triangulation 실패)")
    func skipsNilWorld3d() {
        let kf = makeKeyframe(world3d: [
            nil,            // ref idx 0 — nil → 제외
            [1, 2, 3],
            nil,            // ref idx 2 — nil → 제외
        ])
        let queryKp: [SIMD3<Float>] = [
            SIMD3<Float>(10, 20, 0.9),
            SIMD3<Float>(30, 40, 0.8),
            SIMD3<Float>(50, 60, 0.7),
        ]
        let matches: [DescriptorMatcher.Match?] = [
            DescriptorMatcher.Match(queryIdx: 0, refIdx: 0, score: 0.9),  // → world nil 제외
            DescriptorMatcher.Match(queryIdx: 1, refIdx: 1, score: 0.85), // 통과
            DescriptorMatcher.Match(queryIdx: 2, refIdx: 2, score: 0.7),  // → world nil 제외
        ]
        let pairs = MatchedPointExtractor.extract(
            matches: matches, queryKeypoints: queryKp, bundleKeyframe: kf
        )
        #expect(pairs.count == 1)
        #expect(pairs[0].imagePoint == SIMD2<Float>(30, 40))
        #expect(pairs[0].worldPoint == SIMD3<Float>(1, 2, 3))
        #expect(pairs[0].matchScore == 0.85)
    }

    @Test("refIdx 범위 초과 시 안전하게 제외")
    func skipsOutOfRangeRefIdx() {
        let kf = makeKeyframe(world3d: [[1, 2, 3]])
        let queryKp = [SIMD3<Float>(0, 0, 0.9)]
        let matches: [DescriptorMatcher.Match?] = [
            DescriptorMatcher.Match(queryIdx: 0, refIdx: 99, score: 0.9), // out of range
        ]
        let pairs = MatchedPointExtractor.extract(
            matches: matches, queryKeypoints: queryKp, bundleKeyframe: kf
        )
        #expect(pairs.isEmpty)
    }

    @Test("queryKeypoints 인덱스 범위 초과 시 안전하게 제외")
    func skipsOutOfRangeQueryIdx() {
        let kf = makeKeyframe(world3d: [[1, 2, 3]])
        let queryKp = [SIMD3<Float>(0, 0, 0.9)]
        // matches.count = 5 인데 queryKp.count = 1 인 비정상 입력
        let matches: [DescriptorMatcher.Match?] = [
            DescriptorMatcher.Match(queryIdx: 0, refIdx: 0, score: 0.9),
            DescriptorMatcher.Match(queryIdx: 1, refIdx: 0, score: 0.85), // qi=1 out of range
            nil, nil, nil
        ]
        let pairs = MatchedPointExtractor.extract(
            matches: matches, queryKeypoints: queryKp, bundleKeyframe: kf
        )
        // qi=0 만 통과
        #expect(pairs.count == 1)
        #expect(pairs[0].imagePoint == SIMD2<Float>(0, 0))
    }

    // MARK: - S3 LightGlue 어댑터 케이스

    @Test("LightGlue compact 매칭 배열을 정상 변환")
    func lightGlueMatchesProducesPairs() {
        let kf = makeKeyframe(world3d: [[1, 2, 3], [4, 5, 6], [7, 8, 9]])
        let queryKp: [SIMD3<Float>] = [
            SIMD3<Float>(10, 20, 0.9),
            SIMD3<Float>(30, 40, 0.8),
            SIMD3<Float>(50, 60, 0.7),
        ]
        // LightGlue 출력은 nil 없는 compact 배열. queryIdx=1 항목은 매칭이 없어 빠진 형태(=2개).
        let matches: [LightGlueMatcherEngine.Match] = [
            LightGlueMatcherEngine.Match(queryIdx: 0, refIdx: 2, score: 0.91),
            LightGlueMatcherEngine.Match(queryIdx: 2, refIdx: 1, score: 0.83),
        ]
        let pairs = MatchedPointExtractor.extract(
            lightGlueMatches: matches, queryKeypoints: queryKp, bundleKeyframe: kf
        )
        #expect(pairs.count == 2)
        #expect(pairs[0].imagePoint == SIMD2<Float>(10, 20))
        #expect(pairs[0].worldPoint == SIMD3<Float>(7, 8, 9))
        #expect(pairs[0].matchScore == 0.91)
        #expect(pairs[1].imagePoint == SIMD2<Float>(50, 60))
        #expect(pairs[1].worldPoint == SIMD3<Float>(4, 5, 6))
    }

    @Test("LightGlue — world_3d 가 nil 인 ref 는 결과에서 제외")
    func lightGlueMatchesFiltersNilWorld3d() {
        let kf = makeKeyframe(world3d: [
            [1, 2, 3],
            nil,            // ref idx 1 — nil → 제외
            [7, 8, 9],
        ])
        let queryKp: [SIMD3<Float>] = [
            SIMD3<Float>(10, 20, 0.9),
            SIMD3<Float>(30, 40, 0.8),
            SIMD3<Float>(50, 60, 0.7),
        ]
        let matches: [LightGlueMatcherEngine.Match] = [
            LightGlueMatcherEngine.Match(queryIdx: 0, refIdx: 0, score: 0.9),  // 통과
            LightGlueMatcherEngine.Match(queryIdx: 1, refIdx: 1, score: 0.85), // → world nil 제외
            LightGlueMatcherEngine.Match(queryIdx: 2, refIdx: 2, score: 0.7),  // 통과
        ]
        let pairs = MatchedPointExtractor.extract(
            lightGlueMatches: matches, queryKeypoints: queryKp, bundleKeyframe: kf
        )
        #expect(pairs.count == 2)
        #expect(pairs[0].imagePoint == SIMD2<Float>(10, 20))
        #expect(pairs[0].worldPoint == SIMD3<Float>(1, 2, 3))
        #expect(pairs[1].imagePoint == SIMD2<Float>(50, 60))
        #expect(pairs[1].worldPoint == SIMD3<Float>(7, 8, 9))
    }

    @Test("LightGlue — refIdx / queryIdx 범위 초과 시 안전하게 제외")
    func lightGlueMatchesIndexBoundsGuard() {
        let kf = makeKeyframe(world3d: [[1, 2, 3]])
        let queryKp: [SIMD3<Float>] = [SIMD3<Float>(10, 20, 0.9)]
        let matches: [LightGlueMatcherEngine.Match] = [
            LightGlueMatcherEngine.Match(queryIdx: 0, refIdx: 99, score: 0.9), // refIdx out of range
            LightGlueMatcherEngine.Match(queryIdx: 5, refIdx: 0, score: 0.85), // queryIdx out of range
            LightGlueMatcherEngine.Match(queryIdx: 0, refIdx: 0, score: 0.7),  // 통과
        ]
        let pairs = MatchedPointExtractor.extract(
            lightGlueMatches: matches, queryKeypoints: queryKp, bundleKeyframe: kf
        )
        #expect(pairs.count == 1)
        #expect(pairs[0].imagePoint == SIMD2<Float>(10, 20))
        #expect(pairs[0].worldPoint == SIMD3<Float>(1, 2, 3))
    }
}
