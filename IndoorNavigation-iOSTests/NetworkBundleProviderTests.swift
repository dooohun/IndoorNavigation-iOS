import Testing
import Foundation
@testable import IndoorNavigation_iOS

/// Phase 8 S2 — `LookupResponse → LocalizationBundle` 어댑터 + `NetworkBundleProvider`
/// 캐시 동작 단위 테스트. 네트워크 호출 자체는 검증하지 않는다.
struct NetworkBundleProviderTests {

    // MARK: - 합성 헬퍼

    private static let kpCount = 5
    private static let descDim = 256
    private static let globalDim = 384
    private static let width = 960
    private static let height = 540

    /// (5, 2) FP32 LE keypoints base64. 픽셀 좌표 (i, i*2).
    private static func makeKeypointsB64(count: Int = kpCount, multiplier: Float = 1.0) -> String {
        var arr = [Float32]()
        arr.reserveCapacity(count * 2)
        for i in 0..<count {
            arr.append(Float(i) * multiplier)
            arr.append(Float(i * 2) * multiplier)
        }
        let data = arr.withUnsafeBufferPointer { Data(buffer: $0) }
        return data.base64EncodedString()
    }

    /// 잘못된 byte 길이의 keypoints base64 (count*2*4 - 1 bytes).
    private static func makeKeypointsB64Truncated(count: Int = kpCount) -> String {
        let expected = count * 2 * MemoryLayout<Float32>.size
        let data = Data(repeating: 0, count: expected - 1)
        return data.base64EncodedString()
    }

    /// (5, 3) FP32 LE world3d base64. nanRows 인덱스는 NaN 으로.
    private static func makeWorld3dB64(count: Int = kpCount, nanRows: Set<Int> = []) -> String {
        var arr = [Float32]()
        arr.reserveCapacity(count * 3)
        for i in 0..<count {
            if nanRows.contains(i) {
                arr.append(.nan); arr.append(.nan); arr.append(.nan)
            } else {
                arr.append(Float(i)); arr.append(Float(i) + 0.1); arr.append(Float(i) + 0.2)
            }
        }
        let data = arr.withUnsafeBufferPointer { Data(buffer: $0) }
        return data.base64EncodedString()
    }

    /// (count, descDim) FP16 row-major base64. row 별 채널 i 만 1.0.
    private static func makeDescriptorsB64(count: Int = kpCount) -> String {
        var fp16 = [Float16](repeating: 0, count: count * descDim)
        for i in 0..<count {
            fp16[i * descDim + (i % descDim)] = 1.0
        }
        let data = fp16.withUnsafeBufferPointer { Data(buffer: $0) }
        return data.base64EncodedString()
    }

    /// (384,) FP16 base64. 단순 패턴 (0번 채널만 1).
    private static func makeGlobalDescriptorB64() -> String {
        var fp16 = [Float16](repeating: 0, count: globalDim)
        fp16[0] = 1.0
        let data = fp16.withUnsafeBufferPointer { Data(buffer: $0) }
        return data.base64EncodedString()
    }

