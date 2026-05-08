#if DEBUG
import Testing
import CoreML
import Foundation
import simd
@testable import IndoorNavigation_iOS

/// `SuperPointFrameDumper.encode(...)` 의 직렬화 정책 단위 테스트.
/// 파일 IO 우회 — encode 만 단위 검증한다 (writeDump 는 통합 테스트 영역).
struct SuperPointFrameDumperTests {

    private let dim = 256

    // MARK: - Helpers

    /// (n, 256) FP16 MLMultiArray. row 별 firstChannel 만 1.0, 나머지 0.0.
    private func makeUnitDescriptors(rowChannels: [Int]) -> MLMultiArray {
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

    /// 더미 intrinsics (fx=600, fy=600, cx=480, cy=270, 960×540).
    private var dummyIntrinsics: simd_float3x3 {
        // simd_float3x3 column-major: m[col][row]
        // K = [[fx, 0, cx], [0, fy, cy], [0, 0, 1]]  (row-major 통상 표기)
        // → m[0][0]=fx, m[1][1]=fy, m[2][0]=cx, m[2][1]=cy, m[2][2]=1
        return simd_float3x3(columns: (
            SIMD3<Float>(600, 0, 0),
            SIMD3<Float>(0, 600, 0),
            SIMD3<Float>(480, 270, 1)
        ))
    }

    private func makeFrame(
        keypoints: [SIMD3<Float>],
        descriptors: MLMultiArray,
        intrinsics: simd_float3x3? = nil,
        inputSize: CGSize = CGSize(width: 960, height: 540)
    ) -> SuperPointFrame {
        return SuperPointFrame(
            intrinsics: intrinsics ?? dummyIntrinsics,
            timestamp: 1000.0,
            keypoints: keypoints,
            descriptors: descriptors,
            inputSize: inputSize
        )
    }

    private func decodeJSON(_ data: Data) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = obj as? [String: Any] else {
            throw NSError(domain: "test", code: -1, userInfo: [NSLocalizedDescriptionKey: "not a dict"])
        }
        return dict
    }

    // MARK: - 1) descriptor base64 round-trip

