import Testing
import CoreML
import Foundation
@testable import IndoorNavigation_iOS

/// DescriptorMatcher 의 cosine similarity 매칭 + threshold 단위 테스트.
struct DescriptorMatcherTests {

    private let dim = 256

    // MARK: - Helpers

    /// (n, dim) FP16 MLMultiArray. row 별 단위벡터 (L2 정규화) — 첫 채널만 1, 나머지 0.
    /// queryIdx 가 i 면 firstUnitChannel[i] 채널을 1로 설정 가능 (개별 row 제어).
    private func makeUnitVectors(rowChannels: [Int]) -> MLMultiArray {
        let n = rowChannels.count
        let arr = try! MLMultiArray(shape: [NSNumber(value: n), NSNumber(value: dim)],
                                    dataType: .float16)
        let ptr = arr.dataPointer.bindMemory(to: Float16.self, capacity: n * dim)
        for i in 0..<n {
            for c in 0..<dim {
                ptr[i * dim + c] = (c == rowChannels[i]) ? 1.0 : 0.0
            }
        }
        return arr
    }

    /// (n, dim) FP16 raw bytes. 각 row 는 단위벡터 (특정 채널만 1).
    private func makeUnitVectorBytes(rowChannels: [Int]) -> Data {
        let n = rowChannels.count
        var fp16 = [Float16](repeating: 0, count: n * dim)
        for i in 0..<n {
            fp16[i * dim + rowChannels[i]] = 1.0
        }
        return fp16.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - 1) 동일한 단위벡터 → cosine similarity 1.0

    @Test("query 와 reference 가 같은 단위벡터면 score = 1.0")
    func identicalVectorsScore1() {
        let query = makeUnitVectors(rowChannels: [10, 50, 100])
        let refBytes = makeUnitVectorBytes(rowChannels: [10, 50, 100])
        let matches = DescriptorMatcher.matchTop1(
            query: query, referenceBytes: refBytes, referenceCount: 3, threshold: 0.9
        )
        #expect(matches.count == 3)
        for (qi, m) in matches.enumerated() {
            guard let m = m else {
                Issue.record("query[\(qi)] no match")
                continue
            }
            #expect(m.queryIdx == qi)
            #expect(m.refIdx == qi)            // 동일 단위벡터 매칭
            #expect(abs(m.score - 1.0) < 0.01) // FP16 양자화 오차 허용
        }
    }

    // MARK: - 2) 직교 단위벡터 → cosine similarity 0 (threshold 미달 → nil)

    @Test("직교 단위벡터(threshold 미달) → 매칭 nil")
    func orthogonalVectorsBelowThreshold() {
        let query = makeUnitVectors(rowChannels: [0])     // channel 0
        let refBytes = makeUnitVectorBytes(rowChannels: [128]) // channel 128, 직교
        let matches = DescriptorMatcher.matchTop1(
            query: query, referenceBytes: refBytes, referenceCount: 1, threshold: 0.5
        )
        #expect(matches.count == 1)
        #expect(matches[0] == nil, "expected nil (orthogonal score = 0)")
    }

    // MARK: - 3) Q vs R top-1 선택

    @Test("동일 채널이 reference 안에 있으면 그 row 가 top-1")
    func picksTop1FromReference() {
        // query: channel 50
        let query = makeUnitVectors(rowChannels: [50])
        // reference 5개: channel 0, 50, 100, 150, 200. query 와 일치하는 건 idx=1 (channel 50).
        let refBytes = makeUnitVectorBytes(rowChannels: [0, 50, 100, 150, 200])
        let matches = DescriptorMatcher.matchTop1(
            query: query, referenceBytes: refBytes, referenceCount: 5, threshold: 0.9
        )
        #expect(matches.count == 1)
        guard let m = matches[0] else {
            Issue.record("expected match")
            return
        }
        #expect(m.refIdx == 1)
        #expect(abs(m.score - 1.0) < 0.01)
    }

    // MARK: - 4) Stats 계산

    @Test("stats: 매칭 수 / 평균·max·min 점수")
    func statsAggregates() {
        let matches: [DescriptorMatcher.Match?] = [
            DescriptorMatcher.Match(queryIdx: 0, refIdx: 0, score: 0.9),
            nil,
            DescriptorMatcher.Match(queryIdx: 2, refIdx: 1, score: 0.7),
            DescriptorMatcher.Match(queryIdx: 3, refIdx: 2, score: 0.8),
        ]
        let s = DescriptorMatcher.stats(matches: matches, queryCount: 4)
        #expect(s.queryCount == 4)
        #expect(s.matchedCount == 3)
        #expect(abs(s.avgScore - 0.8) < 1e-3)
        #expect(s.maxScore == 0.9)
        #expect(s.minScore == 0.7)
    }

    // MARK: - 5) 잘못된 reference 사이즈 → 빈 결과

    @Test("reference 바이트 사이즈 불일치 → 빈 매칭")
    func mismatchedReferenceSize() {
        let query = makeUnitVectors(rowChannels: [0])
        let badBytes = Data(count: 10) // 너무 작음
        let matches = DescriptorMatcher.matchTop1(
            query: query, referenceBytes: badBytes, referenceCount: 5, threshold: 0.5
        )
        #expect(matches.isEmpty)
    }

    // MARK: - 6) Mock bundle 첫 keyframe 와 sanity 매칭

    @Test("mock bundle 첫 keyframe descriptor 자체와 매칭 → 모두 score=1")
    func selfMatchOnMockBundle() throws {
        let bundle = try MockBundleProvider().loadBundle()
        guard let kf = bundle.keyframes.first,
              let refBytes = Data(base64Encoded: kf.descriptorsB64) else {
            Issue.record("mock bundle 로드/디코딩 실패")
            return
        }
        let n = kf.keypoints.count

        // 같은 descriptor 를 query 로 다시 넣어 자기 자신 매칭 sanity check.
        let queryArr = try MLMultiArray(shape: [NSNumber(value: n), NSNumber(value: dim)],
                                        dataType: .float16)
        let qPtr = queryArr.dataPointer.bindMemory(to: Float16.self, capacity: n * dim)
        refBytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let src = buf.bindMemory(to: Float16.self).baseAddress else { return }
            for i in 0..<(n * dim) { qPtr[i] = src[i] }
        }

        let matches = DescriptorMatcher.matchTop1(
            query: queryArr, referenceBytes: refBytes, referenceCount: n, threshold: 0.95
        )
        #expect(matches.count == n)
        let stats = DescriptorMatcher.stats(matches: matches, queryCount: n)
        // 자기 자신과 매칭이라 모두 매칭 + 평균 점수 ≈ 1.0
        #expect(stats.matchedCount == n, "expected all \(n) matches, got \(stats.matchedCount)")
        #expect(stats.avgScore > 0.99, "self-match avg=\(stats.avgScore)")
    }
}