    /// 단위 4×4 pose.
    private static func identityPose() -> [[Double]] {
        return [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0, 0, 1, 0],
            [0, 0, 0, 1],
        ]
    }

    /// 표준 합성 keyframe 한 개.
    private static func makeKeyframe(kfId: String = "kf-0",
                                     scanId: String = "scan-A",
                                     floorLevel: Int = 3,
                                     fx: Double = 600,
                                     world3dNanRows: Set<Int> = [],
                                     keypointMultiplier: Float = 1.0) -> LookupKeyframe {
        let intr = KeyframeIntrinsics(
            fx: fx, fy: 600, cx: 480, cy: 270,
            width: width, height: height
        )
        return LookupKeyframe(
            kfId: kfId,
            scanId: scanId,
            floorLevel: floorLevel,
            rtabmapNodeId: 0,
            pose: identityPose(),
            intrinsics: intr,
            matchedQueryIndices: [0],
            distancesM: [0.0],
            keypointCount: kpCount,
            keypoints: makeKeypointsB64(multiplier: keypointMultiplier),
            descriptors: makeDescriptorsB64(),
            world3d: makeWorld3dB64(nanRows: world3dNanRows),
            globalDescriptor: makeGlobalDescriptorB64()
        )
    }

    /// keyframeCount 개 keyframe 을 가진 합성 LookupResponse.
    private static func makeSyntheticLookupResponse(
        keyframeCount: Int,
        world3dNanRows: Set<Int> = [],
        heterogeneousIntrinsics: Bool = false
    ) -> LookupResponse {
        var kfs: [LookupKeyframe] = []
        for i in 0..<keyframeCount {
            let fx: Double = (heterogeneousIntrinsics && i == 1) ? 700 : 600
            kfs.append(makeKeyframe(
                kfId: "kf-\(i)",
                scanId: "scan-A",
                fx: fx,
                world3dNanRows: world3dNanRows
            ))
        }
        let model = LookupModel(
            extractor: "superpoint_v1",
            matcher: "superpoint_lightglue",
            descriptorDim: descDim,
            maxKeypoints: 1024,
            descriptorDtype: "float16",
            globalDescriptorDim: globalDim,
            globalDescriptorExtractor: "dinov2"
        )
        let stats = LookupStats(
            queryCount: 1,
            keyframeCount: keyframeCount,
            totalKeypoints: kpCount * keyframeCount,
            byteSize: 0
        )
        return LookupResponse(
            buildingId: "test-building",
            keyframes: kfs,
            model: model,
            stats: stats
        )
    }

    // MARK: - 1) 기본 어댑팅

    @Test("toLocalizationBundle: keyframeCount/intrinsics/keypoints.count 정상 매핑")
    func toLocalizationBundle_basic() throws {
        let resp = Self.makeSyntheticLookupResponse(keyframeCount: 2)
        let bundle = try resp.toLocalizationBundle(destination: "")

        #expect(bundle.manifest.keyframeCount == 2)
        #expect(bundle.keyframes.count == 2)
        #expect(bundle.manifest.intrinsics.width == Self.width)
        #expect(bundle.manifest.intrinsics.height == Self.height)
        #expect(bundle.manifest.intrinsics.fx == 600)
        #expect(bundle.manifest.floorLevel == 3)
        #expect(bundle.manifest.scanId == "scan-A")
        #expect(bundle.manifest.version == "lookup-v1")

        // keypoints 디코딩 (5점, 2D)
        #expect(bundle.keyframes[0].keypoints.count == Self.kpCount)
        #expect(bundle.keyframes[0].keypoints[0].count == 2)
        // 첫 점 (0,0), 두번째 (1,2)
        #expect(bundle.keyframes[0].keypoints[0] == [0, 0])
        #expect(bundle.keyframes[0].keypoints[1] == [1, 2])
    }

    // MARK: - 2) world3d NaN row → nil

    @Test("toLocalizationBundle: world3d NaN row 는 nil 로 디코드")
    func toLocalizationBundle_world3dNullDecoded() throws {
        let resp = Self.makeSyntheticLookupResponse(keyframeCount: 1, world3dNanRows: [1, 3])
        let bundle = try resp.toLocalizationBundle(destination: "")
        let w = bundle.keyframes[0].world3d
        #expect(w.count == Self.kpCount)
        #expect(w[0] != nil)
        #expect(w[1] == nil)
        #expect(w[2] != nil)
        #expect(w[3] == nil)
        #expect(w[4] != nil)
        // 정상 row 값 확인
        #expect(w[0]?.count == 3)
        #expect(w[0]?[0] == 0)
    }

    // MARK: - 3) 빈 keyframes throw

    @Test("toLocalizationBundle: keyframes 빈 배열이면 adaptationFailed throw")
    func toLocalizationBundle_emptyKeyframesThrows() {
        let resp = Self.makeSyntheticLookupResponse(keyframeCount: 0)
        #expect(throws: LookupAdaptationError.self) {
            _ = try resp.toLocalizationBundle(destination: "")
        }
    }

    // MARK: - 4) intrinsics 불일치 throw

    @Test("toLocalizationBundle: keyframe 별 intrinsics 다르면 throw")
    func toLocalizationBundle_heterogeneousIntrinsicsThrows() {
        let resp = Self.makeSyntheticLookupResponse(keyframeCount: 2, heterogeneousIntrinsics: true)
        #expect(throws: LookupAdaptationError.self) {
            _ = try resp.toLocalizationBundle(destination: "")
        }
    }

    // MARK: - 5) destination override

    @Test("toLocalizationBundle: destination 파라미터가 manifest 에 주입")
    func toLocalizationBundle_destinationOverride() throws {
        let resp = Self.makeSyntheticLookupResponse(keyframeCount: 1)
        let bundle = try resp.toLocalizationBundle(destination: "201호")
        #expect(bundle.manifest.destination == "201호")
    }

    // MARK: - 6) loadBundle before fetch → notLoaded

    @Test("loadBundle: fetch 전 호출하면 notLoaded throw")
    func loadBundle_beforeFetchThrows() {
        let provider = NetworkBundleProvider(
            buildingId: "x",
            queryPoints: [NetworkBundleProvider.QueryPoint(floorLevel: 0, x: 0, y: 0, z: 0)]
        )
        #expect(throws: NetworkBundleProvider.NetworkBundleError.self) {
            _ = try provider.loadBundle()
        }
    }

    // MARK: - 7) keypoints byte size mismatch

    @Test("decodeKeypointsBase64: byte 길이 미스매치면 throw")
    func keypointsBase64Decode_sizeMismatchThrows() {
        // 잘못된 길이의 keypoints base64 가 들어간 keyframe 생성
        let intr = KeyframeIntrinsics(fx: 600, fy: 600, cx: 480, cy: 270,
                                      width: Self.width, height: Self.height)
        let badKf = LookupKeyframe(
            kfId: "kf-0",
            scanId: "scan-A",
            floorLevel: 3,
            rtabmapNodeId: 0,
            pose: Self.identityPose(),
            intrinsics: intr,
            matchedQueryIndices: [0],
            distancesM: [0.0],
            keypointCount: Self.kpCount,
            keypoints: Self.makeKeypointsB64Truncated(),  // ← 잘못된 길이
            descriptors: Self.makeDescriptorsB64(),
            world3d: Self.makeWorld3dB64(),
            globalDescriptor: Self.makeGlobalDescriptorB64()
        )
        let model = LookupModel(
            extractor: "superpoint_v1", matcher: "superpoint_lightglue",
            descriptorDim: Self.descDim, maxKeypoints: 1024,
            descriptorDtype: "float16", globalDescriptorDim: Self.globalDim,
            globalDescriptorExtractor: "dinov2"
        )
        let stats = LookupStats(queryCount: 1, keyframeCount: 1, totalKeypoints: Self.kpCount, byteSize: 0)
        let resp = LookupResponse(buildingId: "x", keyframes: [badKf], model: model, stats: stats)

        #expect(throws: LookupAdaptationError.self) {
            _ = try resp.toLocalizationBundle(destination: "")
        }
    }
}