    @Test("descriptor base64 round-trip — FP16 raw bytes 길이 일치 + 첫 채널 ≈ 1.0")
    func descriptorBase64RoundTrip() throws {
        let n = 3
        let descriptors = makeUnitDescriptors(rowChannels: [0, 0, 0]) // 모든 row: channel 0 = 1
        let frame = makeFrame(
            keypoints: [
                SIMD3<Float>(10, 20, 0.5),
                SIMD3<Float>(30, 40, 0.6),
                SIMD3<Float>(50, 60, 0.7)
            ],
            descriptors: descriptors
        )

        let data = try SuperPointFrameDumper.encode(
            frame: frame, arPose: nil, orientation: "landscape", date: Date()
        )
        let json = try decodeJSON(data)

        guard let b64 = json["descriptors_b64"] as? String else {
            Issue.record("descriptors_b64 missing")
            return
        }
        guard let decoded = Data(base64Encoded: b64) else {
            Issue.record("base64 디코딩 실패")
            return
        }
        // 길이 = N * 256 * sizeof(Float16) = 3 * 256 * 2 = 1536 bytes
        #expect(decoded.count == n * 256 * MemoryLayout<Float16>.size)

        // 첫 row 첫 채널 ≈ 1.0
        let firstChannelValue: Float = decoded.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> Float in
            guard let base = buf.bindMemory(to: Float16.self).baseAddress else { return 0 }
            return Float(base[0])
        }
        #expect(abs(firstChannelValue - 1.0) < 0.01)
    }

    // MARK: - 2) keypoints (u, v) 만 직렬화 — score 제외

    @Test("keypoints 는 (u, v) 만 직렬화하고 score 는 제외")
    func keypointsOnlyUV() throws {
        let descriptors = makeUnitDescriptors(rowChannels: [0])
        let frame = makeFrame(
            keypoints: [SIMD3<Float>(10, 20, 0.7)],
            descriptors: descriptors
        )
        let data = try SuperPointFrameDumper.encode(
            frame: frame, arPose: nil, orientation: "portrait", date: Date()
        )
        let json = try decodeJSON(data)

        guard let kps = json["keypoints"] as? [[Any]] else {
            Issue.record("keypoints array missing")
            return
        }
        #expect(kps.count == 1)
        #expect(kps[0].count == 2)
        let u = (kps[0][0] as? NSNumber)?.floatValue ?? 0
        let v = (kps[0][1] as? NSNumber)?.floatValue ?? 0
        #expect(abs(u - 10.0) < 1e-4)
        #expect(abs(v - 20.0) < 1e-4)
    }

    // MARK: - 3) intrinsics 매핑 (fx/fy/cx/cy/width/height)

    @Test("intrinsics 매핑 — simd_float3x3 column-major → fx/fy/cx/cy 정확히 추출")
    func intrinsicsMapping() throws {
        let descriptors = makeUnitDescriptors(rowChannels: [0])
        let frame = makeFrame(
            keypoints: [SIMD3<Float>(0, 0, 1.0)],
            descriptors: descriptors,
            intrinsics: simd_float3x3(columns: (
                SIMD3<Float>(700, 0, 0),
                SIMD3<Float>(0, 710, 0),
                SIMD3<Float>(320, 240, 1)
            )),
            inputSize: CGSize(width: 640, height: 480)
        )
        let data = try SuperPointFrameDumper.encode(
            frame: frame, arPose: nil, orientation: "landscape", date: Date()
        )
        let json = try decodeJSON(data)

        guard let intrinsics = json["intrinsics"] as? [String: Any] else {
            Issue.record("intrinsics dict missing")
            return
        }
        #expect((intrinsics["fx"] as? NSNumber)?.floatValue == 700)
        #expect((intrinsics["fy"] as? NSNumber)?.floatValue == 710)
        #expect((intrinsics["cx"] as? NSNumber)?.floatValue == 320)
        #expect((intrinsics["cy"] as? NSNumber)?.floatValue == 240)
        #expect((intrinsics["width"] as? NSNumber)?.intValue == 640)
        #expect((intrinsics["height"] as? NSNumber)?.intValue == 480)
    }

    // MARK: - 4) ar_pose nil → JSON null

    @Test("arPose nil 시 ar_pose_4x4 는 JSON null")
    func arPoseNilSerializesNull() throws {
        let descriptors = makeUnitDescriptors(rowChannels: [0])
        let frame = makeFrame(
            keypoints: [SIMD3<Float>(0, 0, 1.0)],
            descriptors: descriptors
        )
        let data = try SuperPointFrameDumper.encode(
            frame: frame, arPose: nil, orientation: "landscape", date: Date()
        )
        // JSONSerialization 은 null 을 NSNull 로 매핑
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        guard let dict = obj as? [String: Any] else {
            Issue.record("not a dict")
            return
        }
        // key 자체는 존재 + 값은 NSNull
        #expect(dict.keys.contains("ar_pose_4x4"))
        #expect(dict["ar_pose_4x4"] is NSNull)
    }

    // MARK: - 5) kind == "client_dump" 고정

    @Test("kind 필드는 'client_dump' 고정")
    func kindFieldFixed() throws {
        let descriptors = makeUnitDescriptors(rowChannels: [0])
        let frame = makeFrame(
            keypoints: [SIMD3<Float>(0, 0, 1.0)],
            descriptors: descriptors
        )
        let data = try SuperPointFrameDumper.encode(
            frame: frame, arPose: nil, orientation: "landscape", date: Date()
        )
        let json = try decodeJSON(data)
        #expect((json["kind"] as? String) == "client_dump")
    }
}
#endif
