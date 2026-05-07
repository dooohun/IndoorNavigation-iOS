import Testing
import Foundation
@testable import IndoorNavigation_iOS

/// MockBundleProvider 가 앱 번들의 mock_bundle.json 을 정확히 디코딩하는지 검증.
struct MockBundleProviderTests {

    @Test("mock_bundle.json 로드 + manifest 핵심 필드")
    func loadsManifest() throws {
        let provider = MockBundleProvider()
        let bundle = try provider.loadBundle()
        // 매핑 시점 카메라 사이즈 (서버 합의 — 클라 추출 입력과 동일)
        #expect(bundle.manifest.intrinsics.width == 960)
        #expect(bundle.manifest.intrinsics.height == 540)
        #expect(bundle.manifest.floorLevel == 3)
        #expect(!bundle.manifest.destination.isEmpty)
        // local_transform 은 3×4 행렬
        #expect(bundle.manifest.localTransform3x4.count == 3)
        #expect(bundle.manifest.localTransform3x4.first?.count == 4)
    }

    @Test("keyframe 5개 (mock --limit 5)")
    func loadsAllKeyframes() throws {
        let bundle = try MockBundleProvider().loadBundle()
        #expect(bundle.keyframes.count == 5)
        for (i, kf) in bundle.keyframes.enumerated() {
            #expect(kf.index == i)
            // pose 는 4×4 homogeneous
            #expect(kf.pose4x4.count == 4)
            #expect(kf.pose4x4.last == [0.0, 0.0, 0.0, 1.0])
        }
    }

    @Test("descriptors base64 → FP16 (N, 256) 사이즈 일치")
    func descriptorBytesMatchKeypointCount() throws {
        let bundle = try MockBundleProvider().loadBundle()
        guard let kf = bundle.keyframes.first else {
            Issue.record("no keyframe")
            return
        }
        let n = kf.keypoints.count
        let dim = 256
        guard let descBytes = Data(base64Encoded: kf.descriptorsB64) else {
            Issue.record("descriptors_b64 디코딩 실패")
            return
        }
        // FP16 = 2 bytes. (N, 256) → N * 256 * 2
        #expect(descBytes.count == n * dim * MemoryLayout<Float16>.size)
    }

    @Test("descriptors L2 norm ≈ 1.0 (서버 lightglue 정규화 보존)")
    func descriptorL2NormPreserved() throws {
        let bundle = try MockBundleProvider().loadBundle()
        guard let kf = bundle.keyframes.first,
              let descBytes = Data(base64Encoded: kf.descriptorsB64) else {
            Issue.record("base64 디코딩 실패")
            return
        }
        let n = kf.keypoints.count
        let dim = 256
        // 첫 row 의 L2 norm 확인 (Float16 양자화 오차 ±1e-2 허용)
        descBytes.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.bindMemory(to: Float16.self).baseAddress else {
                Issue.record("Float16 바인드 실패")
                return
            }
            var sumSq: Float = 0
            for c in 0..<dim {
                let v = Float(base[c])
                sumSq += v * v
            }
            let norm = sumSq.squareRoot()
            #expect(abs(norm - 1.0) < 0.02, "first row L2 norm = \(norm), n=\(n)")
        }
    }

    @Test("world_3d 일부는 null (multi-view triangulation 실패 점)")
    func world3dContainsNulls() throws {
        let bundle = try MockBundleProvider().loadBundle()
        guard let kf = bundle.keyframes.first else {
            Issue.record("no keyframe")
            return
        }
        let nullCount = kf.world3d.filter { $0 == nil }.count
        // 서버 매핑 npz 에서 첫 keyframe 은 모두 NaN (mock 변환 시 null 로)
        #expect(nullCount > 0, "expected some null entries in world_3d")
    }

    @Test("global_descriptor 384 dim FP16")
    func globalDescriptorSize() throws {
        let bundle = try MockBundleProvider().loadBundle()
        guard let kf = bundle.keyframes.first,
              let bytes = Data(base64Encoded: kf.globalDescriptorB64) else {
            Issue.record("global_descriptor 디코딩 실패")
            return
        }
        // 384 × 2 bytes
        #expect(bytes.count == 384 * MemoryLayout<Float16>.size)
    }
}
